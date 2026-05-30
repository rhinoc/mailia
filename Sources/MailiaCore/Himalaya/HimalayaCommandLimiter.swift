import Foundation

public actor HimalayaCommandLimiter {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(maxConcurrentCommands: Int) {
        self.permits = max(1, maxConcurrentCommands)
    }

    public func run(
        _ command: HimalayaCommand,
        bridge: any HimalayaBridge,
        timeout: TimeInterval?
    ) async throws -> HimalayaResult {
        await wait()
        do {
            let result = try await bridge.run(command, timeout: timeout)
            signal()
            return result
        } catch {
            signal()
            throw error
        }
    }

    private func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func signal() {
        guard !waiters.isEmpty else {
            permits += 1
            return
        }

        waiters.removeFirst().resume()
    }
}

