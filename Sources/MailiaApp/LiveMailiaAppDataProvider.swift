import Foundation
import GRDB
import MailiaCore
import AppKit

@MainActor
protocol MailiaAppDataProviding {
    func loadSnapshot(workspace: MailiaWorkspace, searchQuery: String) async throws -> MailiaSnapshot
    func lastRefreshFinishedAt() async throws -> Date?
    func recipientSuggestions() async throws -> [MailiaRecipientSuggestion]
    func refresh(
        workspace: MailiaWorkspace,
        searchQuery: String,
        options: MailiaRefreshOptions,
        progress: @escaping @MainActor (MailiaRefreshProgress) -> Void
    ) async throws -> MailiaSnapshot
    func refreshAfterSendingMessage(
        accountKeys: Set<String>,
        workspace: MailiaWorkspace,
        searchQuery: String
    ) async throws -> MailiaSnapshot
    func refreshNewerTimelineMessages(
        accountKeys: Set<String>,
        workspace: MailiaWorkspace,
        searchQuery: String
    ) async throws -> MailiaSnapshot
    func syncEntityHistory(
        emailAddresses: Set<String>,
        workspace: MailiaWorkspace,
        searchQuery: String,
        progress: @escaping @MainActor (MailiaRefreshProgress) -> Void
    ) async throws -> MailiaSnapshot
    func loadTimelinePage(
        entityID: Int64,
        workspace: MailiaWorkspace,
        direction: MailiaTimelinePageDirection,
        anchorID: Int64?,
        limit: Int
    ) async throws -> MailiaTimelinePage
    func loadLatestTimelineItems(entityIDs: [Int64], workspace: MailiaWorkspace) async throws -> [MailiaTimelineItem]
    func loadBody(for item: MailiaTimelineItem) async throws -> MailiaTimelineBody
    func performEntityAction(
        _ action: MailiaEntityAction,
        entityID: Int64,
        workspace: MailiaWorkspace,
        progress: @escaping @MainActor (String) -> Void
    ) async throws
    func markMessageRead(item: MailiaTimelineItem, workspace: MailiaWorkspace) async throws
    func markMessagesRead(items: [MailiaTimelineItem], workspace: MailiaWorkspace) async throws -> Int
    func markEntityRead(entityID: Int64, workspace: MailiaWorkspace) async throws
    func setMessageFlag(item: MailiaTimelineItem, isFlagged: Bool) async throws
    func downloadAttachments(for item: MailiaTimelineItem) async throws -> MailiaAttachmentDownloadResult
    func sendReply(to item: MailiaTimelineItem, content: MailiaComposerContent, replyAll: Bool, accountKey: String?) async throws
    func sendNewMessage(
        to recipients: [String],
        subject: String?,
        content: MailiaComposerContent,
        accountKey: String?
    ) async throws
    func loadSendAccounts() async throws -> [MailiaSendAccount]
    func updateAccountSettings(_ updates: [MailiaAccountSettingsUpdate]) async throws
    func messageBodyCacheStats() async throws -> CacheStats
    func clearMessageBodyCache() async throws
}

/// Aggregates per-workspace sync progress into a single determinate progress value
/// for the refresh button.
private actor RefreshProgressAggregator {
    private var byWorkspace: [Workspace: SyncWorkspaceProgress] = [:]

    func update(_ progress: SyncWorkspaceProgress) -> MailiaRefreshProgress {
        byWorkspace[progress.workspace] = progress

        let totalFolders = byWorkspace.values.reduce(0) { $0 + $1.totalFolders }
        let completedFolders = byWorkspace.values.reduce(0) { $0 + $1.completedFolders }
        let syncedMessages = byWorkspace.values.reduce(0) { $0 + $1.syncedMessages }

        let detail: String
        if totalFolders > 0 {
            detail = "\(completedFolders) of \(totalFolders) mailboxes · \(syncedMessages) messages"
        } else {
            detail = "\(syncedMessages) messages"
        }

        return MailiaRefreshProgress(
            phase: .downloading,
            title: "Downloading messages",
            detail: detail,
            fraction: totalFolders > 0 ? Double(completedFolders) / Double(totalFolders) : nil
        )
    }
}

private enum BackgroundFolderRefreshDecision: String, Sendable {
    case start
    case skipInFlight = "in_flight"
    case skipRecentlyAttempted = "recently_attempted"
}

private actor BackgroundFolderRefreshGate {
    private let minimumInterval: TimeInterval
    private var isRunning = false
    private var lastAttemptStartedAt: Date?

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    func begin(now: Date) -> BackgroundFolderRefreshDecision {
        if isRunning {
            return .skipInFlight
        }
        if let lastAttemptStartedAt,
           now.timeIntervalSince(lastAttemptStartedAt) < minimumInterval {
            return .skipRecentlyAttempted
        }
        isRunning = true
        lastAttemptStartedAt = now
        return .start
    }

    func finish() {
        isRunning = false
    }
}

@MainActor
private func measureMainActorTiming<Result>(
    operation: String,
    fields: [MailiaTimingField] = [],
    _ body: () async throws -> Result
) async throws -> Result {
    let startedAt = Date()
    do {
        let result = try await body()
        MailiaTiming.log(operation: operation, startedAt: startedAt, fields: fields)
        return result
    } catch {
        MailiaTiming.log(operation: operation, startedAt: startedAt, status: "failure", fields: fields)
        throw error
    }
}

enum MailiaSyncFailure: LocalizedError {
    case mailboxSyncFailed
    case mailboxDiscoveryFailed(Error)

    var errorDescription: String? {
        switch self {
        case .mailboxSyncFailed:
            "One or more mailboxes failed to sync. Check that the Mailia app-server is available and the account settings are valid."
        case let .mailboxDiscoveryFailed(error):
            "Unable to discover mailboxes: \(error.localizedDescription)"
        }
    }
}

@MainActor
struct LiveMailiaAppDataProvider: MailiaAppDataProviding {
    private let databaseQueue: DatabaseQueue
    private let repository: MailRepository
    private let syncService: SyncService
    private let appServerClient: MailAppServerClient
    private let himalayaConfigStore: HimalayaConfigStore
    private let appServerRequestLimiter: MailAppServerRequestLimiter
    private let downloadsDirectory: URL
    private let revealDownloadedFiles: @MainActor ([URL], URL) -> Void
    private let emailDisplayPipeline = EmailHTMLDisplayPipeline()
    private let htmlTextExtractor = HTMLTextExtractor()
    private let backgroundFolderRefreshGate: BackgroundFolderRefreshGate
    private let backgroundMailboxMaintenanceDelayNanoseconds: UInt64
    private let nowProvider: @Sendable () -> Date

    init() {
        do {
            let environment = try MailiaEnvironment.live(
                appServerClient: MailiaHimalayaExecutableSettings.appServerClient()
            )
            let databaseQueue = try environment.openDatabase()
            self.init(
                databaseQueue: databaseQueue,
                appServerClient: environment.appServerClient,
                downloadsDirectory: environment.downloadsDirectory
            )
        } catch {
            let databaseQueue = try! DatabaseQueue()
            try! DatabaseSchemaFactory.initialize(databaseQueue)
            self.init(
                databaseQueue: databaseQueue,
                appServerClient: MailiaHimalayaExecutableSettings.appServerClient(),
                downloadsDirectory: Self.defaultDownloadsDirectory()
            )
        }
    }

    init(
        databaseQueue: DatabaseQueue,
        appServerClient: MailAppServerClient,
        downloadsDirectory: URL,
        policy: SyncPolicy = SyncPolicy(),
        appServerRequestLimiter: MailAppServerRequestLimiter? = nil,
        himalayaConfigStore: HimalayaConfigStore = HimalayaConfigStore(),
        revealDownloadedFiles: @MainActor @escaping ([URL], URL) -> Void = Self.revealInFinder,
        backgroundFolderRefreshMinimumInterval: TimeInterval = 300,
        backgroundMailboxMaintenanceDelayNanoseconds: UInt64 = 1_000_000_000,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let requestLimiter = appServerRequestLimiter
            ?? MailAppServerRequestLimiter(maxConcurrentRequests: policy.maxConcurrentHimalayaProcesses)
        self.databaseQueue = databaseQueue
        self.repository = MailRepository(databaseQueue: databaseQueue)
        self.appServerClient = appServerClient
        self.himalayaConfigStore = himalayaConfigStore
        self.appServerRequestLimiter = requestLimiter
        self.downloadsDirectory = downloadsDirectory
        self.revealDownloadedFiles = revealDownloadedFiles
        self.backgroundFolderRefreshGate = BackgroundFolderRefreshGate(
            minimumInterval: backgroundFolderRefreshMinimumInterval
        )
        self.backgroundMailboxMaintenanceDelayNanoseconds = backgroundMailboxMaintenanceDelayNanoseconds
        self.nowProvider = now
        self.syncService = SyncService(
            appServerClient: appServerClient,
            databaseQueue: databaseQueue,
            policy: policy,
            appServerRequestLimiter: requestLimiter,
            now: now
        )
    }

