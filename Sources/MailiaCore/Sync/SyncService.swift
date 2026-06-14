import Foundation
import GRDB

public struct SyncService {
    private let appServerClient: MailAppServerClient
    private let repository: MailRepository
    private let himalayaConfigStore: HimalayaConfigStore
    private let policy: SyncPolicy
    private let windowCalculator: SyncWindowCalculator
    private let appServerRequestLimiter: MailAppServerRequestLimiter
    private let nowProvider: @Sendable () -> Date

    public init(
        appServerClient: MailAppServerClient,
        databaseQueue: DatabaseQueue,
        himalayaConfigStore: HimalayaConfigStore = HimalayaConfigStore(),
        policy: SyncPolicy = SyncPolicy(),
        appServerRequestLimiter: MailAppServerRequestLimiter? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.appServerClient = appServerClient
        self.repository = MailRepository(databaseQueue: databaseQueue)
        self.himalayaConfigStore = himalayaConfigStore
        self.policy = policy
        self.windowCalculator = SyncWindowCalculator(policy: policy)
        self.appServerRequestLimiter = appServerRequestLimiter
            ?? MailAppServerRequestLimiter(maxConcurrentRequests: policy.maxConcurrentHimalayaProcesses)
        self.nowProvider = now
    }

    @discardableResult
    public func discoverAccounts(timeout: TimeInterval? = nil) async throws -> [DiscoveredAccount] {
        let timingStartedAt = Date()
        do {
            let serverAccounts = try await runAppServer(priority: .backgroundSync) {
                try await appServerClient.accountList(timeout: timeout)
            }
            let configMetadata = (try? himalayaConfigStore.accountMetadata()) ?? [:]
            let accounts = serverAccounts
                .map { accountDTO in
                    let metadata = configMetadata[accountDTO.name]
                    return accountDTO.discoveredAccount(metadata: metadata)
                }
                .filter { !$0.accountKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            try repository.upsertAccounts(accounts)
            MailiaTiming.log(
                operation: "sync.discover_accounts",
                startedAt: timingStartedAt,
                fields: [.label("account_count", accounts.count)]
            )
            return accounts
        } catch {
            MailiaTiming.log(operation: "sync.discover_accounts", startedAt: timingStartedAt, status: "failure")
            throw error
        }
    }

    @discardableResult
    public func discoverFolders(
        accountKey: String,
        timeout: TimeInterval? = nil,
        source: String? = nil
    ) async throws -> [DiscoveredFolder] {
        let timingStartedAt = Date()
        let baseFields = [.redacted("account", accountKey)] + Self.folderDiscoverySourceFields(source)
        do {
            let serverFolders = try await runAppServer(priority: .backgroundSync) {
                try await appServerClient.folderList(account: accountKey, timeout: timeout)
            }
            let folders = serverFolders
                .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map {
                    $0.discoveredFolder(accountKey: accountKey)
                }
            try repository.replaceDiscoveredFolders(accountKey: accountKey, folders: folders)
            try repository.markAccountSyncStatus(accountKey: accountKey, status: "ok")
            MailiaTiming.log(
                operation: "sync.discover_folders",
                startedAt: timingStartedAt,
                fields: baseFields + folderRoleCountFields(folders)
            )
            return folders
        } catch {
            MailiaTiming.log(
                operation: "sync.discover_folders",
                startedAt: timingStartedAt,
                status: "failure",
                fields: baseFields
            )
            throw error
        }
    }

    @discardableResult
    public func discoverFoldersForDiscoveredAccounts(
        timeout: TimeInterval? = nil,
        source: String? = nil
    ) async throws -> [DiscoveredFolder] {
        let timingStartedAt = Date()
        let timingFields = Self.folderDiscoverySourceFields(source)
        do {
            let accounts = try await discoverAccounts(timeout: timeout)
            let accountSemaphore = AsyncSemaphore(permits: policy.maxConcurrentAccounts)

            let folders = try await withThrowingTaskGroup(of: [DiscoveredFolder].self) { group in
                for account in accounts {
                    group.addTask {
                        try await withPermit(accountSemaphore) {
                            do {
                                return try await discoverFolders(
                                    accountKey: account.accountKey,
                                    timeout: timeout,
                                    source: source
                                )
                            } catch let error as CancellationError {
                                throw error
                            } catch {
                                NSLog("Unable to discover folders for account \(account.accountKey): \(error.localizedDescription)")
                                try? repository.markAccountSyncStatus(
                                    accountKey: account.accountKey,
                                    status: "failed",
                                    errorMessage: error.localizedDescription
                                )
                                return []
                            }
                        }
                    }
                }

                var folders: [DiscoveredFolder] = []
                for try await accountFolders in group {
                    folders += accountFolders
                }
                return folders
            }
            MailiaTiming.log(
                operation: "sync.discover_folders_all",
                startedAt: timingStartedAt,
                fields: timingFields + [
                    .label("account_count", accounts.count),
                    .label("folder_count", folders.count)
                ]
            )
            return folders
        } catch {
            MailiaTiming.log(
                operation: "sync.discover_folders_all",
                startedAt: timingStartedAt,
                status: "failure",
                fields: timingFields
            )
            throw error
        }
    }

    @discardableResult
    public func discoverFoldersForRefresh(
        timeout: TimeInterval? = nil,
        source: String? = nil
    ) async throws -> [DiscoveredFolder] {
        return try await discoverFoldersForDiscoveredAccounts(timeout: timeout, source: source)
    }

    @discardableResult
    public func syncWorkspace(
        _ workspace: Workspace,
        accountKeys: Set<String>? = nil,
        folderRoles: Set<FolderRole>? = nil,
        accountPriorityScores: [String: Int] = [:],
        fullHistory: Bool = false,
        timeout: TimeInterval? = nil,
        onProgress: (@Sendable (SyncWorkspaceProgress) -> Void)? = nil
    ) async throws -> Int {
        try await syncWorkspaceResult(
            workspace,
            accountKeys: accountKeys,
            folderRoles: folderRoles,
            accountPriorityScores: accountPriorityScores,
            fullHistory: fullHistory,
            timeout: timeout,
            onProgress: onProgress
        ).syncedCount
    }

    public func syncWorkspaceResult(
        _ workspace: Workspace,
        accountKeys: Set<String>? = nil,
        folderRoles: Set<FolderRole>? = nil,
        accountPriorityScores: [String: Int] = [:],
        fullHistory: Bool = false,
        timeout: TimeInterval? = nil,
        onProgress: (@Sendable (SyncWorkspaceProgress) -> Void)? = nil
    ) async throws -> SyncWorkspaceResult {
        let timingStartedAt = Date()
        let baseFields: [MailiaTimingField] = [
            .label("workspace", workspace.rawValue),
            .label("full_history", fullHistory)
        ]
        do {
            let normalizedAccountKeys: Set<String>?
            if let accountKeys {
                let normalized = Set(
                    accountKeys
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                )
                guard !normalized.isEmpty else {
                    let result = SyncWorkspaceResult(syncedCount: 0, attemptedFolderCount: 0, hadFailure: false)
                    MailiaTiming.log(
                        operation: "sync.workspace",
                        startedAt: timingStartedAt,
                        fields: baseFields + syncWorkspaceResultFields(result)
                    )
                    return result
                }
                normalizedAccountKeys = normalized
            } else {
                normalizedAccountKeys = nil
            }
            var folders = try syncableFolders(
                workspace: workspace,
                accountKeys: normalizedAccountKeys,
                folderRoles: folderRoles
            )
            if folders.isEmpty {
                _ = try await discoverFoldersForDiscoveredAccounts(
                    timeout: timeout,
                    source: "sync_empty_fallback"
                )
                folders = try syncableFolders(
                    workspace: workspace,
                    accountKeys: normalizedAccountKeys,
                    folderRoles: folderRoles
                )
            }
            let totalFolders = folders.count
            let shouldMarkAccountCheckpoint = accountKeys == nil && folderRoles == nil

            let onFolderSynced = makeProgressHandler(
                workspace: workspace,
                totalUnits: totalFolders,
                onProgress: onProgress
            )

            let outcomes = try await runByAccount(
                folders: folders,
                priorityScores: accountPriorityScores
            ) { accountKey, accountFolders in
                let accountSyncStartedAt = nowProvider()
                let outcome = try await syncFolders(
                    accountFolders,
                    workspace: workspace,
                    fullHistory: fullHistory,
                    timeout: timeout,
                    onFolderSynced: onFolderSynced
                )

                if shouldMarkAccountCheckpoint, !accountFolders.isEmpty, !outcome.hadFailure {
                    try repository.markAccountSyncSucceeded(
                        accountKey: accountKey,
                        workspace: workspace,
                        at: accountSyncStartedAt,
                        startedAt: accountSyncStartedAt,
                        finishedAt: nowProvider()
                    )
                }
                if !accountFolders.isEmpty, !outcome.hadFailure {
                    try repository.markAccountSyncStatus(accountKey: accountKey, status: "ok")
                }
                return outcome
            }
            let totalSynced = outcomes.reduce(0) { $0 + $1.syncedCount }
            let result = SyncWorkspaceResult(
                syncedCount: totalSynced,
                attemptedFolderCount: totalFolders,
                hadFailure: outcomes.contains { $0.hadFailure }
            )
            MailiaTiming.log(
                operation: "sync.workspace",
                startedAt: timingStartedAt,
                fields: baseFields + syncWorkspaceResultFields(result)
            )
            return result
        } catch {
            MailiaTiming.log(operation: "sync.workspace", startedAt: timingStartedAt, status: "failure", fields: baseFields)
            throw error
        }
    }

    private func syncableFolders(
        workspace: Workspace,
        accountKeys: Set<String>?,
        folderRoles: Set<FolderRole>?
    ) throws -> [StoredFolder] {
        var folders = try repository.folders(for: workspace)
        if let accountKeys {
            folders = folders.filter { accountKeys.contains($0.accountKey) }
        }
        if let folderRoles {
            folders = folders.filter { folderRoles.contains($0.role) }
        }
        return folders
    }

    @discardableResult
    public func syncFolder(
        _ folder: StoredFolder,
        workspace: Workspace,
        fullHistory: Bool = false,
        timeout: TimeInterval? = nil,
        onFolderSynced: (@Sendable (Int) -> Void)? = nil
    ) async throws -> Int {
        let timingStartedAt = Date()
        let baseFields: [MailiaTimingField] = [
            .label("workspace", workspace.rawValue),
            .redacted("account", folder.accountKey),
            .redacted("folder", folder.providerName),
            .label("folder_role", folder.role.rawValue),
            .label("full_history", fullHistory)
        ]
        do {
            let syncStartedAt = nowProvider()
            let lastSuccessfulSyncAt = try repository.lastSuccessfulSyncAt(
                accountKey: folder.accountKey,
                folderID: folder.id,
                workspace: workspace
            )
            let window = fullHistory
                ? windowCalculator.fullHistoryWindow(checkpointHighWater: syncStartedAt)
                : windowCalculator.incrementalWindow(
                    now: syncStartedAt,
                    lastSuccessfulSyncAt: lastSuccessfulSyncAt,
                    isJunk: workspace == .junk || folder.role == .junk
                )
            let pageResult = try await makeEnvelopePageSyncer().sync(
                folder: folder,
                query: syncQuery(startDate: window.startDate),
                window: window,
                timeout: timeout,
                progress: { result in
                    onFolderSynced?(result.syncedCount)
                },
                checkpoint: { result in
                    try repository.markFolderSyncSucceeded(
                        accountKey: folder.accountKey,
                        folderID: folder.id,
                        workspace: workspace,
                        at: window.checkpointHighWater ?? syncStartedAt,
                        startedAt: syncStartedAt,
                        finishedAt: nowProvider(),
                        queryStartAt: window.queryStart,
                        oldestSyncedMessageDate: result.oldestSyncedMessageDate
                    )
                }
            )
            MailiaTiming.log(
                operation: "sync.folder",
                startedAt: timingStartedAt,
                fields: baseFields + [.label("message_count", pageResult.syncedCount)]
            )
            return pageResult.syncedCount
        } catch {
            MailiaTiming.log(operation: "sync.folder", startedAt: timingStartedAt, status: "failure", fields: baseFields)
            throw error
        }
    }

    @discardableResult
    public func syncEntityHistory(
        _ workspace: Workspace,
        emailAddresses: Set<String>,
        timeout: TimeInterval? = nil,
        onProgress: (@Sendable (SyncWorkspaceProgress) -> Void)? = nil
    ) async throws -> Int {
        let timingStartedAt = Date()
        let baseFields: [MailiaTimingField] = [.label("workspace", workspace.rawValue)]
        do {
            let normalizedEmailAddresses = emailAddresses
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty && $0.contains("@") }
                .sorted()
            guard !normalizedEmailAddresses.isEmpty else {
                MailiaTiming.log(
                    operation: "sync.entity_history",
                    startedAt: timingStartedAt,
                    fields: baseFields + [
                        .label("address_count", 0),
                        .label("synced_count", 0)
                    ]
                )
                return 0
            }

            let folders = try repository.folders(for: workspace)
            let totalQueries = folders.count * normalizedEmailAddresses.count * 2

            let onQuerySynced = makeProgressHandler(
                workspace: workspace,
                totalUnits: totalQueries,
                onProgress: onProgress
            )

            let accountSyncedCounts = try await runByAccount(folders: folders) { _, accountFolders in
                var syncedCount = 0
                for folder in accountFolders {
                    for emailAddress in normalizedEmailAddresses {
                        syncedCount += try await syncFilteredFolderBestEffort(
                            folder,
                            workspace: workspace,
                            filter: "from \(emailAddress)",
                            timeout: timeout,
                            onQuerySynced: onQuerySynced
                        )
                        syncedCount += try await syncFilteredFolderBestEffort(
                            folder,
                            workspace: workspace,
                            filter: "to \(emailAddress)",
                            timeout: timeout,
                            onQuerySynced: onQuerySynced
                        )
                    }
                }
                return syncedCount
            }
            let syncedCount = accountSyncedCounts.reduce(0, +)
            MailiaTiming.log(
                operation: "sync.entity_history",
                startedAt: timingStartedAt,
                fields: baseFields + [
                    .label("address_count", normalizedEmailAddresses.count),
                    .label("folder_count", folders.count),
                    .label("query_count", totalQueries),
                    .label("synced_count", syncedCount)
                ]
            )
            return syncedCount
        } catch {
            MailiaTiming.log(operation: "sync.entity_history", startedAt: timingStartedAt, status: "failure", fields: baseFields)
            throw error
        }
    }

