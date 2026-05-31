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
    func loadBody(for item: MailiaTimelineItem) async throws -> MailiaTimelineBody
    func performEntityAction(
        _ action: MailiaEntityAction,
        entityID: Int64,
        workspace: MailiaWorkspace,
        progress: @escaping @MainActor (String) -> Void
    ) async throws
    func markEntityRead(entityID: Int64, workspace: MailiaWorkspace) async throws
    func setMessageFlag(item: MailiaTimelineItem, isFlagged: Bool) async throws
    func downloadAttachments(for item: MailiaTimelineItem) async throws -> MailiaAttachmentDownloadResult
    func sendReply(to item: MailiaTimelineItem, body: String, replyAll: Bool, accountKey: String?) async throws
    func sendNewMessage(
        to recipients: [String],
        subject: String?,
        body: String,
        accountKey: String?
    ) async throws
    func loadSendAccounts() async throws -> [MailiaSendAccount]
    func updateAccountSettings(_ updates: [MailiaAccountSettingsUpdate]) async throws
    func messageBodyCacheStats() async throws -> CacheStats
    func clearMessageBodyCache() async throws
}

/// Aggregates per-workspace sync progress (Main + Junk run concurrently) into a single
/// determinate progress value for the refresh button.
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

@MainActor
struct LiveMailiaAppDataProvider: MailiaAppDataProviding {
    private let databaseQueue: DatabaseQueue
    private let repository: MailRepository
    private let syncService: SyncService
    private let bridge: any HimalayaBridge
    private let himalayaConfigStore: HimalayaConfigStore
    private let himalayaCommandLimiter: HimalayaCommandLimiter
    private let downloadsDirectory: URL
    private let revealDownloadedFiles: @MainActor ([URL], URL) -> Void
    private let htmlDisplayNormalizer = HTMLDisplayNormalizer()
    private let messageTextNormalizer = MessageTextNormalizer()

    init() {
        do {
            let environment = try MailiaEnvironment.live()
            let databaseQueue = try environment.openDatabase()
            self.init(
                databaseQueue: databaseQueue,
                bridge: environment.himalayaBridge,
                downloadsDirectory: environment.downloadsDirectory
            )
        } catch {
            let databaseQueue = try! DatabaseQueue()
            try! DatabaseMigratorFactory.makeMigrator().migrate(databaseQueue)
            self.init(
                databaseQueue: databaseQueue,
                bridge: ProcessHimalayaBridge(),
                downloadsDirectory: Self.defaultDownloadsDirectory()
            )
        }
    }

    init(
        databaseQueue: DatabaseQueue,
        bridge: any HimalayaBridge,
        downloadsDirectory: URL,
        policy: SyncPolicy = SyncPolicy(),
        himalayaCommandLimiter: HimalayaCommandLimiter? = nil,
        himalayaConfigStore: HimalayaConfigStore = HimalayaConfigStore(),
        revealDownloadedFiles: @MainActor @escaping ([URL], URL) -> Void = Self.revealInFinder
    ) {
        let commandLimiter = himalayaCommandLimiter
            ?? HimalayaCommandLimiter(maxConcurrentCommands: policy.maxConcurrentHimalayaProcesses)
        self.databaseQueue = databaseQueue
        self.repository = MailRepository(databaseQueue: databaseQueue)
        self.bridge = bridge
        self.himalayaConfigStore = himalayaConfigStore
        self.himalayaCommandLimiter = commandLimiter
        self.downloadsDirectory = downloadsDirectory
        self.revealDownloadedFiles = revealDownloadedFiles
        self.syncService = SyncService(
            bridge: bridge,
            databaseQueue: databaseQueue,
            policy: policy,
            himalayaCommandLimiter: commandLimiter
        )
    }

