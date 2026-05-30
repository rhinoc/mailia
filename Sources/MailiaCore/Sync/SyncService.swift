import Foundation
import GRDB

public struct SyncService {
    private let bridge: any HimalayaBridge
    private let repository: MailRepository
    private let policy: SyncPolicy
    private let decoder: JSONDecoder
    private let windowCalculator: SyncWindowCalculator
    private let himalayaCommandLimiter: HimalayaCommandLimiter
    private let nowProvider: @Sendable () -> Date

    public init(
        bridge: any HimalayaBridge,
        databaseQueue: DatabaseQueue,
        policy: SyncPolicy = SyncPolicy(),
        himalayaCommandLimiter: HimalayaCommandLimiter? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.bridge = bridge
        self.repository = MailRepository(databaseQueue: databaseQueue)
        self.policy = policy
        self.decoder = JSONDecoder()
        self.windowCalculator = SyncWindowCalculator(policy: policy)
        self.himalayaCommandLimiter = himalayaCommandLimiter
            ?? HimalayaCommandLimiter(maxConcurrentCommands: policy.maxConcurrentHimalayaProcesses)
        self.nowProvider = now
    }

    @discardableResult
    public func discoverAccounts(timeout: TimeInterval? = nil) async throws -> [DiscoveredAccount] {
        let result = try await runHimalaya(.accountList(), timeout: timeout).requireSuccess()
        let decoded = try result.decodeJSON(as: HimalayaList<HimalayaAccountDTO>.self, decoder: decoder)
        let accounts = decoded.values
            .map(\.discoveredAccount)
            .filter { !$0.accountKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        try repository.upsertAccounts(accounts)
        return accounts
    }

    @discardableResult
    public func discoverFolders(
        accountKey: String,
        timeout: TimeInterval? = nil
    ) async throws -> [DiscoveredFolder] {
        let result = try await runHimalaya(.folderList(account: accountKey), timeout: timeout).requireSuccess()
        let decoded = try result.decodeJSON(as: HimalayaList<HimalayaFolderDTO>.self, decoder: decoder)
        let folders = decoded.values
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map {
                $0.discoveredFolder(accountKey: accountKey)
            }
        try repository.upsertFolders(folders)
        return folders
    }

    @discardableResult
    public func discoverFoldersForDiscoveredAccounts(timeout: TimeInterval? = nil) async throws -> [DiscoveredFolder] {
        let accounts = try await discoverAccounts(timeout: timeout)
        let accountSemaphore = AsyncSemaphore(permits: policy.maxConcurrentAccounts)

        return try await withThrowingTaskGroup(of: [DiscoveredFolder].self) { group in
            for account in accounts {
                group.addTask {
                    try await withPermit(accountSemaphore) {
                        try await discoverFolders(accountKey: account.accountKey, timeout: timeout)
                    }
                }
            }

            var folders: [DiscoveredFolder] = []
            for try await accountFolders in group {
                folders += accountFolders
            }
            return folders
        }
    }

    @discardableResult
    public func syncWorkspace(
        _ workspace: Workspace,
        timeout: TimeInterval? = nil
    ) async throws -> Int {
        let folders = try repository.folders(for: workspace)
        let foldersByAccount = Dictionary(grouping: folders, by: \.accountKey)
        let accountSemaphore = AsyncSemaphore(permits: policy.maxConcurrentAccounts)

        return try await withThrowingTaskGroup(of: Int.self) { group in
            for accountKey in foldersByAccount.keys.sorted() {
                let accountFolders = (foldersByAccount[accountKey] ?? [])
                    .sorted { $0.providerName < $1.providerName }

                group.addTask {
                    try await withPermit(accountSemaphore) {
                        let syncedCount = try await syncFolders(
                            accountFolders,
                            workspace: workspace,
                            timeout: timeout
                        )

                        if !accountFolders.isEmpty {
                            try repository.markAccountSyncSucceeded(
                                accountKey: accountKey,
                                workspace: workspace,
                                at: nowProvider()
                            )
                        }
                        return syncedCount
                    }
                }
            }

            var syncedCount = 0
            for try await accountCount in group {
                syncedCount += accountCount
            }
            return syncedCount
        }
    }

    @discardableResult
    public func syncFolder(
        _ folder: StoredFolder,
        workspace: Workspace,
        timeout: TimeInterval? = nil
    ) async throws -> Int {
        let lastSuccessfulSyncAt = try repository.lastSuccessfulSyncAt(
            accountKey: folder.accountKey,
            folderID: folder.id,
            workspace: workspace
        )
        let window = windowCalculator.incrementalWindow(
            now: nowProvider(),
            lastSuccessfulSyncAt: lastSuccessfulSyncAt,
            isJunk: workspace == .junk || folder.role == .junk
        )
        let pageSize = max(1, window.pageSize)
        let result = try await runHimalaya(
            .envelopeList(
                folder: folder.providerName,
                account: folder.accountKey,
                query: syncQuery(startDate: window.startDate),
                page: 1,
                pageSize: pageSize
            ),
            timeout: timeout
        ).requireSuccess()

        let decoded = try result.decodeJSON(as: HimalayaList<HimalayaEnvelopeDTO>.self, decoder: decoder)
        let bounded = decoded.values.prefix(pageSize)
        let envelopes = bounded.map {
            $0.envelopeMessage(
                accountKey: folder.accountKey,
                folderName: folder.providerName,
                folderRole: folder.role
            )
        }
        let ids = try repository.upsertEnvelopes(envelopes)
        try repository.markFolderSyncSucceeded(
            accountKey: folder.accountKey,
            folderID: folder.id,
            workspace: workspace,
            at: nowProvider()
        )
        return ids.count
    }

    private func syncFolders(
        _ folders: [StoredFolder],
        workspace: Workspace,
        timeout: TimeInterval?
    ) async throws -> Int {
        guard policy.maxConcurrentFoldersPerAccount > 1 else {
            var syncedCount = 0
            for folder in folders {
                syncedCount += try await syncFolder(folder, workspace: workspace, timeout: timeout)
            }
            return syncedCount
        }

        let folderSemaphore = AsyncSemaphore(permits: policy.maxConcurrentFoldersPerAccount)
        return try await withThrowingTaskGroup(of: Int.self) { group in
            for folder in folders {
                group.addTask {
                    try await withPermit(folderSemaphore) {
                        try await syncFolder(folder, workspace: workspace, timeout: timeout)
                    }
                }
            }

            var syncedCount = 0
            for try await folderCount in group {
                syncedCount += folderCount
            }
            return syncedCount
        }
    }

    private func runHimalaya(
        _ command: HimalayaCommand,
        timeout: TimeInterval?
    ) async throws -> HimalayaResult {
        try await himalayaCommandLimiter.run(command, bridge: bridge, timeout: timeout)
    }

    private func syncQuery(startDate: Date) -> String {
        "after \(Self.formatQueryDate(startDate)) order by date desc"
    }

    private static func formatQueryDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(permits: Int) {
        self.permits = max(1, permits)
    }

    func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard !waiters.isEmpty else {
            permits += 1
            return
        }

        waiters.removeFirst().resume()
    }
}

private func withPermit<T: Sendable>(
    _ semaphore: AsyncSemaphore,
    operation: @Sendable () async throws -> T
) async throws -> T {
    await semaphore.wait()
    do {
        let value = try await operation()
        await semaphore.signal()
        return value
    } catch {
        await semaphore.signal()
        throw error
    }
}

extension SyncService: @unchecked Sendable {}