    private func makeProgressHandler(
        workspace: Workspace,
        totalUnits: Int,
        onProgress: (@Sendable (SyncWorkspaceProgress) -> Void)?
    ) -> (@Sendable (Int) -> Void)? {
        guard let onProgress else { return nil }
        let counter = SyncProgressCounter()

        onProgress(SyncWorkspaceProgress(
            workspace: workspace,
            completedFolders: 0,
            totalFolders: totalUnits,
            syncedMessages: 0
        ))

        return { messages in
            Task {
                let snapshot = await counter.record(messages: messages)
                onProgress(SyncWorkspaceProgress(
                    workspace: workspace,
                    completedFolders: snapshot.completedFolders,
                    totalFolders: totalUnits,
                    syncedMessages: snapshot.syncedMessages
                ))
            }
        }
    }

    private func runByAccount<Result: Sendable>(
        folders: [StoredFolder],
        priorityScores: [String: Int] = [:],
        workload: @escaping @Sendable (_ accountKey: String, _ folders: [StoredFolder]) async throws -> Result
    ) async throws -> [Result] {
        let foldersByAccount = Dictionary(grouping: folders, by: \.accountKey)
        let sortedAccountKeys = sortedAccountKeys(Array(foldersByAccount.keys), priorityScores: priorityScores)
        let maxActiveAccounts = max(1, policy.maxConcurrentAccounts)

        return try await withThrowingTaskGroup(of: Result.self) { group in
            var nextAccountIndex = 0
            var activeAccounts = 0

            func submitNextAccountIfNeeded() {
                guard nextAccountIndex < sortedAccountKeys.count else { return }
                let accountKey = sortedAccountKeys[nextAccountIndex]
                nextAccountIndex += 1
                let accountFolders = (foldersByAccount[accountKey] ?? [])
                    .sorted(by: folderSyncPrecedence)

                group.addTask {
                    try await workload(accountKey, accountFolders)
                }
                activeAccounts += 1
            }

            while activeAccounts < maxActiveAccounts, nextAccountIndex < sortedAccountKeys.count {
                submitNextAccountIfNeeded()
            }

            var results: [Result] = []
            while activeAccounts > 0 {
                guard let result = try await group.next() else { break }
                results.append(result)
                activeAccounts -= 1
                submitNextAccountIfNeeded()
            }
            return results
        }
    }

