import Foundation

public struct SyncWindow: Sendable, Equatable {
    public var startDate: Date
    public var pageSize: Int

    public init(startDate: Date, pageSize: Int) {
        self.startDate = startDate
        self.pageSize = pageSize
    }
}

public struct SyncWindowCalculator: Sendable {
    public var policy: SyncPolicy
    public var calendar: Calendar

    public init(policy: SyncPolicy = SyncPolicy(), calendar: Calendar = .init(identifier: .gregorian)) {
        self.policy = policy
        self.calendar = calendar
    }

    public func initialWindow(now: Date, isJunk: Bool) -> SyncWindow {
        let duration = isJunk ? policy.junkHistoryWindow : policy.mainHistoryWindow
        return SyncWindow(
            startDate: now - duration.timeIntervalApproximation,
            pageSize: policy.initialPerFolderLimit
        )
    }

    public func incrementalWindow(now: Date, lastSuccessfulSyncAt: Date?, isJunk: Bool) -> SyncWindow {
        guard let lastSuccessfulSyncAt else {
            return initialWindow(now: now, isJunk: isJunk)
        }

        let historicalStart = initialWindow(now: now, isJunk: isJunk).startDate
        let overlappedStart = lastSuccessfulSyncAt - policy.checkpointOverlap.timeIntervalApproximation
        return SyncWindow(
            startDate: max(historicalStart, overlappedStart),
            pageSize: policy.incrementalPerFolderLimit
        )
    }
}

extension Duration {
    var timeIntervalApproximation: TimeInterval {
        let components = self.components
        let seconds = Double(components.seconds)
        let attoseconds = Double(components.attoseconds) / 1_000_000_000_000_000_000
        return seconds + attoseconds
    }
}
