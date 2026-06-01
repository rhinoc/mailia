import Foundation

enum ListFetchPriority: Int, Comparable, Sendable {
    case background = 100
    case incremental = 200
    case selected = 300

    static func < (lhs: ListFetchPriority, rhs: ListFetchPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum ListFetchRequestID: Hashable, Sendable {
    case selectedTimeline(entityID: Int64)
    case timelinePage(direction: MailiaTimelinePageDirection)
}

@MainActor
final class ListFetchQueue {
    typealias Operation = @MainActor () async -> Void

    private struct PendingJob {
        let id: ListFetchRequestID
        var priority: ListFetchPriority
        var sequence: Int
        let operation: Operation
    }

    private struct RunningJob {
        let priority: ListFetchPriority
        let token: Int
    }

    private let maxConcurrentLoads: Int
    private var pendingJobs: [ListFetchRequestID: PendingJob] = [:]
    private var runningJobs: [ListFetchRequestID: RunningJob] = [:]
    private var tasks: [ListFetchRequestID: Task<Void, Never>] = [:]
    private var nextSequence = 0
    private var nextToken = 0

    init(maxConcurrentLoads: Int = 2) {
        self.maxConcurrentLoads = maxConcurrentLoads
    }

    deinit {
        for task in tasks.values {
            task.cancel()
        }
    }

    func enqueue(
        id: ListFetchRequestID,
        priority: ListFetchPriority,
        operation: @escaping Operation
    ) {
        cancel(id: id)
        nextSequence += 1
        pendingJobs[id] = PendingJob(
            id: id,
            priority: priority,
            sequence: nextSequence,
            operation: operation
        )
        preemptLowerPriorityLoadIfNeeded(forPriority: priority)
        startPendingLoads()
    }

    func cancel(id: ListFetchRequestID) {
        pendingJobs[id] = nil
        tasks[id]?.cancel()
        tasks[id] = nil
        runningJobs[id] = nil
    }

    func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
        pendingJobs.removeAll()
        runningJobs.removeAll()
        tasks.removeAll()
    }

    private func startPendingLoads() {
        while runningJobs.count < maxConcurrentLoads {
            guard let nextID = nextPendingLoadID(),
                  let job = pendingJobs.removeValue(forKey: nextID)
            else {
                return
            }
            startLoad(job)
        }
    }

    private func nextPendingLoadID() -> ListFetchRequestID? {
        pendingJobs.max { lhs, rhs in
            if lhs.value.priority == rhs.value.priority {
                return lhs.value.sequence < rhs.value.sequence
            }
            return lhs.value.priority < rhs.value.priority
        }?.key
    }

    private func preemptLowerPriorityLoadIfNeeded(forPriority priority: ListFetchPriority) {
        guard runningJobs.count >= maxConcurrentLoads,
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

        tasks[preempted.key]?.cancel()
        tasks[preempted.key] = nil
        runningJobs[preempted.key] = nil
    }

    private func startLoad(_ job: PendingJob) {
        nextToken += 1
        let token = nextToken
        runningJobs[job.id] = RunningJob(priority: job.priority, token: token)
        tasks[job.id]?.cancel()
        tasks[job.id] = Task { [weak self] in
            await job.operation()
            guard let self else { return }
            if isCurrent(id: job.id, token: token) {
                runningJobs[job.id] = nil
                tasks[job.id] = nil
                startPendingLoads()
            }
        }
    }

    private func isCurrent(id: ListFetchRequestID, token: Int) -> Bool {
        runningJobs[id]?.token == token
    }
}