    private func syncFolders(
        _ folders: [StoredFolder],
        workspace: Workspace,
        fullHistory: Bool,
        timeout: TimeInterval?,
        onFolderSynced: (@Sendable (Int) -> Void)? = nil
    ) async throws -> SyncFoldersOutcome {
        guard policy.maxConcurrentFoldersPerAccount > 1 else {
            var outcome = SyncFoldersOutcome()
            for folder in folders {
                outcome.merge(try await syncFolderBestEffort(
                    folder,
                    workspace: workspace,
                    fullHistory: fullHistory,
                    timeout: timeout,
                    onFolderSynced: onFolderSynced
                ))
            }
            return outcome
        }

        let folderSemaphore = AsyncSemaphore(permits: policy.maxConcurrentFoldersPerAccount)
        let outcome = try await withThrowingTaskGroup(of: SyncFoldersOutcome.self) { group in
            for folder in folders {
                group.addTask {
                    try await withPermit(folderSemaphore) {
                        try await syncFolderBestEffort(
                            folder,
                            workspace: workspace,
                            fullHistory: fullHistory,
                            timeout: timeout,
                            onFolderSynced: onFolderSynced
                        )
                    }
                }
            }

            var outcome = SyncFoldersOutcome()
            for try await folderOutcome in group {
                outcome.merge(folderOutcome)
            }
            return outcome
        }
        return outcome
    }