    func loadSnapshot(workspace: MailiaWorkspace, searchQuery: String) async throws -> MailiaSnapshot {
        try await measureMainActorTiming(
            operation: "app.load_snapshot",
            fields: [
                .label("workspace", workspace.coreWorkspace.rawValue),
                .label("search_active", !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ]
        ) {
            let entities = try repository.entityList(workspace: workspace.coreWorkspace)
            let sendAccounts = try localSendAccounts()
            return MailiaSnapshot(
                entities: filterAndMap(entities, workspace: workspace, searchQuery: searchQuery),
                sendAccounts: sendAccounts,
                loadedAt: Date()
            )
        }
    }

    func lastRefreshFinishedAt() async throws -> Date? {
        try repository.lastSuccessfulRefreshFinishedAt()
    }

    func recipientSuggestions() async throws -> [MailiaRecipientSuggestion] {
        let limit = 1_000
        let entities = try repository.entityList(workspace: .main)
            + repository.entityList(workspace: .junk)

        var seen = Set<String>()
        var suggestions: [MailiaRecipientSuggestion] = []
        suggestions.reserveCapacity(min(limit, entities.count))

        for entity in entities {
            let displayName = entity.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let addresses = ([entity.primaryEmailAddress].compactMap { $0 } + entity.emailAddresses)
            for address in addresses {
                let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = trimmed.lowercased()
                guard !trimmed.isEmpty,
                      !Self.isNonReplyableAddress(trimmed),
                      seen.insert(normalized).inserted
                else { continue }
                suggestions.append(
                    MailiaRecipientSuggestion(
                        id: normalized,
                        name: displayName.isEmpty ? trimmed : displayName,
                        email: trimmed,
                        entityID: entity.id,
                        avatarImageDataURL: nil
                    )
                )
                if suggestions.count >= limit { return suggestions }
            }
        }

        let sendAccounts = try await loadSendAccounts()
        for account in sendAccounts {
            guard suggestions.count < limit,
                  let email = account.emailAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !email.isEmpty
            else { continue }

            let normalized = email.lowercased()
            guard !Self.isNonReplyableAddress(email),
                  seen.insert(normalized).inserted
            else { continue }

            let displayName = account.displayName?.nilIfBlank ?? account.label
            suggestions.append(
                MailiaRecipientSuggestion(
                    id: normalized,
                    name: displayName,
                    email: email,
                    entityID: Self.syntheticEntityID(forNormalizedEmail: normalized),
                    avatarImageDataURL: nil
                )
            )
        }

        return suggestions
    }

    private static func syntheticEntityID(forNormalizedEmail email: String) -> Int64 {
        Int64(truncatingIfNeeded: email.unicodeScalars.reduce(5381) { partial, scalar in
            (partial &* 33) &+ Int(scalar.value)
        })
    }

    /// Heuristically detects machine-only mailboxes (no-reply / notifications / system senders)
    /// that should never appear as compose suggestions.
    private static func isNonReplyableAddress(_ address: String) -> Bool {
        let localPart = address.split(separator: "@").first.map(String.init)?.lowercased()
            ?? address.lowercased()
        // Collapse separators so "no-reply", "no_reply", "no.reply" all match "noreply".
        let collapsed = localPart.filter { $0.isLetter || $0.isNumber }
        let blockedSubstrings = [
            "noreply",
            "donotreply",
            "notification",
            "notifications",
            "mailerdaemon",
            "postmaster",
            "automailer",
            "autoreply"
        ]
        return blockedSubstrings.contains { collapsed.contains($0) }
    }

    private func fetchSendAccounts() async throws -> [MailiaSendAccount] {
        let existingAccounts = try repository.accounts()
        do {
            _ = try await syncService.discoverAccounts(timeout: 15)
        } catch {
            guard !existingAccounts.isEmpty else { throw error }
            NSLog("Unable to refresh configured accounts: \(error.localizedDescription)")
        }
        let storedAccounts = try repository.accounts()
        return Self.sortedSendAccounts(storedAccounts.map(MailiaSendAccount.init))
    }

    private func localSendAccounts() throws -> [MailiaSendAccount] {
        try Self.sortedSendAccounts(repository.accounts().map(MailiaSendAccount.init))
    }

    private static func sortedSendAccounts(_ accounts: [MailiaSendAccount]) -> [MailiaSendAccount] {
        accounts.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault {
                return lhs.isDefault
            }

            switch (lhs.sortOrder, rhs.sortOrder) {
            case let (left?, right?) where left != right:
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
        }
    }

    func loadSendAccounts() async throws -> [MailiaSendAccount] {
        try await fetchSendAccounts()
    }

    func updateAccountSettings(_ updates: [MailiaAccountSettingsUpdate]) async throws {
        guard !updates.isEmpty else { return }

        for update in updates {
            if let displayName = update.displayName {
                try himalayaConfigStore.setAccountDisplayName(
                    accountKey: update.accountKey,
                    displayName: displayName.nilIfBlank
                )
            }

            if let emoji = update.emoji {
                try repository.updateAccountEmoji(
                    accountKey: update.accountKey,
                    emoji: MailiaSendAccount.normalizedEmoji(emoji)
                )
            }

            if let sortOrder = update.sortOrder {
                try repository.updateAccountSortOrder(
                    accountKey: update.accountKey,
                    sortOrder: sortOrder
                )
            }
        }

        if let defaultAccountKey = updates.first(where: { $0.isDefault == true })?.accountKey {
            try himalayaConfigStore.setDefaultAccount(accountKey: defaultAccountKey)
        }

        _ = try await syncService.discoverAccounts(timeout: 15)
    }

    func messageBodyCacheStats() async throws -> CacheStats {
        try repository.messageBodyCacheStats()
    }

    func clearMessageBodyCache() async throws {
        try repository.clearMessageBodyCache()
    }

    func refresh(
        workspace: MailiaWorkspace,
        searchQuery: String,
        options: MailiaRefreshOptions,
        progress: @escaping @MainActor (MailiaRefreshProgress) -> Void
    ) async throws -> MailiaSnapshot {
        try await measureMainActorTiming(
            operation: "app.refresh",
            fields: [
                .label("workspace", workspace.coreWorkspace.rawValue),
                .label("full_history", options.fullHistory),
                .label("preferred_account_count", options.preferredAccountKeys.count),
                .label("search_active", !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ]
        ) {
            progress(MailiaRefreshProgress(
                phase: .discovering,
                title: "Discovering mailboxes",
                detail: nil,
                fraction: nil
            ))
            let shouldRefreshKnownFoldersInBackground: Bool
            if try repository.folders().isEmpty {
                shouldRefreshKnownFoldersInBackground = false
                do {
                    _ = try await syncService.discoverFoldersForRefresh(
                        timeout: 45,
                        source: "blocking_initial"
                    )
                } catch let error as CancellationError {
                    throw error
                } catch {
                    throw MailiaSyncFailure.mailboxDiscoveryFailed(error)
                }
            } else {
                shouldRefreshKnownFoldersInBackground = true
            }

            let aggregator = RefreshProgressAggregator()
            let report: @Sendable (SyncWorkspaceProgress) -> Void = { workspaceProgress in
                Task { @MainActor in
                    progress(await aggregator.update(workspaceProgress))
                }
            }

            let mainAccountPriorityScores = try refreshAccountPriorityScores(
                workspace: .main,
                preferredAccountKeys: options.preferredAccountKeys
            )
            let junkAccountPriorityScores = try refreshAccountPriorityScores(
                workspace: .junk,
                preferredAccountKeys: options.preferredAccountKeys
            )
            let syncTimeout: TimeInterval = options.fullHistory ? 300 : 45
            var shouldRefreshRemainingMailboxesInBackground = false

            if options.fullHistory {
                async let mainSync: SyncWorkspaceResult = syncService.syncWorkspaceResult(
                    .main,
                    accountPriorityScores: mainAccountPriorityScores,
                    fullHistory: true,
                    timeout: syncTimeout,
                    onProgress: report
                )
                async let junkSync: SyncWorkspaceResult = syncService.syncWorkspaceResult(
                    .junk,
                    accountPriorityScores: junkAccountPriorityScores,
                    fullHistory: true,
                    timeout: syncTimeout,
                    onProgress: report
                )
                let syncResults = try await (mainSync, junkSync)
                if syncResults.0.hadFailure || syncResults.1.hadFailure {
                    throw MailiaSyncFailure.mailboxSyncFailed
                }
            } else {
                let currentWorkspace = workspace.coreWorkspace
                let currentAccountPriorityScores = currentWorkspace == .junk
                    ? junkAccountPriorityScores
                    : mainAccountPriorityScores
                let currentSync = try await syncService.syncWorkspaceResult(
                    currentWorkspace,
                    accountPriorityScores: currentAccountPriorityScores,
                    fullHistory: false,
                    timeout: syncTimeout,
                    onProgress: report
                )
                if currentSync.hadFailure {
                    throw MailiaSyncFailure.mailboxSyncFailed
                }
                shouldRefreshRemainingMailboxesInBackground = true
            }

            progress(MailiaRefreshProgress(
                phase: .finishing,
                title: "Updating",
                detail: nil,
                fraction: nil
            ))
            let snapshot = try await loadSnapshot(workspace: workspace, searchQuery: searchQuery)
            if shouldRefreshRemainingMailboxesInBackground {
                refreshRemainingMailboxesInBackground(
                    currentWorkspace: workspace.coreWorkspace,
                    timeout: syncTimeout,
                    refreshKnownFolders: shouldRefreshKnownFoldersInBackground,
                    mainAccountPriorityScores: mainAccountPriorityScores,
                    junkAccountPriorityScores: junkAccountPriorityScores
                )
            }
            return snapshot
        }
    }

    private func refreshRemainingMailboxesInBackground(
        currentWorkspace: Workspace,
        timeout: TimeInterval,
        refreshKnownFolders: Bool,
        mainAccountPriorityScores: [String: Int],
        junkAccountPriorityScores: [String: Int]
    ) {
        Task { [backgroundFolderRefreshGate, backgroundMailboxMaintenanceDelayNanoseconds, nowProvider, syncService] in
            if backgroundMailboxMaintenanceDelayNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: backgroundMailboxMaintenanceDelayNanoseconds)
                } catch {
                    return
                }
            }

            if refreshKnownFolders {
                let startedAt = Date()
                let decision = await backgroundFolderRefreshGate.begin(now: nowProvider())
                guard decision == .start else {
                    MailiaTiming.log(
                        operation: "sync.discover_folders_all",
                        startedAt: startedAt,
                        status: "skipped",
                        fields: [
                            .label("source", "background_refresh"),
                            .label("skip_reason", decision.rawValue)
                        ]
                    )
                    return
                }
                do {
                    _ = try await syncService.discoverFoldersForRefresh(
                        timeout: timeout,
                        source: "background_refresh"
                    )
                    await backgroundFolderRefreshGate.finish()
                } catch let error as CancellationError {
                    await backgroundFolderRefreshGate.finish()
                    _ = error
                    return
                } catch {
                    await backgroundFolderRefreshGate.finish()
                    NSLog("Unable to refresh mailbox list in background: \(error.localizedDescription)")
                }
            }

            for workspace in Self.backgroundSyncWorkspaces(after: currentWorkspace) {
                do {
                    let scores = workspace == .junk ? junkAccountPriorityScores : mainAccountPriorityScores
                    _ = try await syncService.syncWorkspaceResult(
                        workspace,
                        accountPriorityScores: scores,
                        fullHistory: false,
                        timeout: timeout
                    )
                } catch let error as CancellationError {
                    _ = error
                    return
                } catch {
                    NSLog("Unable to refresh \(workspace.rawValue) mailbox in background: \(error.localizedDescription)")
                }
            }
        }
    }

    nonisolated private static func backgroundSyncWorkspaces(after currentWorkspace: Workspace) -> [Workspace] {
        [.main, .junk].filter { $0 != currentWorkspace }
    }

    private func refreshAccountPriorityScores(
        workspace: MailiaWorkspace,
        preferredAccountKeys: [String]
    ) throws -> [String: Int] {
        var scores: [String: Int] = [:]

        func raise(_ accountKey: String, score: Int) {
            let accountKey = accountKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !accountKey.isEmpty else { return }
            scores[accountKey] = max(scores[accountKey] ?? 0, score)
        }

        var preferredScore = 10_000
        for accountKey in preferredAccountKeys {
            raise(accountKey, score: preferredScore)
            preferredScore -= 1
        }

        for account in try repository.accounts() where account.isDefault {
            raise(account.accountKey, score: 9_000)
        }

        var recentScore = 8_000
        for entity in try repository.entityList(workspace: workspace.coreWorkspace).prefix(200) {
            for accountKey in entity.accountKeys {
                raise(accountKey, score: recentScore)
            }
            recentScore = max(1, recentScore - 1)
        }

        return scores
    }

    func refreshAfterSendingMessage(
        accountKeys: Set<String>,
        workspace: MailiaWorkspace,
        searchQuery: String
    ) async throws -> MailiaSnapshot {
        let normalizedAccountKeys = Set(
            accountKeys
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )

        if !normalizedAccountKeys.isEmpty {
            for accountKey in normalizedAccountKeys {
                do {
                    _ = try await syncService.discoverFolders(
                        accountKey: accountKey,
                        timeout: 15,
                        source: "after_send"
                    )
                } catch {
                    NSLog("Unable to refresh folders for \(accountKey): \(error.localizedDescription)")
                }
            }

            let result = try await syncService.syncWorkspaceResult(
                .main,
                accountKeys: normalizedAccountKeys,
                folderRoles: [.normal, .sent],
                timeout: 30
            )
            if result.hadFailure {
                throw MailiaSyncFailure.mailboxSyncFailed
            }
        }

        return try await loadSnapshot(workspace: workspace, searchQuery: searchQuery)
    }

    func refreshNewerTimelineMessages(
        accountKeys: Set<String>,
        workspace: MailiaWorkspace,
        searchQuery: String
    ) async throws -> MailiaSnapshot {
        let normalizedAccountKeys = Self.normalizedAccountKeys(accountKeys)
        let folderRoles = Set(WorkspacePolicy.visibleRoles(for: workspace.coreWorkspace))

        if !normalizedAccountKeys.isEmpty {
            let existingFolderCount = try syncableFolderCount(
                workspace: workspace.coreWorkspace,
                accountKeys: normalizedAccountKeys,
                folderRoles: folderRoles
            )

            if existingFolderCount == 0 {
                for accountKey in normalizedAccountKeys {
                    do {
                        _ = try await syncService.discoverFolders(
                            accountKey: accountKey,
                            timeout: 15,
                            source: "newer_timeline_empty_cache"
                        )
                    } catch {
                        NSLog("Unable to refresh folders for \(accountKey): \(error.localizedDescription)")
                    }
                }
            }

            let syncableFolderCount = try syncableFolderCount(
                workspace: workspace.coreWorkspace,
                accountKeys: normalizedAccountKeys,
                folderRoles: folderRoles
            )
            if syncableFolderCount > 0 {
                let result = try await syncService.syncWorkspaceResult(
                    workspace.coreWorkspace,
                    accountKeys: normalizedAccountKeys,
                    folderRoles: folderRoles,
                    timeout: 30
                )
                if result.hadFailure {
                    throw MailiaSyncFailure.mailboxSyncFailed
                }
            }
        }

        return try await loadSnapshot(workspace: workspace, searchQuery: searchQuery)
    }

    private static func normalizedAccountKeys(_ accountKeys: Set<String>) -> Set<String> {
        Set(
            accountKeys
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private func syncableFolderCount(
        workspace: Workspace,
        accountKeys: Set<String>,
        folderRoles: Set<FolderRole>
    ) throws -> Int {
        try repository.folders(for: workspace).filter { folder in
            accountKeys.contains(folder.accountKey) && folderRoles.contains(folder.role)
        }.count
    }

    func syncEntityHistory(
        emailAddresses: Set<String>,
        workspace: MailiaWorkspace,
        searchQuery: String,
        progress: @escaping @MainActor (MailiaRefreshProgress) -> Void
    ) async throws -> MailiaSnapshot {
        try await measureMainActorTiming(
            operation: "app.sync_entity_history",
            fields: [
                .label("workspace", workspace.coreWorkspace.rawValue),
                .label("address_count", emailAddresses.count),
                .label("search_active", !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ]
        ) {
            progress(MailiaRefreshProgress(
                phase: .discovering,
                title: "Discovering mailboxes",
                detail: nil,
                fraction: nil
            ))
            do {
                _ = try await syncService.discoverFoldersForDiscoveredAccounts(
                    timeout: 45,
                    source: "entity_history"
                )
            } catch let error as CancellationError {
                throw error
            } catch {
                NSLog("Unable to refresh mailbox list before entity sync: \(error.localizedDescription)")
            }

            let aggregator = RefreshProgressAggregator()
            let report: @Sendable (SyncWorkspaceProgress) -> Void = { workspaceProgress in
                Task { @MainActor in
                    progress(await aggregator.update(workspaceProgress))
                }
            }

            _ = try await syncService.syncEntityHistory(
                workspace.coreWorkspace,
                emailAddresses: emailAddresses,
                timeout: 300,
                onProgress: report
            )

            progress(MailiaRefreshProgress(
                phase: .finishing,
                title: "Updating conversations",
                detail: nil,
                fraction: nil
            ))

            return try await loadSnapshot(workspace: workspace, searchQuery: searchQuery)
        }
    }

    func loadTimelinePage(
        entityID: Int64,
        workspace: MailiaWorkspace,
        direction: MailiaTimelinePageDirection,
        anchorID: Int64?,
        limit: Int
    ) async throws -> MailiaTimelinePage {
        try await measureMainActorTiming(
            operation: "app.load_timeline_page",
            fields: [
                .label("workspace", workspace.coreWorkspace.rawValue),
                .label("direction", String(describing: direction)),
                .label("limit", limit),
                .label("has_anchor", anchorID != nil)
            ]
        ) {
            let fetchLimit = limit + 1
            let messages = try repository.messages(
                entityID: entityID,
                workspace: workspace.coreWorkspace,
                includeBodies: false,
                limit: fetchLimit,
                beforeMessageID: direction == .older ? anchorID : nil,
                afterMessageID: direction == .newer ? anchorID : nil
            )
            let hasMore = messages.count > limit
            let pageMessages: [TimelineMessage]
            switch direction {
            case .latest, .older:
                pageMessages = hasMore ? Array(messages.suffix(limit)) : messages
            case .newer:
                pageMessages = hasMore ? Array(messages.prefix(limit)) : messages
            }
            let emojiByAccount: [String: String] = Dictionary(
                uniqueKeysWithValues: try repository.accounts().compactMap { account -> (String, String)? in
                    guard let emoji = account.emoji?.nilIfBlank else { return nil }
                    return (account.accountKey, emoji)
                }
            )
            let items = pageMessages.map { message in
                makeTimelineItem(message: message, entityID: entityID, emojiByAccount: emojiByAccount)
            }
            return MailiaTimelinePage(items: items, hasMore: hasMore)
        }
    }

    func loadLatestTimelineItems(entityIDs: [Int64], workspace: MailiaWorkspace) async throws -> [MailiaTimelineItem] {
        try await measureMainActorTiming(
            operation: "app.load_latest_timeline_items",
            fields: [
                .label("workspace", workspace.coreWorkspace.rawValue),
                .label("requested_count", entityIDs.count)
            ]
        ) {
            var seenEntityIDs = Set<Int64>()
            let uniqueEntityIDs = entityIDs.filter { seenEntityIDs.insert($0).inserted }
            guard !uniqueEntityIDs.isEmpty else { return [] }

            let emojiByAccount: [String: String] = Dictionary(
                uniqueKeysWithValues: try repository.accounts().compactMap { account -> (String, String)? in
                    guard let emoji = account.emoji?.nilIfBlank else { return nil }
                    return (account.accountKey, emoji)
                }
            )

            let messagesByEntityID = try repository.latestMessages(
                entityIDs: uniqueEntityIDs,
                workspace: workspace.coreWorkspace
            )
            return uniqueEntityIDs.compactMap { entityID in
                guard let message = messagesByEntityID[entityID] else { return nil }
                return makeTimelineItem(message: message, entityID: entityID, emojiByAccount: emojiByAccount)
            }
        }
    }

    func loadBody(for item: MailiaTimelineItem) async throws -> MailiaTimelineBody {
        try await measureMainActorTiming(
            operation: "app.load_body",
            fields: [.label("has_attachment_flag", item.hasAttachments)]
        ) {
            if let cached = try repository.messageBody(messageID: item.id),
               let body = try cachedTimelineBody(cached, item: item) {
                return body
            }

            let locations = try bodyFetchLocations(for: item)
            guard !locations.isEmpty else {
                return unavailableTimelineBody(item: item)
            }

            var lastBody: MessageBodyFetchResult?
            for location in locations {
                let body: MessageBodyFetchResult
                do {
                    body = try await fetchBody(
                        messageID: item.id,
                        accountKey: location.accountKey,
                        folderName: location.sourceFolderName,
                        envelopeID: location.himalayaEnvelopeID
                    )
                } catch {
                    guard Self.shouldMarkMessageLocationMissing(for: error) else {
                        throw error
                    }
                    continue
                }
                if body.hasAttachments {
                    try repository.setMessageHasAttachments(messageID: item.id, hasAttachments: true)
                }
                guard body.hasDisplayContent else {
                    lastBody = body
                    continue
                }

                try repository.cacheMessageBody(
                    messageID: item.id,
                    sanitizedHTML: body.sanitizedHTML,
                    htmlVariants: body.htmlVariants,
                    textFallback: body.textFallback
                )
                return MailiaTimelineBody(
                    html: body.sanitizedHTML?.nilIfBlank,
                    htmlVariants: MailiaTimelineHTMLVariants(body.htmlVariants),
                    hasAttachments: item.hasAttachments || body.hasAttachments
                )
            }

            let body = lastBody ?? MessageBodyFetchResult(
                sanitizedHTML: nil,
                htmlVariants: nil,
                textFallback: nil,
                hasAttachments: false
            )
            try repository.cacheMessageBody(
                messageID: item.id,
                sanitizedHTML: body.sanitizedHTML,
                htmlVariants: body.htmlVariants,
                textFallback: body.textFallback
            )
            if body.sanitizedHTML?.nilIfBlank == nil {
                return unavailableTimelineBody(item: item)
            }
            return MailiaTimelineBody(
                html: body.sanitizedHTML?.nilIfBlank,
                htmlVariants: MailiaTimelineHTMLVariants(body.htmlVariants),
                hasAttachments: item.hasAttachments || body.hasAttachments
            )
        }
    }

    private func cachedTimelineBody(_ cached: TimelineMessageBody, item: MailiaTimelineItem) throws -> MailiaTimelineBody? {
        guard let html = cached.sanitizedHTML?.nilIfBlank else {
            return nil
        }

        return MailiaTimelineBody(
            html: html,
            htmlVariants: MailiaTimelineHTMLVariants(cached.htmlVariants),
            hasAttachments: item.hasAttachments
        )
    }

    private func bodyFetchLocations(for item: MailiaTimelineItem) throws -> [MessageLocationTarget] {
        var locations = try repository.messageLocations(messageID: item.id)
        if let folderName = item.folderLabel.nilIfBlank,
           let envelopeID = item.envelopeID.nilIfBlank {
            let preferred = MessageLocationTarget(
                messageID: item.id,
                accountKey: item.accountLabel,
                sourceFolderName: folderName,
                sourceFolderRole: .unknown,
                himalayaEnvelopeID: envelopeID
            )
            locations.removeAll {
                $0.accountKey == preferred.accountKey &&
                $0.sourceFolderName == preferred.sourceFolderName &&
                $0.himalayaEnvelopeID == preferred.himalayaEnvelopeID
            }
            locations.insert(preferred, at: 0)
        }
        return locations
    }

    private func unavailableTimelineBody(item: MailiaTimelineItem) -> MailiaTimelineBody {
        MailiaTimelineBody(html: nil, hasAttachments: item.hasAttachments)
    }

    private enum EntityActionOperation: Sendable {
        case flag(isEnabled: Bool)
        case move(targetFoldersByAccount: [String: String])

        func shouldRun(for location: MessageLocationTarget) -> Bool {
            switch self {
            case .flag:
                return true
            case let .move(targetFoldersByAccount):
                guard let targetFolderName = targetFoldersByAccount[location.accountKey],
                      targetFolderName != location.sourceFolderName
                else {
                    return false
                }
                return true
            }
        }

        func perform(
            location: MessageLocationTarget,
            appServerClient: MailAppServerClient,
            timeout: TimeInterval?
        ) async throws {
            switch self {
            case let .flag(isEnabled):
                _ = try await appServerClient.messageModify(
                    id: location.himalayaEnvelopeID,
                    folder: location.sourceFolderName,
                    account: location.accountKey,
                    addFlags: isEnabled ? ["flagged"] : [],
                    removeFlags: isEnabled ? [] : ["flagged"],
                    timeout: timeout
                )
            case let .move(targetFoldersByAccount):
                guard let targetFolderName = targetFoldersByAccount[location.accountKey],
                      targetFolderName != location.sourceFolderName
                else {
                    return
                }
                _ = try await appServerClient.messageModify(
                    id: location.himalayaEnvelopeID,
                    folder: location.sourceFolderName,
                    account: location.accountKey,
                    moveTo: targetFolderName,
                    timeout: timeout
                )
            }
        }
    }

    private struct EntityActionLocationResult: Sendable {
        var location: MessageLocationTarget
        var didRunCommand: Bool
        var failureDescription: String?
    }

    func performEntityAction(
        _ action: MailiaEntityAction,
        entityID: Int64,
        workspace: MailiaWorkspace,
        progress: @escaping @MainActor (String) -> Void
    ) async throws {
        progress("Discovering folders...")
        _ = try await syncService.discoverFoldersForDiscoveredAccounts(
            timeout: 45,
            source: "entity_action"
        )
        let locations = try repository.messageLocations(
            entityID: entityID,
            workspace: workspace.coreWorkspace,
            sourceRoles: EntityActionPolicy.sourceRoles(for: action)
        )
        guard !locations.isEmpty else {
            throw EntityActionError.noMessages
        }

        switch action {
        case .flagImportant:
            try await performBatchEntityAction(
                action: action,
                locations: locations,
                operation: .flag(isEnabled: true),
                progress: progress
            )
            return
        case .removeFlag:
            try await performBatchEntityAction(
                action: action,
                locations: locations,
                operation: .flag(isEnabled: false),
                progress: progress
            )
            return
        case .moveToInbox, .moveToJunk, .moveToTrash:
            break
        }

        guard let targetRole = EntityActionPolicy.targetRole(for: action) else { return }
        var targetFoldersByAccount: [String: String] = [:]
        for accountKey in Set(locations.map(\.accountKey)) {
            guard let targetFolderName = try repository.targetFolderName(
                accountKey: accountKey,
                role: targetRole
            ) else {
                throw EntityActionError.missingTargetFolder(accountKey: accountKey, role: targetRole)
            }
            targetFoldersByAccount[accountKey] = targetFolderName
        }
        try await performBatchEntityAction(
            action: action,
            locations: locations,
            operation: .move(targetFoldersByAccount: targetFoldersByAccount),
            progress: progress
        )
    }

    func markEntityRead(entityID: Int64, workspace: MailiaWorkspace) async throws {
        let locations = try repository.messageLocations(
            entityID: entityID,
            workspace: workspace.coreWorkspace,
            onlyUnread: true
        )
        guard !locations.isEmpty else { return }

        let results = await runMarkReadCommands(locations: locations)
        let failures = try applyMarkReadResults(results)

        if let firstFailure = failures.first {
            throw EntityActionError.partialFailure(
                failed: failures.count,
                total: locations.count,
                firstFailure: firstFailure
            )
        }
    }

    func markMessageRead(item: MailiaTimelineItem, workspace: MailiaWorkspace) async throws {
        let locations = try repository.messageLocations(messageID: item.id)
        guard !locations.isEmpty else { return }

        var failures: [String] = []
        for location in locations {
            do {
                try await markMessageReadRemotely(location)
                let didUpdate = try repository.setMessageLocationFlag(
                    accountKey: location.accountKey,
                    folderName: location.sourceFolderName,
                    himalayaEnvelopeID: location.himalayaEnvelopeID,
                    flag: "seen",
                    isEnabled: true
                )
                if !didUpdate {
                    failures.append("No matching message location was found for \(location.himalayaEnvelopeID).")
                }
            } catch {
                failures.append(Self.errorDescription(error))
            }
        }

        if let firstFailure = failures.first {
            throw EntityActionError.partialFailure(
                failed: failures.count,
                total: locations.count,
                firstFailure: firstFailure
            )
        }
    }

    func markMessagesRead(items: [MailiaTimelineItem], workspace: MailiaWorkspace) async throws -> Int {
        var seenMessageIDs = Set<Int64>()
        let uniqueItems = items.filter { seenMessageIDs.insert($0.id).inserted }
        guard !uniqueItems.isEmpty else { return 0 }

        var changedCount = 0
        var failures: [String] = []
        var totalLocationCount = 0

        for item in uniqueItems {
            let locations = try repository.messageLocations(messageID: item.id, onlyUnread: true)
            guard !locations.isEmpty else { continue }

            totalLocationCount += locations.count
            let results = await runMarkReadCommands(locations: locations)
            let itemFailures = try applyMarkReadResults(results)

            if itemFailures.isEmpty {
                changedCount += 1
            } else {
                failures.append(contentsOf: itemFailures)
            }
        }

        if let firstFailure = failures.first {
            throw EntityActionError.partialFailure(
                failed: failures.count,
                total: max(totalLocationCount, failures.count),
                firstFailure: firstFailure
            )
        }

        return changedCount
    }

    private func runMarkReadCommands(locations: [MessageLocationTarget]) async -> [EntityActionLocationResult] {
        let groupedLocations = Dictionary(grouping: locations) { location in
            "\(location.accountKey)\u{1F}\(location.messageID)"
        }
        .values
        .map { group in
            group.sorted {
                if $0.sourceFolderName == $1.sourceFolderName {
                    $0.himalayaEnvelopeID < $1.himalayaEnvelopeID
                } else {
                    $0.sourceFolderName < $1.sourceFolderName
                }
            }
        }

        let appServerClient = appServerClient
        let requestLimiter = appServerRequestLimiter
        return await withTaskGroup(of: [EntityActionLocationResult].self) { group in
            for locationGroup in groupedLocations {
                group.addTask {
                    guard Self.shouldCoalesceMarkReadLocationGroup(locationGroup) else {
                        var groupResults: [EntityActionLocationResult] = []
                        for location in locationGroup {
                            do {
                                try await Self.markMessageReadRemotely(
                                    location,
                                    appServerClient: appServerClient,
                                    requestLimiter: requestLimiter
                                )
                                groupResults.append(EntityActionLocationResult(
                                    location: location,
                                    didRunCommand: true,
                                    failureDescription: nil
                                ))
                            } catch {
                                groupResults.append(EntityActionLocationResult(
                                    location: location,
                                    didRunCommand: true,
                                    failureDescription: Self.errorDescription(error)
                                ))
                            }
                        }
                        return groupResults
                    }

                    guard let remoteLocation = Self.preferredMarkReadRemoteLocation(in: locationGroup) else {
                        return []
                    }

                    do {
                        try await Self.markMessageReadRemotely(
                            remoteLocation,
                            appServerClient: appServerClient,
                            requestLimiter: requestLimiter
                        )
                        return locationGroup.map { location in
                            EntityActionLocationResult(
                                location: location,
                                didRunCommand: true,
                                failureDescription: nil
                            )
                        }
                    } catch {
                        let failure = Self.errorDescription(error)
                        return locationGroup.map { location in
                            EntityActionLocationResult(
                                location: location,
                                didRunCommand: location == remoteLocation,
                                failureDescription: failure
                            )
                        }
                    }
                }
            }

            var results: [EntityActionLocationResult] = []
            for await groupResults in group {
                results += groupResults
            }
            return results
        }
    }

    nonisolated private static func shouldCoalesceMarkReadLocationGroup(
        _ locations: [MessageLocationTarget]
    ) -> Bool {
        locations.contains { location in
            location.sourceFolderName.lowercased().hasPrefix("[gmail]/")
        }
    }

    nonisolated private static func preferredMarkReadRemoteLocation(
        in locations: [MessageLocationTarget]
    ) -> MessageLocationTarget? {
        locations.sorted(by: markReadRemoteLocationPrecedes).first
    }

    nonisolated private static func markReadRemoteLocationPrecedes(
        _ lhs: MessageLocationTarget,
        _ rhs: MessageLocationTarget
    ) -> Bool {
        let lhsRank = markReadRemoteLocationRank(lhs)
        let rhsRank = markReadRemoteLocationRank(rhs)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        if lhs.sourceFolderName != rhs.sourceFolderName {
            return lhs.sourceFolderName.localizedStandardCompare(rhs.sourceFolderName) == .orderedAscending
        }
        return lhs.himalayaEnvelopeID.localizedStandardCompare(rhs.himalayaEnvelopeID) == .orderedAscending
    }

    nonisolated private static func markReadRemoteLocationRank(_ location: MessageLocationTarget) -> Int {
        let folder = location.sourceFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedFolder = folder.lowercased()
        if lowercasedFolder == "inbox" {
            return 0
        }
        if !lowercasedFolder.hasPrefix("[gmail]/") && location.sourceFolderRole == .normal {
            return 1
        }
        if lowercasedFolder.contains("all mail") || lowercasedFolder.contains("所有邮件") {
            return 3
        }
        if lowercasedFolder.contains("important") || lowercasedFolder.contains("重要") {
            return 4
        }
        return 2
    }

    private func applyMarkReadResults(_ results: [EntityActionLocationResult]) throws -> [String] {
        var failures = results.compactMap(\.failureDescription)
        for result in results where result.failureDescription == nil && result.didRunCommand {
            let didUpdate = try repository.setMessageLocationFlag(
                accountKey: result.location.accountKey,
                folderName: result.location.sourceFolderName,
                himalayaEnvelopeID: result.location.himalayaEnvelopeID,
                flag: "seen",
                isEnabled: true
            )
            if !didUpdate {
                failures.append("No matching message location was found for \(result.location.himalayaEnvelopeID).")
            }
        }
        return failures
    }

    nonisolated private static func markMessageReadRemotely(
        _ location: MessageLocationTarget,
        appServerClient: MailAppServerClient,
        requestLimiter: MailAppServerRequestLimiter
    ) async throws {
        let maxAttempts = 3
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                try await requestLimiter.run(priority: .backgroundSync, timingMethod: "message_modify") {
                    _ = try await appServerClient.messageModify(
                        id: location.himalayaEnvelopeID,
                        folder: location.sourceFolderName,
                        account: location.accountKey,
                        addFlags: ["seen"],
                        timeout: 30
                    )
                }
                return
            } catch {
                lastError = error
                guard attempt < maxAttempts else {
                    throw error
                }

                let delay = UInt64(attempt) * 500_000_000
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        if let lastError {
            throw lastError
        }
    }

    private func markMessageReadRemotely(_ location: MessageLocationTarget) async throws {
        let maxAttempts = 3
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                try await appServerRequestLimiter.run(priority: .backgroundSync, timingMethod: "message_modify") {
                    _ = try await appServerClient.messageModify(
                        id: location.himalayaEnvelopeID,
                        folder: location.sourceFolderName,
                        account: location.accountKey,
                        addFlags: ["seen"],
                        timeout: 30
                    )
                }
                return
            } catch {
                lastError = error
                guard attempt < maxAttempts else {
                    throw error
                }

                let delay = UInt64(attempt) * 500_000_000
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        if let lastError {
            throw lastError
        }
    }

    private func performBatchEntityAction(
        action: MailiaEntityAction,
        locations: [MessageLocationTarget],
        operation: EntityActionOperation,
        progress: @escaping @MainActor (String) -> Void
    ) async throws {
        let runnableLocations = locations.filter { operation.shouldRun(for: $0) }
        guard !runnableLocations.isEmpty else { return }

        let results = await runEntityActionCommands(
            action: action,
            locations: runnableLocations,
            operation: operation,
            progress: progress
        )
        var failures = results.compactMap(\.failureDescription)

        for result in results where result.failureDescription == nil && result.didRunCommand {
            do {
                switch operation {
                case let .flag(isEnabled):
                    let didUpdate = try repository.setMessageLocationFlag(
                        accountKey: result.location.accountKey,
                        folderName: result.location.sourceFolderName,
                        himalayaEnvelopeID: result.location.himalayaEnvelopeID,
                        flag: "flagged",
                        isEnabled: isEnabled
                    )
                    if !didUpdate {
                        failures.append("No matching message location was found for \(result.location.himalayaEnvelopeID).")
                    }
                case .move:
                    try repository.markMessageLocationMissing(
                        accountKey: result.location.accountKey,
                        folderName: result.location.sourceFolderName,
                        himalayaEnvelopeID: result.location.himalayaEnvelopeID
                    )
                }
            } catch {
                failures.append(Self.errorDescription(error))
            }
        }

        if let firstFailure = failures.first {
            throw EntityActionError.partialFailure(
                failed: failures.count,
                total: runnableLocations.count,
                firstFailure: firstFailure
            )
        }
    }

    private func runEntityActionCommands(
        action: MailiaEntityAction,
        locations: [MessageLocationTarget],
        operation: EntityActionOperation,
        progress: @escaping @MainActor (String) -> Void
    ) async -> [EntityActionLocationResult] {
        let groupedLocations = Dictionary(grouping: locations) { location in
            "\(location.accountKey)\u{1F}\(location.messageID)"
        }
        .values
        .map { group in
            group.sorted {
                if $0.sourceFolderName == $1.sourceFolderName {
                    $0.himalayaEnvelopeID < $1.himalayaEnvelopeID
                } else {
                    $0.sourceFolderName < $1.sourceFolderName
                }
            }
        }
        let totalCount = locations.count
        let appServerClient = appServerClient
        let requestLimiter = appServerRequestLimiter

        progress(action.statusLabel)
        return await withTaskGroup(of: [EntityActionLocationResult].self) { group in
            for locationGroup in groupedLocations {
                group.addTask {
                    var groupResults: [EntityActionLocationResult] = []
                    for location in locationGroup {
                        guard operation.shouldRun(for: location) else {
                            groupResults.append(
                                EntityActionLocationResult(
                                    location: location,
                                    didRunCommand: false,
                                    failureDescription: nil
                                )
                            )
                            continue
                        }

                        do {
                            try await requestLimiter.run(priority: .interactive) {
                                try await operation.perform(
                                    location: location,
                                    appServerClient: appServerClient,
                                    timeout: 30
                                )
                            }
                            groupResults.append(
                                EntityActionLocationResult(
                                    location: location,
                                    didRunCommand: true,
                                    failureDescription: nil
                                )
                            )
                        } catch {
                            groupResults.append(
                                EntityActionLocationResult(
                                    location: location,
                                    didRunCommand: true,
                                    failureDescription: Self.errorDescription(error)
                                )
                            )
                        }
                    }
                    return groupResults
                }
            }

            var results: [EntityActionLocationResult] = []
            for await groupResults in group {
                results += groupResults
                progress(action.progressStatus(current: min(results.count, totalCount), total: totalCount))
            }
            return results
        }
    }

    nonisolated private static func errorDescription(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    func setMessageFlag(item: MailiaTimelineItem, isFlagged: Bool) async throws {
        guard let folderName = item.folderLabel.nilIfBlank,
              let envelopeID = item.envelopeID.nilIfBlank else {
            throw EntityActionError.noMessages
        }

        try await appServerRequestLimiter.run(priority: .interactive) {
            _ = try await appServerClient.messageModify(
                id: envelopeID,
                folder: folderName,
                account: item.accountLabel,
                addFlags: isFlagged ? ["flagged"] : [],
                removeFlags: isFlagged ? [] : ["flagged"],
                timeout: 30
            )
        }
        let didUpdate = try repository.setMessageLocationFlag(
            accountKey: item.accountLabel,
            folderName: folderName,
            himalayaEnvelopeID: envelopeID,
            flag: "flagged",
            isEnabled: isFlagged
        )
        guard didUpdate else {
            throw EntityActionError.noMatchingMessageLocation
        }
    }

    func downloadAttachments(for item: MailiaTimelineItem) async throws -> MailiaAttachmentDownloadResult {
        guard item.hasAttachments else {
            throw EntityActionError.noAttachments
        }
        guard let folderName = item.folderLabel.nilIfBlank,
              let envelopeID = item.envelopeID.nilIfBlank else {
            throw EntityActionError.noMatchingMessageLocation
        }

        let targetDownloadsDirectory = Self.configuredDownloadsDirectory(fallback: downloadsDirectory)
        try FileManager.default.createDirectory(at: targetDownloadsDirectory, withIntermediateDirectories: true)
        let attachments = try await appServerRequestLimiter.run(priority: .userDownload) {
            try await appServerClient.attachmentDownload(
                messageID: envelopeID,
                folder: folderName,
                account: item.accountLabel,
                downloadsDirectory: targetDownloadsDirectory,
                timeout: 300
            )
        }

        let newFileURLs = attachments.map { URL(fileURLWithPath: $0.path) }
        let newFiles = newFileURLs.map(\.lastPathComponent)
        revealDownloadedFiles(newFileURLs, targetDownloadsDirectory)
        return MailiaAttachmentDownloadResult(
            directoryPath: targetDownloadsDirectory.path,
            fileNames: newFiles
        )
    }

    func sendReply(
        to item: MailiaTimelineItem,
        content: MailiaComposerContent,
        replyAll: Bool,
        accountKey: String?
    ) async throws {
        let plainBody = content.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard plainBody.nilIfBlank != nil || content.hasRenderableContent else {
            throw EntityActionError.noMessages
        }

        let sendAccount = try selectedSendAccount(accountKey: accountKey?.nilIfBlank ?? item.accountLabel.nilIfBlank)
        guard let fromAddress = sendAccount.emailAddress?.nilIfBlank else {
            throw EntityActionError.missingSendAccountEmail(accountKey: sendAccount.id)
        }
        let headers = replyHeaders(
            to: item,
            from: MailAddress(displayName: sendAccount.displayName?.nilIfBlank, emailAddress: fromAddress),
            replyAll: replyAll
        )
        guard headers.contains(where: { $0.name.caseInsensitiveCompare("To") == .orderedSame }) else {
            throw EntityActionError.noMessages
        }
        let rawMessage = try OutgoingMessageMIMEBuilder.rawMessage(
            headers: headers,
            content: content
        )
        try await appServerRequestLimiter.run(priority: .interactive) {
            _ = try await appServerClient.messageSend(raw: rawMessage, account: sendAccount.id, timeout: 300)
        }
    }

    func sendNewMessage(
        to recipients: [String],
        subject: String?,
        content: MailiaComposerContent,
        accountKey: String?
    ) async throws {
        let cleanedRecipients = recipients.compactMap(Self.mailHeaderValue)
        guard !cleanedRecipients.isEmpty else {
            throw EntityActionError.noMessages
        }
        let plainBody = content.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard plainBody.nilIfBlank != nil || content.hasRenderableContent else {
            throw EntityActionError.noMessages
        }

        let sendAccount = try selectedSendAccount(accountKey: accountKey?.nilIfBlank)
        guard let fromAddress = sendAccount.emailAddress?.nilIfBlank else {
            throw EntityActionError.missingSendAccountEmail(accountKey: sendAccount.id)
        }
        let rawHeaders = newMessageHeaders(
            from: MailAddress(displayName: sendAccount.displayName?.nilIfBlank, emailAddress: fromAddress),
            recipients: cleanedRecipients,
            subject: subject
        )
        let rawMessage = try OutgoingMessageMIMEBuilder.rawMessage(
            headers: rawHeaders,
            content: content
        )
        try await appServerRequestLimiter.run(priority: .interactive) {
            _ = try await appServerClient.messageSend(raw: rawMessage, account: sendAccount.id, timeout: 300)
        }
    }

    private func selectedSendAccount(accountKey: String?) throws -> MailiaSendAccount {
        let accounts = try localSendAccounts()
        if let accountKey, let account = accounts.first(where: { $0.id == accountKey }) {
            return account
        }
        if let defaultAccount = accounts.first(where: \.isDefault) {
            return defaultAccount
        }
        if let account = accounts.first {
            return account
        }
        throw EntityActionError.noMessages
    }

    private func newMessageHeaders(
        from: MailAddress,
        recipients: [String],
        subject: String?
    ) -> [MailiaEmailHeader] {
        var headers = [
            MailiaEmailHeader(name: "From", value: from.displayLabel),
            MailiaEmailHeader(name: "To", value: recipients.joined(separator: ", "))
        ]
        if let subject = Self.mailHeaderValue(subject) {
            headers.append(MailiaEmailHeader(name: "Subject", value: subject))
        }
        return headers
    }

    private func replyHeaders(
        to item: MailiaTimelineItem,
        from: MailAddress,
        replyAll: Bool
    ) -> [MailiaEmailHeader] {
        let recipients = replyRecipients(for: item, fromAddress: from.emailAddress, replyAll: replyAll)
        var headers = [
            MailiaEmailHeader(name: "From", value: from.displayLabel)
        ]
        if !recipients.to.isEmpty {
            headers.append(MailiaEmailHeader(
                name: "To",
                value: recipients.to.map(\.displayLabel).joined(separator: ", ")
            ))
        }
        if !recipients.cc.isEmpty {
            headers.append(MailiaEmailHeader(
                name: "Cc",
                value: recipients.cc.map(\.displayLabel).joined(separator: ", ")
            ))
        }
        headers.append(MailiaEmailHeader(name: "Subject", value: replySubject(item.subject)))
        if let rfcMessageID = Self.mailHeaderValue(item.rfcMessageID) {
            headers.append(MailiaEmailHeader(name: "In-Reply-To", value: rfcMessageID))
            headers.append(MailiaEmailHeader(name: "References", value: rfcMessageID))
        }
        return headers
    }

    private func replyRecipients(
        for item: MailiaTimelineItem,
        fromAddress: String,
        replyAll: Bool
    ) -> (to: [MailAddress], cc: [MailAddress]) {
        let ownAddress = fromAddress.lowercased()
        let primaryTo: [MailAddress]
        let copyCandidates: [MailAddress]

        switch item.direction {
        case .incoming:
            primaryTo = item.from.map { [$0] } ?? []
            copyCandidates = replyAll ? item.to + item.cc : []
        case .outgoing:
            primaryTo = item.to
            copyCandidates = replyAll ? item.cc : []
        }

        var seen = Set([ownAddress])
        let to = uniqueAddresses(primaryTo, seen: &seen)
        let cc = uniqueAddresses(copyCandidates, seen: &seen)
        return (to, cc)
    }

    private func uniqueAddresses(_ addresses: [MailAddress], seen: inout Set<String>) -> [MailAddress] {
        var result: [MailAddress] = []
        for address in addresses {
            let email = address.emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !email.isEmpty else { continue }
            let key = email.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(MailAddress(displayName: address.displayName?.nilIfBlank, emailAddress: email))
        }
        return result
    }

    private func replySubject(_ subject: String) -> String {
        let value = Self.mailHeaderValue(subject) ?? "(No subject)"
        if value.range(of: #"^\s*(re|回复|答复|回覆)\s*[:：]"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return value
        }
        return "Re: \(value)"
    }

    private static func mailHeaderValue(_ value: String?) -> String? {
        value?
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
    }

    private func makeTimelineItem(
        message: TimelineMessage,
        entityID: Int64,
        emojiByAccount: [String: String] = [:]
    ) -> MailiaTimelineItem {
        MailiaTimelineItem(
            id: message.messageID,
            entityID: entityID,
            direction: message.direction,
            rfcMessageID: message.rfcMessageID,
            subject: message.subject?.nilIfBlank ?? "(No subject)",
            preview: preview(for: message),
            html: message.sanitizedHTML?.nilIfBlank,
            htmlVariants: MailiaTimelineHTMLVariants(message.htmlVariants),
            date: HimalayaDateParser.parse(message.messageDate),
            accountLabel: message.accountKey,
            accountEmoji: emojiByAccount[message.accountKey],
            accountAvatarImageDataURL: nil,
            folderLabel: message.folderName ?? "",
            envelopeID: message.himalayaEnvelopeID ?? "",
            isFlagged: message.flags.contains { $0.caseInsensitiveCompare("flagged") == .orderedSame },
            from: message.from,
            to: message.to,
            cc: message.cc,
            fromLabel: message.from?.displayLabel ?? "",
            toLabel: message.to.map(\.displayLabel).joined(separator: ", "),
            hasAttachments: message.hasAttachments
        )
    }

    private struct MessageBodyFetchResult {
        var sanitizedHTML: String?
        var htmlVariants: EmailHTMLDisplayVariants?
        var textFallback: String?
        var hasAttachments: Bool

        var hasDisplayContent: Bool {
            sanitizedHTML?.nilIfBlank != nil
        }
    }

    private func fetchBody(messageID: Int64, accountKey: String, folderName: String, envelopeID: String) async throws -> MessageBodyFetchResult {
        let exportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailiaExport-\(messageID)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: exportDirectory)
        }

        let bodyFetchFields: [MailiaTimingField] = [
            .redacted("account", accountKey),
            .redacted("folder", folderName)
        ]
        let bodyFetchStartedAt = Date()
        let message: MailAppServerMessageGetResult
        do {
            message = try await appServerRequestLimiter.run(priority: .visibleBody, timingMethod: "message_get") {
                try await appServerClient.messageGet(
                    id: envelopeID,
                    folder: folderName,
                    account: accountKey,
                    timeout: 30
                )
            }
            MailiaTiming.log(
                operation: "body.message_get",
                startedAt: bodyFetchStartedAt,
                fields: bodyFetchFields
            )
        } catch {
            let errorKind = Self.bodyFetchTimingErrorKind(for: error)
            MailiaTiming.log(
                operation: "body.message_get",
                startedAt: bodyFetchStartedAt,
                status: "failure",
                fields: bodyFetchFields + [.label("error_kind", errorKind)]
            )
            if Self.shouldMarkMessageLocationMissing(for: error) {
                try? repository.markMessageLocationMissing(
                    accountKey: accountKey,
                    folderName: folderName,
                    himalayaEnvelopeID: envelopeID
                )
            }
            throw error
        }

        let document = try MailiaTiming.measure(
            operation: "body.display_pipeline",
            fields: [
                .label("has_html", message.html?.nilIfBlank != nil),
                .label("has_text", message.text?.nilIfBlank != nil),
                .label("has_attachment_flag", message.hasAttachment)
            ]
        ) {
            try emailDisplayPipeline.document(
                exportedHTML: message.html,
                exportedText: message.text,
                exportDirectory: exportDirectory
            )
        }

        return MessageBodyFetchResult(
            sanitizedHTML: document.html,
            htmlVariants: document.htmlVariants,
            textFallback: document.textFallback,
            hasAttachments: message.hasAttachment || document.hasAttachments
        )
    }

    private static func bodyFetchTimingErrorKind(for error: Error) -> String {
        if error is CancellationError {
            return "cancelled"
        }
        if let error = error as? MailAppServerError {
            return error.timingErrorKind
        }
        return "unknown"
    }

    private static func shouldMarkMessageLocationMissing(for error: Error) -> Bool {
        (error as? MailAppServerError)?.marksMessageLocationMissing == true
    }

    private static func defaultDownloadsDirectory(fileManager: FileManager = .default) -> URL {
        (try? fileManager.url(
            for: .downloadsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    static func configuredDownloadsDirectory(
        defaults: UserDefaults = .standard,
        fallback: URL = defaultDownloadsDirectory()
    ) -> URL {
        guard let path = defaults.string(forKey: MailiaPreferenceKeys.downloadsDirectoryPath)?.nilIfBlank else {
            return fallback
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func revealInFinder(_ fileURLs: [URL], fallbackDirectory: URL) {
        let existingFileURLs = fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existingFileURLs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(existingFileURLs)
            return
        }

        if FileManager.default.fileExists(atPath: fallbackDirectory.path) {
            NSWorkspace.shared.open(fallbackDirectory)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([fallbackDirectory])
        }
    }

    private func downloadedFileNames(in directory: URL) -> [String] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls
            .filter { url in
                (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func filterAndMap(
        _ entities: [EntityListItem],
        workspace: MailiaWorkspace,
        searchQuery: String
    ) -> [MailiaEntitySummary] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return entities
            .filter { item in
                query.isEmpty
                    || item.displayName.localizedCaseInsensitiveContains(query)
                    || (item.primaryEmailAddress?.localizedCaseInsensitiveContains(query) ?? false)
                    || item.emailAddresses.joined(separator: " ").localizedCaseInsensitiveContains(query)
                    || (item.latestSubject?.localizedCaseInsensitiveContains(query) ?? false)
                    || (item.searchableText?.localizedCaseInsensitiveContains(query) ?? false)
                    || item.accountKeys.joined(separator: " ").localizedCaseInsensitiveContains(query)
            }
            .map { item in
                MailiaEntitySummary(
                    id: item.id,
                    displayName: item.displayName,
                    primaryEmailAddress: item.primaryEmailAddress?.nilIfBlank,
                    emailAddresses: item.emailAddresses,
                    kind: .unknown,
                    unreadCount: item.unreadCount,
                    latestSubject: item.latestSubject?.nilIfBlank ?? "(No subject)",
                    latestBodyPreview: item.latestBodyPreview?.nilIfBlank,
                    latestMessageID: item.latestMessageID,
                    latestDate: item.latestDate,
                    accountKeys: item.accountKeys,
                    accountLabel: item.accountKeys.isEmpty ? "" : item.accountKeys.joined(separator: ", "),
                    workspace: workspace,
                    avatarImageDataURL: nil
                )
            }
    }

    private func preview(for message: TimelineMessage) -> String {
        if let text = message.textFallback?.nilIfBlank {
            return text
        }
        if let html = message.sanitizedHTML?.nilIfBlank {
            if let preview = htmlTextExtractor.previewText(from: html) {
                return preview
            }
        }
        let from = message.from?.displayLabel
        let to = message.to.map(\.displayLabel).joined(separator: ", ")
        switch message.direction {
        case .incoming:
            return from.map { "From \($0)" } ?? "Message body has not been loaded yet."
        case .outgoing:
            return to.isEmpty ? "Sent message body has not been loaded yet." : "To \(to)"
        }
    }
}

private enum EntityActionError: LocalizedError {
    case noMessages
    case noMatchingMessageLocation
    case missingSendAccountEmail(accountKey: String)
    case missingTargetFolder(accountKey: String, role: FolderRole)
    case noAttachments
    case partialFailure(failed: Int, total: Int, firstFailure: String)

    var errorDescription: String? {
        switch self {
        case .noMessages:
            "No movable messages were found for this entity."
        case .noMatchingMessageLocation:
            "No matching message location was found for this message."
        case let .missingSendAccountEmail(accountKey):
            "No email address is configured for \(accountKey)."
        case let .missingTargetFolder(accountKey, role):
            "No \(role.rawValue) folder was found for \(accountKey)."
        case .noAttachments:
            "This message does not have attachments."
        case let .partialFailure(failed, total, firstFailure):
            "\(failed) of \(total) message actions failed. First failure: \(firstFailure)"
        }
    }
}

private extension MailAddress {
    var displayLabel: String {
        if let displayName = displayName?.nilIfBlank {
            return "\(displayName) <\(emailAddress)>"
        }
        return emailAddress
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
