import Foundation

public enum MailAppServerRequestPriority: Int, Sendable, Comparable {
    case backgroundSync = 0
    case userDownload = 1
    case visibleBody = 2
    case interactive = 3

    public static func < (lhs: MailAppServerRequestPriority, rhs: MailAppServerRequestPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public actor MailAppServerRequestLimiter {
    private let maxConcurrentRequests: Int
    private var activeRequestsByPriority: [MailAppServerRequestPriority: Int] = [:]
    private var waiters: [Waiter] = []
    private var nextSequence: UInt64 = 0

    public init(maxConcurrentRequests: Int) {
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
    }

    public func run<Result: Sendable>(
        priority: MailAppServerRequestPriority = .interactive,
        timingMethod: String? = nil,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        let waitStartedAt = Date()
        let wasQueued: Bool
        do {
            wasQueued = try await wait(priority: priority)
        } catch {
            logQueueTiming(
                startedAt: waitStartedAt,
                priority: priority,
                timingMethod: timingMethod,
                wasQueued: true,
                status: error is CancellationError ? "cancelled" : "failure",
                outcome: error is CancellationError ? "swift_cancelled" : "swift_failure"
            )
            throw error
        }
        logQueueTiming(
            startedAt: waitStartedAt,
            priority: priority,
            timingMethod: timingMethod,
            wasQueued: wasQueued,
            status: "success",
            outcome: wasQueued ? "queued" : "immediate"
        )
        defer { release(priority: priority) }
        try Task.checkCancellation()
        return try await operation()
    }

    private func wait(priority: MailAppServerRequestPriority) async throws -> Bool {
        try Task.checkCancellation()

        if canStart(priority: priority) {
            start(priority: priority)
            return false
        }

        let id = UUID()
        let sequence = nextSequence
        nextSequence += 1
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(
                        id: id,
                        priority: priority,
                        sequence: sequence,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: id)
            }
        }

        if !acquired {
            throw CancellationError()
        }
        return true
    }

    private func logQueueTiming(
        startedAt: Date,
        priority: MailAppServerRequestPriority,
        timingMethod: String?,
        wasQueued: Bool,
        status: String,
        outcome: String
    ) {
        guard timingMethod != nil || wasQueued || status != "success" else { return }
        MailiaTiming.log(
            operation: "app_server.request_queue",
            startedAt: startedAt,
            status: status,
            fields: [
                .label("method", timingMethod ?? "unknown"),
                .label("priority", priority.timingLabel),
                .label("queued", wasQueued),
                .label("queued_ms", max(0, Int((Date().timeIntervalSince(startedAt) * 1_000).rounded()))),
                .label("outcome", outcome)
            ]
        )
    }

    private func start(priority: MailAppServerRequestPriority) {
        activeRequestsByPriority[priority, default: 0] += 1
    }

    private func release(priority: MailAppServerRequestPriority) {
        let count = activeRequestsByPriority[priority] ?? 0
        if count <= 1 {
            activeRequestsByPriority[priority] = nil
        } else {
            activeRequestsByPriority[priority] = count - 1
        }
        signalNextWaiterIfPossible()
    }

    private func signalNextWaiterIfPossible() {
        guard let index = nextStartableWaiterIndex() else { return }
        let waiter = waiters.remove(at: index)
        start(priority: waiter.priority)
        waiter.continuation.resume(returning: true)
    }

    private func nextStartableWaiterIndex() -> Int? {
        waiters.indices
            .filter { canStart(priority: waiters[$0].priority) }
            .max { lhsIndex, rhsIndex in
            let lhs = waiters[lhsIndex]
            let rhs = waiters[rhsIndex]
            if lhs.priority == rhs.priority {
                return lhs.sequence > rhs.sequence
            }
            return lhs.priority < rhs.priority
        }
    }

    private func canStart(priority: MailAppServerRequestPriority) -> Bool {
        guard activeRequestCount < maxConcurrentRequests else { return false }
        if priority == .backgroundSync {
            return activeBackgroundSyncCount < maxBackgroundSyncRequests
        }
        return true
    }

    private var activeRequestCount: Int {
        activeRequestsByPriority.values.reduce(0, +)
    }

    private var activeBackgroundSyncCount: Int {
        activeRequestsByPriority[.backgroundSync] ?? 0
    }

    private var maxBackgroundSyncRequests: Int {
        max(1, maxConcurrentRequests - 1)
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private struct Waiter {
        var id: UUID
        var priority: MailAppServerRequestPriority
        var sequence: UInt64
        var continuation: CheckedContinuation<Bool, Never>
    }
}

private extension MailAppServerRequestPriority {
    var timingLabel: String {
        switch self {
        case .backgroundSync:
            return "background_sync"
        case .userDownload:
            return "user_download"
        case .visibleBody:
            return "visible_body"
        case .interactive:
            return "interactive"
        }
    }
}