    private func syncFolderBestEffort(
        _ folder: StoredFolder,
        workspace: Workspace,
        fullHistory: Bool,
        timeout: TimeInterval?,
        onFolderSynced: (@Sendable (Int) -> Void)? = nil
    ) async throws -> SyncFoldersOutcome {
        do {
            let count = try await syncFolder(
                folder,
                workspace: workspace,
                fullHistory: fullHistory,
                timeout: timeout,
                onFolderSynced: onFolderSynced
            )
            return SyncFoldersOutcome(syncedCount: count, hadFailure: false)
        } catch let error as CancellationError {
            throw error
        } catch {
            NSLog(
                "Unable to sync folder \(folder.providerName) for account \(folder.accountKey) in \(workspace.rawValue): \(error.localizedDescription)"
            )
            try? repository.markAccountSyncStatus(
                accountKey: folder.accountKey,
                status: "failed",
                errorMessage: error.localizedDescription
            )
            onFolderSynced?(0)
            return SyncFoldersOutcome(syncedCount: 0, hadFailure: true)
        }
    }

    private func syncFilteredFolder(
        _ folder: StoredFolder,
        workspace: Workspace,
        filter: String,
        timeout: TimeInterval?,
        onQuerySynced: (@Sendable (Int) -> Void)? = nil
    ) async throws -> Int {
        let timingStartedAt = Date()
        let baseFields: [MailiaTimingField] = [
            .label("workspace", workspace.rawValue),
            .redacted("account", folder.accountKey),
            .redacted("folder", folder.providerName),
            .label("folder_role", folder.role.rawValue),
            .label("filter_direction", filter.hasPrefix("to ") ? "to" : "from")
        ]
        do {
            let window = windowCalculator.fullHistoryWindow()
            let pageResult = try await makeEnvelopePageSyncer().sync(
                folder: folder,
                query: syncQuery(startDate: window.startDate, filter: filter),
                window: window,
                timeout: timeout,
                progress: { result in
                    onQuerySynced?(result.uniqueSyncedCount)
                }
            )
            MailiaTiming.log(
                operation: "sync.filtered_folder",
                startedAt: timingStartedAt,
                fields: baseFields + [.label("message_count", pageResult.uniqueSyncedCount)]
            )
            return pageResult.uniqueSyncedCount
        } catch {
            MailiaTiming.log(
                operation: "sync.filtered_folder",
                startedAt: timingStartedAt,
                status: "failure",
                fields: baseFields
            )
            throw error
        }
    }

