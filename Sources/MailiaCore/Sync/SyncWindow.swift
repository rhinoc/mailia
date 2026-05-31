import Foundation

public struct SyncWindow: Sendable, Equatable {
    public var queryStart: Date
    public var checkpointHighWater: Date?
    public var pageSize: Int

    public var startDate: Date {
        get { queryStart }
        set { queryStart = newValue }
    }

    public init(queryStart: Date, checkpointHighWater: Date?, pageSize: Int) {
        self.queryStart = queryStart
        self.checkpointHighWater = checkpointHighWater
        self.pageSize = pageSize
    }

    public init(startDate: Date, pageSize: Int) {
        self.init(queryStart: startDate, checkpointHighWater: nil, pageSize: pageSize)
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
            queryStart: now - duration.timeIntervalApproximation,
            checkpointHighWater: now,
            pageSize: policy.initialPerFolderLimit
        )
    }

    public func fullHistoryWindow(checkpointHighWater: Date? = nil) -> SyncWindow {
        SyncWindow(
            queryStart: Date(timeIntervalSince1970: 0),
            checkpointHighWater: checkpointHighWater,
            pageSize: policy.fullHistoryPerFolderPageSize
        )
    }

    public func incrementalWindow(now: Date, lastSuccessfulSyncAt: Date?, isJunk: Bool) -> SyncWindow {
        incrementalWindow(now: now, lastCheckpointHighWater: lastSuccessfulSyncAt, isJunk: isJunk)
    }

    public func incrementalWindow(now: Date, lastCheckpointHighWater: Date?, isJunk: Bool) -> SyncWindow {
        guard let lastCheckpointHighWater else {
            return initialWindow(now: now, isJunk: isJunk)
        }

        let historicalStart = initialWindow(now: now, isJunk: isJunk).startDate
        let overlappedStart = lastCheckpointHighWater - policy.checkpointOverlap.timeIntervalApproximation
        return SyncWindow(
            queryStart: max(historicalStart, overlappedStart),
            checkpointHighWater: now,
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
