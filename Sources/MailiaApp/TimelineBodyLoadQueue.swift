import Foundation

@MainActor
protocol TimelineBodyLoadQueueDelegate: AnyObject {
    var currentTimelineGeneration: Int { get }

    func timelineContainsItem(id: Int64) -> Bool
    func timelineItem(id: Int64) -> MailiaTimelineItem?
    func bodyState(id: Int64) -> MailiaTimelineBodyState?
    func setBodyState(_ state: MailiaTimelineBodyState?, id: Int64)
    func cachedBodyState(id: Int64) -> MailiaTimelineBodyState?
    func cacheBodyState(_ state: MailiaTimelineBodyState, id: Int64)
    func rememberBodyAccess(id: Int64)
    func bodyLoadQueueDidUpdateBodyStates()
}

@MainActor
final class TimelineBodyLoadQueue {
    private let provider: any MailiaAppDataProviding
    private let maxConcurrentBodyLoads: Int

    weak var delegate: (any TimelineBodyLoadQueueDelegate)?

    private var pendingLoads: [Int64: MailiaTimelineItem] = [:]
    private var pendingLoadOrder: [Int64] = []
    private var pendingLoadPriorities: [Int64: Int] = [:]
    private var inFlightLoads: Set<Int64> = []
    private var inFlightLoadPriorities: [Int64: Int] = [:]
    private var loadTokens: [Int64: Int] = [:]
    private var loadTasks: [Int64: Task<Void, Never>] = [:]
    private var nextLoadPriority = 0
    private var nextLoadToken = 0

    init(provider: any MailiaAppDataProviding, maxConcurrentBodyLoads: Int = 3) {
        self.provider = provider
        self.maxConcurrentBodyLoads = maxConcurrentBodyLoads
    }

    deinit {
        for task in loadTasks.values {
            task.cancel()
        }
    }

    func loadIfNeeded(for item: MailiaTimelineItem, priority requestedPriority: Int? = nil) {
        guard let delegate,
              delegate.timelineContainsItem(id: item.id)
        else {
            return
        }

        delegate.rememberBodyAccess(id: item.id)
        if let cachedState = delegate.cachedBodyState(id: item.id) {
            delegate.setBodyState(cachedState, id: item.id)
            return
        }

        switch delegate.bodyState(id: item.id) ?? .notRequested {
        case .notRequested:
            break
        case .loading:
            reprioritizeLoadIfNeeded(for: item, requestedPriority: requestedPriority)
            return
        case .loaded, .failed:
            return
        }

        if pendingLoads[item.id] != nil || inFlightLoads.contains(item.id) {
            reprioritizeLoadIfNeeded(for: item, requestedPriority: requestedPriority)
            return
        }

        enqueueLoad(item, requestedPriority: requestedPriority)
        startPendingLoads()
    }

    func reset() {
        cancelAll()
        pendingLoads.removeAll()
        pendingLoadOrder.removeAll()
        pendingLoadPriorities.removeAll()
    }

    func cancelAll() {
        for task in loadTasks.values {
            task.cancel()
        }
        loadTasks.removeAll()
        inFlightLoads.removeAll()
        inFlightLoadPriorities.removeAll()
        loadTokens.removeAll()
    }

    func cancelLoads(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        for id in ids {
            pendingLoads[id] = nil
            pendingLoadPriorities[id] = nil
            loadTasks[id]?.cancel()
            loadTasks[id] = nil
            inFlightLoads.remove(id)
            inFlightLoadPriorities[id] = nil
            loadTokens[id] = nil
        }
        pendingLoadOrder.removeAll { pendingLoads[$0] == nil }
    }

    private func startPendingLoads() {
        while inFlightLoads.count < maxConcurrentBodyLoads {
            guard let nextID = nextPendingLoadID(),
                  let item = pendingLoads.removeValue(forKey: nextID),
                  let delegate
            else {
                pendingLoadOrder.removeAll()
                return
            }
            let priority = pendingLoadPriorities.removeValue(forKey: nextID) ?? 0
            pendingLoadOrder.removeAll { $0 == nextID }
            guard delegate.timelineContainsItem(id: item.id) else {
                delegate.setBodyState(nil, id: item.id)
                continue
            }
            startLoad(for: item, priority: priority)
        }
    }