    private func syncFilteredFolderBestEffort(
        _ folder: StoredFolder,
        workspace: Workspace,
        filter: String,
        timeout: TimeInterval?,
        onQuerySynced: (@Sendable (Int) -> Void)? = nil
    ) async throws -> Int {
        do {
            return try await syncFilteredFolder(
                folder,
                workspace: workspace,
                filter: filter,
                timeout: timeout,
                onQuerySynced: onQuerySynced
            )
        } catch let error as CancellationError {
            throw error
        } catch {
            NSLog(
                "Unable to sync filtered folder \(folder.providerName) for account \(folder.accountKey) in \(workspace.rawValue): \(error.localizedDescription)"
            )
            onQuerySynced?(0)
            return 0
        }
    }

    private func runAppServer<Result: Sendable>(
        priority: MailAppServerRequestPriority,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await appServerRequestLimiter.run(priority: priority, operation: operation)
    }

    private func makeEnvelopePageSyncer() -> EnvelopePageSyncer {
        EnvelopePageSyncer(repository: repository) { folder, query, page, pageSize, timeout in
            let timingStartedAt = Date()
            let fields: [MailiaTimingField] = [
                .redacted("account", folder.accountKey),
                .redacted("folder", folder.providerName),
                .label("folder_role", folder.role.rawValue),
                .label("page", page),
                .label("page_size", pageSize)
            ]
            do {
                let envelopes = try await runAppServer(priority: .backgroundSync) {
                    try await appServerClient.messageList(
                        folder: folder.providerName,
                        account: folder.accountKey,
                        query: query,
                        page: page,
                        pageSize: pageSize,
                        timeout: timeout
                    )
                }
                MailiaTiming.log(
                    operation: "sync.message_list_page",
                    startedAt: timingStartedAt,
                    fields: fields + [.label("envelope_count", envelopes.count)]
                )
                return envelopes
            } catch {
                MailiaTiming.log(
                    operation: "sync.message_list_page",
                    startedAt: timingStartedAt,
                    status: "failure",
                    fields: fields
                )
                throw error
            }
        }
    }

