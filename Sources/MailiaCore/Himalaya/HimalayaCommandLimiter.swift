import Foundation

public enum HimalayaCommandPriority: Int, Sendable, Comparable {
    case backgroundSync = 0
    case userDownload = 1
    case visibleBody = 2
    case interactive = 3

    public static func < (lhs: HimalayaCommandPriority, rhs: HimalayaCommandPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public actor HimalayaCommandLimiter {
    private var permits: Int
    private var waiters: [Waiter] = []
    private var nextSequence: UInt64 = 0

    public init(maxConcurrentCommands: Int) {
        self.permits = max(1, maxConcurrentCommands)
    }

    public func run(
        _ command: HimalayaCommand,
        bridge: any HimalayaBridge,
        timeout: TimeInterval?,
        priority: HimalayaCommandPriority = .interactive
    ) async throws -> HimalayaResult {
        try await wait(priority: priority)
        defer { signal() }
        try Task.checkCancellation()
        return try await bridge.run(command, timeout: timeout)
    }

    private func wait(priority: HimalayaCommandPriority) async throws {
        try Task.checkCancellation()

        if permits > 0 {
            permits -= 1
            return
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
    }

    private func signal() {
        guard !waiters.isEmpty else {
            permits += 1
            return
        }

        let index = nextWaiterIndex()
        waiters.remove(at: index).continuation.resume(returning: true)
    }

    private func nextWaiterIndex() -> Int {
        waiters.indices.max { lhsIndex, rhsIndex in
            let lhs = waiters[lhsIndex]
            let rhs = waiters[rhsIndex]
            if lhs.priority == rhs.priority {
                return lhs.sequence > rhs.sequence
            }
            return lhs.priority < rhs.priority
        } ?? waiters.startIndex
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private struct Waiter {
        var id: UUID
        var priority: HimalayaCommandPriority
        var sequence: UInt64
        var continuation: CheckedContinuation<Bool, Never>
    }
}