    private func enqueueLoad(_ item: MailiaTimelineItem, requestedPriority: Int?) {
        let priority = nextLoadPriorityValue(requestedPriority: requestedPriority)
        pendingLoads[item.id] = item
        pendingLoadPriorities[item.id] = priority
        pendingLoadOrder.removeAll { $0 == item.id }
        pendingLoadOrder.append(item.id)
        preemptOlderLoadIfNeeded(forPriority: priority)
    }

    private func reprioritizePendingLoad(for item: MailiaTimelineItem, requestedPriority: Int?) {
        let priority = nextLoadPriorityValue(requestedPriority: requestedPriority)
        pendingLoads[item.id] = item
        pendingLoadPriorities[item.id] = priority
        pendingLoadOrder.removeAll { $0 == item.id }
        pendingLoadOrder.append(item.id)
        preemptOlderLoadIfNeeded(forPriority: priority)
    }

    private func reprioritizeLoadIfNeeded(for item: MailiaTimelineItem, requestedPriority: Int?) {
        if pendingLoads[item.id] != nil {
            reprioritizePendingLoad(for: item, requestedPriority: requestedPriority)
            startPendingLoads()
        }
    }

    private func nextLoadPriorityValue(requestedPriority: Int?) -> Int {
        if let requestedPriority {
            nextLoadPriority = max(nextLoadPriority, requestedPriority)
            return requestedPriority
        }
        nextLoadPriority += 1
        return nextLoadPriority
    }

    private func nextPendingLoadID() -> Int64? {
        pendingLoadOrder
            .filter { pendingLoads[$0] != nil }
            .max {
                (pendingLoadPriorities[$0] ?? 0) < (pendingLoadPriorities[$1] ?? 0)
            }
    }

    private func preemptOlderLoadIfNeeded(forPriority priority: Int) {
        guard inFlightLoads.count >= maxConcurrentBodyLoads,
              let preemptedID = inFlightLoads.min(by: {
                  (inFlightLoadPriorities[$0] ?? 0) < (inFlightLoadPriorities[$1] ?? 0)
              }),
              (inFlightLoadPriorities[preemptedID] ?? 0) < priority
        else {
            return
        }

        loadTasks[preemptedID]?.cancel()
        loadTasks[preemptedID] = nil
        inFlightLoads.remove(preemptedID)
        let preemptedPriority = inFlightLoadPriorities[preemptedID] ?? 0
        inFlightLoadPriorities[preemptedID] = nil
        loadTokens[preemptedID] = nil
        if let item = delegate?.timelineItem(id: preemptedID),
           pendingLoads[preemptedID] == nil {
            pendingLoads[preemptedID] = item
            pendingLoadPriorities[preemptedID] = preemptedPriority
            pendingLoadOrder.removeAll { $0 == preemptedID }
            pendingLoadOrder.append(preemptedID)
        }
    }

    private func startLoad(for item: MailiaTimelineItem, priority: Int) {
        guard let generation = delegate?.currentTimelineGeneration else { return }
        nextLoadToken += 1
        let token = nextLoadToken
        loadTokens[item.id] = token
        inFlightLoads.insert(item.id)
        inFlightLoadPriorities[item.id] = priority
        delegate?.setBodyState(.loading, id: item.id)

        loadTasks[item.id]?.cancel()
        loadTasks[item.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let body = try await provider.loadBody(for: item)
                if delegate?.currentTimelineGeneration == generation,
                   loadTokens[item.id] == token,
                   delegate?.timelineContainsItem(id: item.id) == true {
                    delegate?.cacheBodyState(.loaded(body), id: item.id)
                    delegate?.setBodyState(.loaded(body), id: item.id)
                    delegate?.rememberBodyAccess(id: item.id)
                }
            } catch is CancellationError {
                if delegate?.currentTimelineGeneration == generation,
                   loadTokens[item.id] == token {
                    delegate?.setBodyState(.notRequested, id: item.id)
                }
            } catch {
                if delegate?.currentTimelineGeneration == generation,
                   loadTokens[item.id] == token,
                   delegate?.timelineContainsItem(id: item.id) == true {
                    delegate?.cacheBodyState(.failed(error.localizedDescription), id: item.id)
                    delegate?.setBodyState(.failed(error.localizedDescription), id: item.id)
                }
            }

            if delegate?.currentTimelineGeneration == generation,
               loadTokens[item.id] == token {
                inFlightLoads.remove(item.id)
                inFlightLoadPriorities[item.id] = nil
                loadTokens[item.id] = nil
                loadTasks[item.id] = nil
                delegate?.bodyLoadQueueDidUpdateBodyStates()
                startPendingLoads()
            }
        }
    }
}