    private func syncQuery(startDate: Date) -> String {
        "after \(Self.formatQueryDate(startDate)) order by date desc"
    }

    private func syncQuery(startDate: Date, filter: String) -> String {
        let trimmedFilter = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFilter.isEmpty else { return syncQuery(startDate: startDate) }
        return "after \(Self.formatQueryDate(startDate)) and \(trimmedFilter) order by date desc"
    }

    private static func formatQueryDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func sortedAccountKeys(_ accountKeys: [String], priorityScores: [String: Int]) -> [String] {
        accountKeys.sorted { lhs, rhs in
            let lhsScore = priorityScores[lhs] ?? 0
            let rhsScore = priorityScores[rhs] ?? 0
            if lhsScore != rhsScore {
                return lhsScore > rhsScore
            }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private func folderSyncPrecedence(_ lhs: StoredFolder, _ rhs: StoredFolder) -> Bool {
        let lhsRank = folderSyncRank(lhs)
        let rhsRank = folderSyncRank(rhs)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        return lhs.providerName.localizedStandardCompare(rhs.providerName) == .orderedAscending
    }

    private func folderSyncRank(_ folder: StoredFolder) -> Int {
        let name = folder.providerName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["inbox", "important", "priority"].contains(name) {
            return 0
        }
        switch folder.role {
        case .normal:
            return 1
        case .sent:
            return 2
        case .junk:
            return 3
        case .trash:
            return 4
        case .drafts:
            return 5
        case .outbox:
            return 6
        case .unknown:
            return 7
        }
    }

    private func folderRoleCountFields(_ folders: [DiscoveredFolder]) -> [MailiaTimingField] {
        let counts = Dictionary(grouping: folders, by: \.role).mapValues(\.count)
        return [
            .label("folder_count", folders.count),
            .label("normal_count", counts[.normal] ?? 0),
            .label("sent_count", counts[.sent] ?? 0),
            .label("junk_count", counts[.junk] ?? 0),
            .label("trash_count", counts[.trash] ?? 0),
            .label("other_count", folders.count
                - (counts[.normal] ?? 0)
                - (counts[.sent] ?? 0)
                - (counts[.junk] ?? 0)
                - (counts[.trash] ?? 0))
        ]
    }

    private static func folderDiscoverySourceFields(_ source: String?) -> [MailiaTimingField] {
        guard let source,
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [] }
        return [.label("source", source)]
    }

    private func syncWorkspaceResultFields(_ result: SyncWorkspaceResult) -> [MailiaTimingField] {
        [
            .label("synced_count", result.syncedCount),
            .label("attempted_folder_count", result.attemptedFolderCount),
            .label("had_failure", result.hadFailure)
        ]
    }

}

private struct EnvelopePageSyncer {
    private let repository: MailRepository
    private let listMessages: @Sendable (StoredFolder, String, Int, Int, TimeInterval?) async throws -> [MailAppServerMessageEnvelope]

    init(
        repository: MailRepository,
        listMessages: @escaping @Sendable (StoredFolder, String, Int, Int, TimeInterval?) async throws -> [MailAppServerMessageEnvelope]
    ) {
        self.repository = repository
        self.listMessages = listMessages
    }