    func loadSnapshot(workspace: MailiaWorkspace, searchQuery: String) async throws -> MailiaSnapshot {
        let entities = try repository.entityList(workspace: workspace.coreWorkspace)
        let sendAccounts = try await loadSendAccounts()
        return MailiaSnapshot(
            entities: filterAndMap(entities, workspace: workspace, searchQuery: searchQuery),
            sendAccounts: sendAccounts,
            loadedAt: Date()
        )
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
        return storedAccounts.map(MailiaSendAccount.init).sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault {
                return lhs.isDefault
            }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
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
        progress(MailiaRefreshProgress(
            phase: .discovering,
            title: "Discovering mailboxes",
            detail: nil,
            fraction: nil
        ))
        do {
            _ = try await syncService.discoverFoldersForDiscoveredAccounts(timeout: 45)
        } catch let error as CancellationError {
            throw error
        } catch {
            NSLog("Unable to refresh mailbox list before sync: \(error.localizedDescription)")
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

        async let mainSync: Int = syncService.syncWorkspace(
            .main,
            accountPriorityScores: mainAccountPriorityScores,
            fullHistory: options.fullHistory,
            timeout: syncTimeout,
            onProgress: report
        )
        async let junkSync: Int = syncService.syncWorkspace(
            .junk,
            accountPriorityScores: junkAccountPriorityScores,
            fullHistory: options.fullHistory,
            timeout: syncTimeout,
            onProgress: report
        )
        _ = try await (mainSync, junkSync)

        progress(MailiaRefreshProgress(
            phase: .finishing,
            title: "Updating",
            detail: nil,
            fraction: nil
        ))
        return try await loadSnapshot(workspace: workspace, searchQuery: searchQuery)
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
                    _ = try await syncService.discoverFolders(accountKey: accountKey, timeout: 15)
                } catch {
                    NSLog("Unable to refresh folders for \(accountKey): \(error.localizedDescription)")
                }
            }

