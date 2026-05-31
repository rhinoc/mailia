import Foundation

public struct SyncPolicy: Sendable, Equatable {
    public var mainHistoryWindow: Duration
    public var junkHistoryWindow: Duration
    public var checkpointOverlap: Duration
    public var initialPerFolderLimit: Int
    public var incrementalPerFolderLimit: Int
    public var foregroundInterval: Duration
    public var maxConcurrentAccounts: Int
    public var maxConcurrentFoldersPerAccount: Int
    public var maxConcurrentHimalayaProcesses: Int

    public init(
        mainHistoryWindow: Duration = .days(90),
        junkHistoryWindow: Duration = .days(30),
        checkpointOverlap: Duration = .hours(24),
        initialPerFolderLimit: Int = 500,
        incrementalPerFolderLimit: Int = 200,
        foregroundInterval: Duration = .minutes(10),
        maxConcurrentAccounts: Int = 2,
        maxConcurrentFoldersPerAccount: Int = 2,
        maxConcurrentHimalayaProcesses: Int = 3
    ) {
        self.mainHistoryWindow = mainHistoryWindow
        self.junkHistoryWindow = junkHistoryWindow
        self.checkpointOverlap = checkpointOverlap
        self.initialPerFolderLimit = initialPerFolderLimit
        self.incrementalPerFolderLimit = incrementalPerFolderLimit
        self.foregroundInterval = foregroundInterval
        self.maxConcurrentAccounts = maxConcurrentAccounts
        self.maxConcurrentFoldersPerAccount = maxConcurrentFoldersPerAccount
        self.maxConcurrentHimalayaProcesses = maxConcurrentHimalayaProcesses
    }
}

extension Duration {
    public static func minutes(_ value: Int64) -> Duration {
        .seconds(value * 60)
    }

    public static func hours(_ value: Int64) -> Duration {
        .minutes(value * 60)
    }

    public static func days(_ value: Int64) -> Duration {
        .hours(value * 24)
    }
}