    @discardableResult
    func sync(
        folder: StoredFolder,
        query: String,
        window: SyncWindow,
        timeout: TimeInterval?,
        progress: (@Sendable (EnvelopePageSyncResult) -> Void)? = nil,
        checkpoint: ((EnvelopePageSyncResult) throws -> Void)? = nil
    ) async throws -> EnvelopePageSyncResult {
        let pageSize = max(1, window.pageSize)
        var page = 1
        var syncResult = EnvelopePageSyncResult()

        while true {
            let listed = try await listMessages(folder, query, page, pageSize, timeout)
            let bounded = listed.prefix(pageSize)
            let envelopes = bounded.map {
                $0.envelopeMessage(
                    accountKey: folder.accountKey,
                    folderName: folder.providerName,
                    folderRole: folder.role
                )
            }
            let ids = try MailiaTiming.measure(
                operation: "repository.upsert_envelopes",
                fields: [
                    .redacted("account", folder.accountKey),
                    .redacted("folder", folder.providerName),
                    .label("folder_role", folder.role.rawValue),
                    .label("envelope_count", envelopes.count)
                ]
            ) {
                try repository.upsertEnvelopes(envelopes)
            }
            syncResult.record(ids: ids, envelopes: envelopes)

            guard listed.count >= pageSize else { break }
            page += 1
        }

        try checkpoint?(syncResult)
        progress?(syncResult)
        return syncResult
    }
}

private struct EnvelopePageSyncResult: Sendable {
    private(set) var syncedCount = 0
    private(set) var uniqueSyncedMessageIDs = Set<Int64>()
    private(set) var oldestSyncedMessageDate: Date?

    var uniqueSyncedCount: Int {
        uniqueSyncedMessageIDs.count
    }

    mutating func record(ids: [Int64], envelopes: [EnvelopeMessage]) {
        syncedCount += ids.count
        uniqueSyncedMessageIDs.formUnion(ids)
        oldestSyncedMessageDate = Self.olderDate(
            oldestSyncedMessageDate,
            envelopes.compactMap { HimalayaDateParser.parse($0.messageDate) }.min()
        )
    }

    private static func olderDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return min(lhs, rhs)
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            return nil
        }
    }
}

public struct SyncWorkspaceProgress: Equatable, Sendable {
    public let workspace: Workspace
    public let completedFolders: Int
    public let totalFolders: Int
    public let syncedMessages: Int

    public init(
        workspace: Workspace,
        completedFolders: Int,
        totalFolders: Int,
        syncedMessages: Int
    ) {
        self.workspace = workspace
        self.completedFolders = completedFolders
        self.totalFolders = totalFolders
        self.syncedMessages = syncedMessages
    }
}

private struct SyncFoldersOutcome: Sendable {
    var syncedCount: Int = 0
    var hadFailure = false

    mutating func merge(_ outcome: SyncFoldersOutcome) {
        syncedCount += outcome.syncedCount
        hadFailure = hadFailure || outcome.hadFailure
    }
}

public struct SyncWorkspaceResult: Equatable, Sendable {
    public let syncedCount: Int
    public let attemptedFolderCount: Int
    public let hadFailure: Bool

    public init(syncedCount: Int, attemptedFolderCount: Int, hadFailure: Bool) {
        self.syncedCount = syncedCount
        self.attemptedFolderCount = attemptedFolderCount
        self.hadFailure = hadFailure
    }
}

private actor SyncProgressCounter {
    struct Snapshot: Sendable {
        let completedFolders: Int
        let syncedMessages: Int
    }

    private var completedFolders = 0
    private var syncedMessages = 0

    func record(messages: Int) -> Snapshot {
        completedFolders += 1
        syncedMessages += messages
        return Snapshot(completedFolders: completedFolders, syncedMessages: syncedMessages)
    }
}

private actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [Waiter] = []

    init(permits: Int) {
        self.permits = max(1, permits)
    }

    func withPermit<T: Sendable>(
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await wait()
        defer { signal() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func wait() async throws {
        try Task.checkCancellation()

        if permits > 0 {
            permits -= 1
            return
        }

        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
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

        waiters.removeFirst().continuation.resume(returning: true)
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<Bool, Never>
    }
}

private func withPermit<T: Sendable>(
    _ semaphore: AsyncSemaphore,
    operation: @Sendable () async throws -> T
) async throws -> T {
    try await semaphore.withPermit(operation: operation)
}

extension SyncService: @unchecked Sendable {}