            _ = try await syncService.syncWorkspace(
                .main,
                accountKeys: normalizedAccountKeys,
                folderRoles: [.normal, .sent],
                timeout: 30
            )
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
                        _ = try await syncService.discoverFolders(accountKey: accountKey, timeout: 15)
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
                _ = try await syncService.syncWorkspace(
                    workspace.coreWorkspace,
                    accountKeys: normalizedAccountKeys,
                    folderRoles: folderRoles,
                    timeout: 30
                )
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
        progress(MailiaRefreshProgress(
            phase: .discovering,
            title: "Discovering mailboxes",
            detail: nil,
            fraction: nil
        ))
        do {
            _ = try await syncService.discoverFoldersForDiscoveredAccounts(timeout: 45)
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

    func loadTimelinePage(
        entityID: Int64,
        workspace: MailiaWorkspace,
        direction: MailiaTimelinePageDirection,
        anchorID: Int64?,
        limit: Int
    ) async throws -> MailiaTimelinePage {
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

    func loadBody(for item: MailiaTimelineItem) async throws -> MailiaTimelineBody {
        if let cached = try repository.messageBody(messageID: item.id),
           cached.sanitizedHTML?.nilIfBlank != nil || cached.textFallback?.nilIfBlank != nil {
            return MailiaTimelineBody(
                html: displayHTML(cached.sanitizedHTML),
                text: cached.textFallback?.nilIfBlank
            )
        }

        guard let folderName = item.folderLabel.nilIfBlank,
              let envelopeID = item.envelopeID.nilIfBlank else {
            return MailiaTimelineBody(html: nil, text: nil)
        }

        let body = try await fetchBody(
            messageID: item.id,
            accountKey: item.accountLabel,
            folderName: folderName,
            envelopeID: envelopeID
        )
        try repository.cacheMessageBody(
            messageID: item.id,
            sanitizedHTML: body.sanitizedHTML,
            textFallback: body.textFallback,
            sanitizerVersion: 2
        )
        return MailiaTimelineBody(
            html: displayHTML(body.sanitizedHTML),
            text: body.textFallback?.nilIfBlank
        )
    }

    private enum EntityActionOperation: Sendable {
        case flag(isEnabled: Bool)
        case move(targetFoldersByAccount: [String: String])

        func command(for location: MessageLocationTarget) -> HimalayaCommand? {
            switch self {
            case let .flag(isEnabled):
                return isEnabled
                    ? .flagAdd(
                        id: location.himalayaEnvelopeID,
                        flag: "flagged",
                        folder: location.sourceFolderName,
                        account: location.accountKey
                    )
                    : .flagRemove(
                        id: location.himalayaEnvelopeID,
                        flag: "flagged",
                        folder: location.sourceFolderName,
                        account: location.accountKey
                    )
            case let .move(targetFoldersByAccount):
                guard let targetFolderName = targetFoldersByAccount[location.accountKey],
                      targetFolderName != location.sourceFolderName
                else {
                    return nil
                }
                return .messageMove(
                    id: location.himalayaEnvelopeID,
                    from: location.sourceFolderName,
                    to: targetFolderName,
                    account: location.accountKey
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
        _ = try await syncService.discoverFoldersForDiscoveredAccounts(timeout: 45)
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

        for location in locations {
            _ = try repository.setMessageLocationFlag(
                accountKey: location.accountKey,
                folderName: location.sourceFolderName,
                himalayaEnvelopeID: location.himalayaEnvelopeID,
                flag: "seen",
                isEnabled: true
            )
        }

        for location in locations {
            await markMessageReadRemotely(location)
        }
    }

    private func markMessageReadRemotely(_ location: MessageLocationTarget) async {
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            do {
                _ = try await himalayaCommandLimiter.run(
                    .flagSeen(
                        id: location.himalayaEnvelopeID,
                        folder: location.sourceFolderName,
                        account: location.accountKey
                    ),
                    bridge: bridge,
                    timeout: 30,
                    priority: .backgroundSync
                ).requireSuccess()
                return
            } catch {
                guard attempt < maxAttempts else {
                    NSLog("Unable to mark message read remotely: \(Self.errorDescription(error))")
                    return
                }

                let delay = UInt64(attempt) * 500_000_000
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }

    private func performBatchEntityAction(
        action: MailiaEntityAction,
        locations: [MessageLocationTarget],
        operation: EntityActionOperation,
        progress: @escaping @MainActor (String) -> Void
    ) async throws {
        let runnableLocations = locations.filter { operation.command(for: $0) != nil }
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
        let bridge = bridge
        let commandLimiter = himalayaCommandLimiter

        progress(action.statusLabel)
        return await withTaskGroup(of: [EntityActionLocationResult].self) { group in
            for locationGroup in groupedLocations {
                group.addTask {
                    var groupResults: [EntityActionLocationResult] = []
                    for location in locationGroup {
                        guard let command = operation.command(for: location) else {
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
                            _ = try await commandLimiter.run(
                                command,
                                bridge: bridge,
                                timeout: 30,
                                priority: .interactive
                            ).requireSuccess()
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

        let command: HimalayaCommand = isFlagged
            ? .flagAdd(id: envelopeID, flag: "flagged", folder: folderName, account: item.accountLabel)
            : .flagRemove(id: envelopeID, flag: "flagged", folder: folderName, account: item.accountLabel)
        _ = try await runHimalaya(command, timeout: 30, priority: .interactive).requireSuccess()
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
        let existingFiles = downloadedFileNames(in: targetDownloadsDirectory)
        _ = try await runHimalaya(
            .attachmentDownload(
                messageID: envelopeID,
                folder: folderName,
                account: item.accountLabel,
                downloadsDirectory: targetDownloadsDirectory
            ),
            timeout: 300,
            priority: .userDownload
        ).requireSuccess()

        let currentFiles = downloadedFileNames(in: targetDownloadsDirectory)
        let newFiles = currentFiles.filter { !existingFiles.contains($0) }
        let newFileURLs = newFiles.map { targetDownloadsDirectory.appendingPathComponent($0) }
        revealDownloadedFiles(newFileURLs, targetDownloadsDirectory)
        return MailiaAttachmentDownloadResult(
            directoryPath: targetDownloadsDirectory.path,
            fileNames: newFiles
        )
    }

    func sendReply(to item: MailiaTimelineItem, body: String, replyAll: Bool, accountKey: String?) async throws {
        guard let folderName = item.folderLabel.nilIfBlank,
              let envelopeID = item.envelopeID.nilIfBlank else {
            throw EntityActionError.noMatchingMessageLocation
        }
        guard let body = body.nilIfBlank else {
            throw EntityActionError.noMessages
        }

        let templateResult = try await runHimalaya(
            .templateReply(
                id: envelopeID,
                body: body,
                folder: folderName,
                account: item.accountLabel,
                replyAll: replyAll
            ),
            timeout: 60,
            priority: .interactive
        ).requireSuccess()

        let template = Self.replyTemplateWithoutQuotedOriginal(
            Self.templateContent(from: templateResult)
        )
        guard let template = template.nilIfBlank else {
            throw EntityActionError.noMessages
        }

        _ = try await runHimalaya(
            .templateSend(template: template, account: accountKey?.nilIfBlank ?? item.accountLabel),
            timeout: 120,
            priority: .interactive
        ).requireSuccess()
    }

    func sendNewMessage(
        to recipients: [String],
        subject: String?,
        body: String,
        accountKey: String?
    ) async throws {
        let cleanedRecipients = recipients.compactMap(Self.mailHeaderValue)
        guard !cleanedRecipients.isEmpty else {
            throw EntityActionError.noMessages
        }
        guard let body = body.nilIfBlank else {
            throw EntityActionError.noMessages
        }

        var headers = ["To:\(cleanedRecipients.joined(separator: ", "))"]
        if let subject = Self.mailHeaderValue(subject) {
            headers.append("Subject:\(subject)")
        }

        let templateResult = try await runHimalaya(
            .templateWrite(body: body, headers: headers, account: accountKey?.nilIfBlank),
            timeout: 60,
            priority: .interactive
        ).requireSuccess()

        let template = Self.templateContent(from: templateResult)
        guard let template = template.nilIfBlank else {
            throw EntityActionError.noMessages
        }

        _ = try await runHimalaya(
            .templateSend(template: template, account: accountKey?.nilIfBlank),
            timeout: 120,
            priority: .interactive
        ).requireSuccess()
    }

    private static func mailHeaderValue(_ value: String?) -> String? {
        value?
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
    }

    private static func templateContent(from result: HimalayaResult) -> String {
        if let output = try? result.decodeJSON(as: HimalayaTemplateWriteOutput.self) {
            return output.content
        }
        if let output = try? result.decodeJSON(as: String.self) {
            return output
        }
        return result.stdout
    }

    static func replyTemplateWithoutQuotedOriginal(_ template: String) -> String {
        let lines = template.components(separatedBy: .newlines)
        guard let quoteStartIndex = lines.indices.reversed().first(where: { index in
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("On "), line.hasSuffix("wrote:") else {
                return false
            }
            let quotedLines = lines[(index + 1)...]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return !quotedLines.isEmpty && quotedLines.allSatisfy { $0.hasPrefix(">") }
        }) else {
            return template
        }

        var keptLines = Array(lines[..<quoteStartIndex])
        while keptLines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            keptLines.removeLast()
        }
        return keptLines.joined(separator: "\n")
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
            subject: message.subject?.nilIfBlank ?? "(No subject)",
            preview: preview(for: message),
            html: displayHTML(message.sanitizedHTML),
            date: HimalayaDateParser.parse(message.messageDate),
            accountLabel: message.accountKey,
            accountEmoji: emojiByAccount[message.accountKey],
            accountAvatarImageDataURL: nil,
            folderLabel: message.folderName ?? "",
            envelopeID: message.himalayaEnvelopeID ?? "",
            isFlagged: message.flags.contains { $0.caseInsensitiveCompare("flagged") == .orderedSame },
            fromLabel: message.from?.displayLabel ?? "",
            toLabel: message.to.map(\.displayLabel).joined(separator: ", "),
            hasAttachments: message.hasAttachments
        )
    }

    private func fetchBody(messageID: Int64, accountKey: String, folderName: String, envelopeID: String) async throws -> (sanitizedHTML: String?, textFallback: String?) {
        let exportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailiaExport-\(messageID)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: exportDirectory)
        }

        do {
            _ = try await runHimalaya(
                .messageExport(id: envelopeID, folder: folderName, account: accountKey, destination: exportDirectory),
                timeout: 30,
                priority: .visibleBody
            ).requireSuccess()

            let htmlURL = exportDirectory.appendingPathComponent("index.html")
            let textURL = exportDirectory.appendingPathComponent("plain.txt")
            let html = try? String(contentsOf: htmlURL, encoding: .utf8)
            let text = (try? String(contentsOf: textURL, encoding: .utf8))
                .map(messageTextNormalizer.normalize)

            if let html, let sanitized = try? HTMLSanitizer().sanitize(html) {
                return (sanitized.content, text?.nilIfBlank)
            }
            if let text = text?.nilIfBlank {
                return (nil, text)
            }
        } catch {
            // Fall through to preview read below.
        }

        let result = try await runHimalaya(
            .messageReadPreview(id: envelopeID, folder: folderName, account: accountKey),
            timeout: 20,
            priority: .visibleBody
        ).requireSuccess()
        return (nil, messageTextNormalizer.normalize(try result.decodeJSON(as: String.self)))
    }

    private func displayHTML(_ html: String?) -> String? {
        guard let html = html?.nilIfBlank else {
            return nil
        }
        return htmlDisplayNormalizer.normalize(html).nilIfBlank
    }

    private func runHimalaya(
        _ command: HimalayaCommand,
        timeout: TimeInterval?,
        priority: HimalayaCommandPriority
    ) async throws -> HimalayaResult {
        try await himalayaCommandLimiter.run(
            command,
            bridge: bridge,
            timeout: timeout,
            priority: priority
        )
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
            return html
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
    case missingTargetFolder(accountKey: String, role: FolderRole)
    case noAttachments
    case partialFailure(failed: Int, total: Int, firstFailure: String)

    var errorDescription: String? {
        switch self {
        case .noMessages:
            "No movable messages were found for this entity."
        case .noMatchingMessageLocation:
            "No matching message location was found for this message."
        case let .missingTargetFolder(accountKey, role):
            "No \(role.rawValue) folder was found for \(accountKey)."
        case .noAttachments:
            "This message does not have attachments."
        case let .partialFailure(failed, total, firstFailure):
            "\(failed) of \(total) message actions failed. First failure: \(firstFailure)"
        }
    }
}

private struct HimalayaTemplateWriteOutput: Decodable {
    var content: String
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
