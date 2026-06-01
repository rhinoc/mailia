import Foundation

enum BodyFetchPriority: Int, Comparable, Sendable {
    case background = 100
    case entityPreview = 200
    case selectedPage = 300
    case nearby = 400
    case visible = 500

    static func < (lhs: BodyFetchPriority, rhs: BodyFetchPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

@MainActor
protocol BodyFetchQueueDelegate: AnyObject {
    var currentTimelineGeneration: Int { get }

    func timelineContainsItem(id: Int64) -> Bool
    func timelineItem(id: Int64) -> MailiaTimelineItem?
    func bodyState(id: Int64) -> MailiaTimelineBodyState?
    func setBodyState(_ state: MailiaTimelineBodyState?, id: Int64)
    func cachedBodyState(id: Int64) -> MailiaTimelineBodyState?
    func cacheBodyState(_ state: MailiaTimelineBodyState, id: Int64)
    func rememberBodyAccess(id: Int64)
    func bodyFetchQueueDidLoadBody(_ body: MailiaTimelineBody, for item: MailiaTimelineItem, priority: BodyFetchPriority)
    func bodyFetchQueueDidUpdateBodyStates()
}

@MainActor
final class BodyFetchQueue {
    private struct PendingJob {
        var item: MailiaTimelineItem
        var priority: BodyFetchPriority
        var sequence: Int
        var requiresTimelineMembership: Bool
    }

    private struct RunningJob {
        var item: MailiaTimelineItem
        var priority: BodyFetchPriority
        var token: Int
        var generation: Int?
        var requiresTimelineMembership: Bool
    }

    private let provider: any MailiaAppDataProviding
    private let maxConcurrentBodyLoads: Int

    weak var delegate: (any BodyFetchQueueDelegate)?

    private var pendingJobs: [Int64: PendingJob] = [:]
    private var runningJobs: [Int64: RunningJob] = [:]
    private var loadTasks: [Int64: Task<Void, Never>] = [:]
    private var nextSequence = 0
    private var nextLoadToken = 0

    init(
        provider: any MailiaAppDataProviding,
        maxConcurrentBodyLoads: Int = 3
    ) {
        self.provider = provider
        self.maxConcurrentBodyLoads = maxConcurrentBodyLoads
    }

    deinit {
        for task in loadTasks.values {
            task.cancel()
        }
    }

    func loadIfNeeded(
        for item: MailiaTimelineItem,
        priority: BodyFetchPriority,
        requiresTimelineMembership: Bool = true
    ) {
        guard let delegate else {
            return
        }
        if requiresTimelineMembership, !delegate.timelineContainsItem(id: item.id) {
            return
        }

        delegate.rememberBodyAccess(id: item.id)
        if let cachedState = delegate.cachedBodyState(id: item.id) {
            if requiresTimelineMembership {
                delegate.setBodyState(cachedState, id: item.id)
            }
            return
        }

        switch delegate.bodyState(id: item.id) ?? .notRequested {
        case .notRequested:
            break
        case .loading:
            reprioritizeLoadIfNeeded(
                for: item,
                priority: priority,
                requiresTimelineMembership: requiresTimelineMembership
            )
            return
        case .loaded:
            return
        case .failed where priority < .visible:
            return
        case .failed:
            delegate.setBodyState(.notRequested, id: item.id)
        }

        if pendingJobs[item.id] != nil || runningJobs[item.id] != nil {
            reprioritizeLoadIfNeeded(
                for: item,
                priority: priority,
                requiresTimelineMembership: requiresTimelineMembership
            )
            return
        }

        enqueueLoad(item, priority: priority, requiresTimelineMembership: requiresTimelineMembership)
        startPendingLoads()
    }

    func reset() {
        cancelAll()
        pendingJobs.removeAll()
    }

    func cancelAll() {
        let cancelledIDs = Set(pendingJobs.keys)
            .union(runningJobs.keys)
            .union(loadTasks.keys)
        for task in loadTasks.values {
            task.cancel()
        }
        for id in cancelledIDs where delegate?.bodyState(id: id) == .loading {
            delegate?.setBodyState(.notRequested, id: id)
        }
        pendingJobs.removeAll()
        loadTasks.removeAll()
        runningJobs.removeAll()
    }

    func cancelLoads(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        for id in ids {
            pendingJobs[id] = nil
            loadTasks[id]?.cancel()
            loadTasks[id] = nil
            runningJobs[id] = nil
            if delegate?.bodyState(id: id) == .loading {
                delegate?.setBodyState(.notRequested, id: id)
            }
        }
    }

    private func startPendingLoads() {
        while runningJobs.count < maxConcurrentBodyLoads {
            guard let nextID = nextPendingLoadID(),
                  let job = pendingJobs.removeValue(forKey: nextID),
                  let delegate
            else {
                return
            }
            guard !job.requiresTimelineMembership || delegate.timelineContainsItem(id: job.item.id) else {
                delegate.setBodyState(nil, id: job.item.id)
                continue
            }
            startLoad(job)
        }
    }

    private func enqueueLoad(
        _ item: MailiaTimelineItem,
        priority: BodyFetchPriority,
        requiresTimelineMembership: Bool
    ) {
        nextSequence += 1
        pendingJobs[item.id] = PendingJob(
            item: item,
            priority: priority,
            sequence: nextSequence,
            requiresTimelineMembership: requiresTimelineMembership
        )
        preemptOlderLoadIfNeeded(forPriority: priority)
    }

    private func reprioritizePendingLoad(
        for item: MailiaTimelineItem,
        priority: BodyFetchPriority,
        requiresTimelineMembership: Bool
    ) {
        let current = pendingJobs[item.id]
        nextSequence += 1
        pendingJobs[item.id] = PendingJob(
            item: item,
            priority: max(priority, current?.priority ?? priority),
            sequence: nextSequence,
            requiresTimelineMembership: requiresTimelineMembership || (current?.requiresTimelineMembership ?? false)
        )
        preemptOlderLoadIfNeeded(forPriority: priority)
    }

    private func reprioritizeLoadIfNeeded(
        for item: MailiaTimelineItem,
        priority: BodyFetchPriority,
        requiresTimelineMembership: Bool
    ) {
        if pendingJobs[item.id] != nil {
            reprioritizePendingLoad(
                for: item,
                priority: priority,
                requiresTimelineMembership: requiresTimelineMembership
            )
            startPendingLoads()
        }
        if var running = runningJobs[item.id], priority > running.priority {
            running.priority = priority
            running.requiresTimelineMembership = requiresTimelineMembership || running.requiresTimelineMembership
            runningJobs[item.id] = running
            if running.requiresTimelineMembership, delegate?.bodyState(id: item.id) != .loading {
                delegate?.setBodyState(.loading, id: item.id)
            }
        }
    }

    private func nextPendingLoadID() -> Int64? {
        pendingJobs.max { lhs, rhs in
            if lhs.value.priority == rhs.value.priority {
                return lhs.value.sequence < rhs.value.sequence
            }
            return lhs.value.priority < rhs.value.priority
        }?.key
    }

    private func preemptOlderLoadIfNeeded(forPriority priority: BodyFetchPriority) {
        guard runningJobs.count >= maxConcurrentBodyLoads,
              let preempted = runningJobs.min(by: {
                  if $0.value.priority == $1.value.priority {
                      return $0.value.token < $1.value.token
                  }
                  return $0.value.priority < $1.value.priority
              }),
              preempted.value.priority < priority
        else {
            return
        }

        let preemptedID = preempted.key
        loadTasks[preemptedID]?.cancel()
        loadTasks[preemptedID] = nil
        runningJobs[preemptedID] = nil
        if pendingJobs[preemptedID] == nil {
            nextSequence += 1
            pendingJobs[preemptedID] = PendingJob(
                item: preempted.value.item,
                priority: preempted.value.priority,
                sequence: nextSequence,
                requiresTimelineMembership: preempted.value.requiresTimelineMembership
            )
        }
    }

    private func startLoad(_ job: PendingJob) {
        let generation = job.requiresTimelineMembership ? delegate?.currentTimelineGeneration : nil
        nextLoadToken += 1
        let token = nextLoadToken
        let item = job.item
        runningJobs[item.id] = RunningJob(
            item: item,
            priority: job.priority,
            token: token,
            generation: generation,
            requiresTimelineMembership: job.requiresTimelineMembership
        )
        if job.requiresTimelineMembership {
            delegate?.setBodyState(.loading, id: item.id)
        }

        loadTasks[item.id]?.cancel()
        loadTasks[item.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let body = try await provider.loadBody(for: item)
                if isCurrent(token: token, itemID: item.id, generation: generation),
                   !job.requiresTimelineMembership || delegate?.timelineContainsItem(id: item.id) == true {
                    if job.requiresTimelineMembership {
                        delegate?.cacheBodyState(.loaded(body), id: item.id)
                        delegate?.setBodyState(.loaded(body), id: item.id)
                    }
                    delegate?.bodyFetchQueueDidLoadBody(body, for: item, priority: job.priority)
                    delegate?.rememberBodyAccess(id: item.id)
                }
            } catch is CancellationError {
                if isCurrent(token: token, itemID: item.id, generation: generation),
                   job.requiresTimelineMembership {
                    delegate?.setBodyState(.notRequested, id: item.id)
                }
            } catch {
                if isCurrent(token: token, itemID: item.id, generation: generation),
                   !job.requiresTimelineMembership || delegate?.timelineContainsItem(id: item.id) == true {
                    if job.requiresTimelineMembership, job.priority >= .visible {
                        delegate?.cacheBodyState(.failed(error.localizedDescription), id: item.id)
                        delegate?.setBodyState(.failed(error.localizedDescription), id: item.id)
                    } else if job.requiresTimelineMembership {
                        delegate?.setBodyState(.notRequested, id: item.id)
                    }
                }
            }

            if isCurrent(token: token, itemID: item.id, generation: generation) {
                runningJobs[item.id] = nil
                loadTasks[item.id] = nil
                delegate?.bodyFetchQueueDidUpdateBodyStates()
                startPendingLoads()
            }
        }
    }

    private func isCurrent(token: Int, itemID: Int64, generation: Int?) -> Bool {
        guard let running = runningJobs[itemID],
              running.token == token else {
            return false
        }
        if let generation {
            return delegate?.currentTimelineGeneration == generation
        }
        return true
    }

}
