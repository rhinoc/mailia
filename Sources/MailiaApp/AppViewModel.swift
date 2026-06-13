import Foundation
import MailiaCore
import os

enum MailiaWorkspace: String, CaseIterable, Identifiable, Sendable {
    case main = "Main"
    case junk = "Junk"
    case flagged = "Flagged"

    var id: String { rawValue }

    var coreWorkspace: Workspace {
        switch self {
        case .main:
            .main
        case .junk:
            .junk
        case .flagged:
            .flagged
        }
    }
}

struct MailiaEntitySummary: Identifiable, Equatable, Sendable {
    let id: Int64
    let displayName: String
    let primaryEmailAddress: String?
    let emailAddresses: [String]
    let kind: EntityKind
    var unreadCount: Int
    let latestSubject: String
    var latestBodyPreview: String?
    let latestMessageID: Int64?
    let latestDate: Date?
    let accountKeys: [String]
    let accountLabel: String
    let workspace: MailiaWorkspace
    var avatarImageDataURL: String?
}

struct MailiaTimelineItem: Identifiable, Equatable, Sendable {
    let id: Int64
    let entityID: Int64
    let direction: MessageDirection
    let subject: String
    let preview: String
    let html: String?
    let htmlVariants: MailiaTimelineHTMLVariants?
    let date: Date?
    let accountLabel: String
    let accountEmoji: String?
    let accountAvatarImageDataURL: String?
    let folderLabel: String
    let envelopeID: String
    let isFlagged: Bool
    let fromLabel: String
    let toLabel: String
    let hasAttachments: Bool
}

struct MailiaTimelineHTMLVariants: Equatable, Sendable {
    let remoteContentBlockedHTML: String?
    let quotedReplyHiddenHTML: String?
    let quotedReplyHiddenRemoteContentBlockedHTML: String?

    init?(_ variants: EmailHTMLDisplayVariants?) {
        guard let variants else {
            return nil
        }
        if variants.remoteContentBlockedHTML == nil,
           variants.quotedReplyHiddenHTML == nil,
           variants.quotedReplyHiddenRemoteContentBlockedHTML == nil {
            return nil
        }
        remoteContentBlockedHTML = variants.remoteContentBlockedHTML
        quotedReplyHiddenHTML = variants.quotedReplyHiddenHTML
        quotedReplyHiddenRemoteContentBlockedHTML = variants.quotedReplyHiddenRemoteContentBlockedHTML
    }
}

struct MailiaTimelineBody: Equatable, Sendable {
    let html: String?
    let htmlVariants: MailiaTimelineHTMLVariants?
    let hasAttachments: Bool

    init(html: String?, htmlVariants: MailiaTimelineHTMLVariants? = nil, hasAttachments: Bool = false) {
        self.html = html
        self.htmlVariants = htmlVariants
        self.hasAttachments = hasAttachments
    }
}

enum MailiaTimelineBodyState: Equatable, Sendable {
    case notRequested
    case loading
    case loaded(MailiaTimelineBody)
    case failed(String)
}

private extension MailiaTimelineBodyState {
    var bodyDebugStatus: String {
        switch self {
        case .notRequested:
            "notRequested"
        case .loading:
            "loading"
        case .loaded:
            "loaded"
        case .failed:
            "failed"
        }
    }
}

struct MailiaAttachmentDownloadResult: Equatable, Sendable {
    let directoryPath: String
    let fileNames: [String]
}

struct MailiaSendAccount: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let emailAddress: String?
    let displayName: String?
    let isDefault: Bool
    let emoji: String?
    let sortOrder: Int?
    let syncStatus: String?
    let syncErrorMessage: String?
    let syncCheckedAt: Date?
    let avatarImageDataURL: String?

    init(
        id: String,
        label: String,
        emailAddress: String?,
        displayName: String?,
        isDefault: Bool,
        emoji: String?,
        sortOrder: Int? = nil,
        syncStatus: String? = nil,
        syncErrorMessage: String? = nil,
        syncCheckedAt: Date? = nil,
        avatarImageDataURL: String?
    ) {
        self.id = id
        self.label = label
        self.emailAddress = emailAddress
        self.displayName = displayName
        self.isDefault = isDefault
        self.emoji = emoji
        self.sortOrder = sortOrder
        self.syncStatus = syncStatus
        self.syncErrorMessage = syncErrorMessage
        self.syncCheckedAt = syncCheckedAt
        self.avatarImageDataURL = avatarImageDataURL
    }
}

struct MailiaAccountSettingsUpdate: Equatable, Sendable {
    var accountKey: String
    var displayName: String?
    var emoji: String?
    var isDefault: Bool?
    var sortOrder: Int?

    init(
        accountKey: String,
        displayName: String?,
        emoji: String?,
        isDefault: Bool?,
        sortOrder: Int? = nil
    ) {
        self.accountKey = accountKey
        self.displayName = displayName
        self.emoji = emoji
        self.isDefault = isDefault
        self.sortOrder = sortOrder
    }
}

extension MailiaSendAccount {
    init(_ account: DiscoveredAccount) {
        let displayName = account.displayName?.nilIfBlank
        let label = Self.cleanAccountLabel(displayName)
            ?? account.emailAddress?.nilIfBlank
            ?? account.accountKey

        self.init(
            id: account.accountKey,
            label: label,
            emailAddress: account.emailAddress?.nilIfBlank,
            displayName: displayName,
            isDefault: account.isDefault,
            emoji: account.emoji?.nilIfBlank,
            sortOrder: account.sortOrder,
            syncStatus: account.syncStatus?.nilIfBlank,
            syncErrorMessage: account.syncErrorMessage?.nilIfBlank,
            syncCheckedAt: account.syncCheckedAt,
            avatarImageDataURL: nil
        )
    }

    var menuLabel: String {
        let base = emailAddress ?? label
        return Self.prefixed(base, emoji: emoji)
    }

    var hasSyncFailure: Bool {
        syncStatus?.caseInsensitiveCompare("failed") == .orderedSame
            || syncErrorMessage?.nilIfBlank != nil
    }

    var syncIssueMessage: String {
        syncErrorMessage?.nilIfBlank ?? "Unable to sync this account."
    }

    var syncIssueTooltip: String {
        let accountLabel = emailAddress ?? label
        return "\(accountLabel)\n\(syncIssueMessage)"
    }

    static func prefixed(_ label: String, emoji: String?) -> String {
        guard let emoji = normalizedEmoji(emoji) else { return label }
        return "\(emoji) \(label)"
    }

    static func normalizedEmoji(_ emoji: String?) -> String? {
        guard let emoji else { return nil }
        let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return nil }
        return String(first)
    }

    private static func cleanAccountLabel(_ label: String?) -> String? {
        guard let label = label?.nilIfBlank else { return nil }
        let cleaned = label
            .replacingOccurrences(of: " (default)", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "(default)", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.nilIfBlank
    }
}

struct MailiaRecipientSuggestion: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let email: String
    let entityID: Int64
    let avatarImageDataURL: String?
}

struct MailiaRefreshProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case discovering
        case downloading
        case finishing
    }

    var phase: Phase
    var title: String
    var detail: String?
    /// Determinate progress in 0...1, or `nil` for an indeterminate spinner.
    var fraction: Double?
}

private struct AvatarResolutionTaskInfo: Equatable, Sendable {
    let source: String
    let displayName: String
    let primaryEmailAddress: String?
    let emailAddresses: [String]
    let startedAt: Date
    let batchID: Int
}

private struct AvatarResolutionProgressBatch: Equatable, Sendable {
    let id: Int
    let source: String
    let startedAt: Date
    var total: Int
    var completed: Int
    var succeeded: Int
    var failed: Int
    var canceled: Int
    var timedOut: Int

    var fraction: Double {
        guard total > 0 else { return 1 }
        return min(1, Double(completed) / Double(total))
    }

    var percent: Int {
        Int((fraction * 100).rounded())
    }
}

private enum AvatarResolutionPriority: Int, Comparable, Sendable {
    case selected = 0
    case visible = 1
    case background = 2

    static func < (lhs: AvatarResolutionPriority, rhs: AvatarResolutionPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

private struct PendingAvatarResolutionRequest: Equatable, Sendable {
    var entity: MailiaEntitySummary
    var source: String
    var priority: AvatarResolutionPriority
    var batchID: Int
    var sequence: Int
}

enum MailiaAttachmentDownloadState: Equatable, Sendable {
    case idle
    case downloading
    case downloaded(MailiaAttachmentDownloadResult)
    case failed(String)
}

enum MailiaReplySendState: Equatable, Sendable {
    case idle
    case sending
    case sent
    case failed(String)
}

struct MailiaSnapshot: Equatable, Sendable {
    let entities: [MailiaEntitySummary]
    let sendAccounts: [MailiaSendAccount]
    let loadedAt: Date
}

struct MailiaRefreshOptions: Equatable, Sendable {
    var preferredAccountKeys: [String] = []
    var fullHistory: Bool = false
}

enum MailiaCacheKind: String, CaseIterable, Identifiable, Sendable {
    case avatars
    case messageBodies

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .avatars:
            "Avatars"
        case .messageBodies:
            "Message bodies"
        }
    }
}

struct MailiaCacheSummary: Identifiable, Equatable, Sendable {
    let kind: MailiaCacheKind
    let itemCount: Int
    let byteSize: Int64

    var id: MailiaCacheKind { kind }
}

enum MailiaTimelinePageDirection: Hashable, Sendable {
    case latest
    case older
    case newer
}

struct MailiaTimelinePage: Equatable, Sendable {
    let items: [MailiaTimelineItem]
    let hasMore: Bool
}

struct MailiaTimelineScrollAnchor: Equatable, Sendable {
    enum Edge: Equatable, Sendable {
        case top
        case bottom
    }

    let id: Int64
    let edge: Edge
    let generation: Int
}

private let mailiaScrollDebugOSLog = OSLog(subsystem: "dev.rhinoc.mailia", category: "ScrollDebug")

func MailiaScrollDebugLog(_ message: String) {
    os_log("%{public}@", log: mailiaScrollDebugOSLog, type: .default, message)
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var searchQuery: String = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            clearPresentationForFilterChange()
            reloadForCurrentFilters()
        }
    }

    @Published var workspace: MailiaWorkspace = .main {
        didSet {
            guard workspace != oldValue else { return }
            pendingMarkReadTask?.cancel()
            clearPresentationForFilterChange()
            reloadForCurrentFilters()
        }
    }

    @Published var selectedEntityID: Int64? {
        didSet {
            guard selectedEntityID != oldValue else { return }
            MailiaScrollDebugLog("[MailiaScrollDebug] selectedEntity changed old=\(oldValue.map { String($0) } ?? "nil") new=\(selectedEntityID.map { String($0) } ?? "nil") timelineGeneration=\(timelineGeneration)")
            replySendState = .idle
            if selectedEntityID != nil {
                isComposingNewMessage = false
            }
            selectedSendAccountKey = nil
            scheduleMarkSelectedEntityReadIfNeeded()
            loadTimelineForSelection()
            resolveSelectedEntityAvatarIfNeeded()
        }
    }

    @Published private(set) var entities: [MailiaEntitySummary] = []
    @Published private(set) var timeline: [MailiaTimelineItem] = []
    @Published private(set) var refreshStatus: String = "Ready"
    @Published private(set) var refreshActivity: MailiaRefreshProgress?
    @Published private(set) var avatarResolutionActivity: MailiaRefreshProgress?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingEntityList = true
    @Published private(set) var recipientSuggestions: [MailiaRecipientSuggestion] = []
    private var suggestionAvatarResolutionTasks: [String: Task<Void, Never>] = [:]
    @Published private(set) var isLoadingTimeline = false
    @Published private(set) var isLoadingOlderTimeline = false
    @Published private(set) var isLoadingNewerTimeline = false
    @Published private(set) var hasOlderTimeline = false
    @Published private(set) var hasNewerTimeline = false
    @Published private(set) var timelineBodyStates: [Int64: MailiaTimelineBodyState] = [:]
    @Published private(set) var attachmentDownloadStates: [Int64: MailiaAttachmentDownloadState] = [:]
    @Published private(set) var replySendState: MailiaReplySendState = .idle
    @Published private(set) var isComposingNewMessage = false
    @Published private(set) var hasComposeDraft = false
    @Published private(set) var sendAccounts: [MailiaSendAccount] = []
    @Published private(set) var selectedSendAccountKey: String?
    @Published private(set) var timelineScrollAnchor: MailiaTimelineScrollAnchor?
    @Published private(set) var cacheSummaries: [MailiaCacheSummary] = []
    @Published private(set) var cacheOperationStatus: String?

    private let provider: any MailiaAppDataProviding
    private let startupRefreshStalenessThreshold: TimeInterval
    private let now: @Sendable () -> Date
    private let htmlTextExtractor = HTMLTextExtractor()
    private var requestGeneration = 0
    private var timelineGeneration = 0
    private var timelineWindowStore = TimelineWindowStore()
    private let listFetchQueue = ListFetchQueue()
    private let bodyLoadQueue: BodyFetchQueue
    private var avatarResolutionTasks: [Int64: Task<Void, Never>] = [:]
    private var avatarResolutionTaskInfo: [Int64: AvatarResolutionTaskInfo] = [:]
    private var avatarResolutionBatches: [Int: AvatarResolutionProgressBatch] = [:]
    private var pendingAvatarResolutionRequests: [Int64: PendingAvatarResolutionRequest] = [:]
    private var accountAvatarResolutionTasks: [String: Task<Void, Never>] = [:]
    private var nextAvatarResolutionBatchID = 0
    private var nextAvatarResolutionSequence = 0
    private var avatarCacheHydrationTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var partialRefreshSnapshotTask: Task<Void, Never>?
    private var partialRefreshSnapshotNeedsReload = false
    private var postSendFollowUpRefreshTasks: [UUID: Task<Void, Never>] = [:]
    private var sendAccountsRefreshTask: Task<Void, Never>?
    private var entityPreviewBodyPrefetchTask: Task<Void, Never>?
    private var optimisticHiddenEntityIDs: Set<Int64> = []
    private var optimisticReadEntityIDs: Set<Int64> = []
    private var pendingMarkReadTask: Task<Void, Never>?
    private var markReadTasks: [Int64: Task<Void, Never>] = [:]
    private let avatarResolver: EntityBrandAvatarResolver
    private let timelinePageSize = 80
    private let selectedTimelineBodyPrefetchLimit = 4
    private let entityPreviewBodyPrefetchLimit = 50
    private let maxConcurrentAvatarResolutions = 4
    private let partialRefreshSnapshotDelayNanoseconds: UInt64 = 350_000_000
    private let postSendFollowUpRefreshDelaysNanoseconds: [UInt64]
    private let avatarResolutionTimeoutNanoseconds: UInt64 = 12_000_000_000

    init(
        provider: any MailiaAppDataProviding = LiveMailiaAppDataProvider(),
        avatarResolver: EntityBrandAvatarResolver = EntityBrandAvatarResolver(),
        postSendFollowUpRefreshDelaysNanoseconds: [UInt64] = [3_000_000_000, 8_000_000_000],
        startupRefreshStalenessThreshold: TimeInterval = 600,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.provider = provider
        self.bodyLoadQueue = BodyFetchQueue(provider: provider)
        self.avatarResolver = avatarResolver
        self.postSendFollowUpRefreshDelaysNanoseconds = postSendFollowUpRefreshDelaysNanoseconds
        self.startupRefreshStalenessThreshold = startupRefreshStalenessThreshold
        self.now = now
        self.bodyLoadQueue.delegate = self
    }

    deinit {
        reloadTask?.cancel()
        partialRefreshSnapshotTask?.cancel()
        sendAccountsRefreshTask?.cancel()
        entityPreviewBodyPrefetchTask?.cancel()
        for task in postSendFollowUpRefreshTasks.values {
            task.cancel()
        }
        pendingMarkReadTask?.cancel()
        for task in markReadTasks.values {
            task.cancel()
        }
        for task in avatarResolutionTasks.values {
            task.cancel()
        }
        for task in accountAvatarResolutionTasks.values {
            task.cancel()
        }
        avatarCacheHydrationTask?.cancel()
        avatarResolutionTasks.removeAll()
        accountAvatarResolutionTasks.removeAll()
        avatarResolutionTaskInfo.removeAll()
        avatarResolutionBatches.removeAll()
        pendingAvatarResolutionRequests.removeAll()
        for task in suggestionAvatarResolutionTasks.values {
            task.cancel()
        }
    }

    func load() async {
        await loadSnapshot(
            statusPrefix: "Loaded",
            refresh: false,
            refreshIfEmpty: true,
            refreshIfStaleAfter: startupRefreshStalenessThreshold
        )
        refreshSendAccountsInBackground()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        await loadSnapshot(statusPrefix: "Refreshed", refresh: true)
    }

    func startRefresh() {
        guard !isRefreshing else { return }
        beginRefreshPresentation(title: "Refreshing")
        Task { [weak self] in
            await self?.loadSnapshot(statusPrefix: "Refreshed", refresh: true)
        }
    }

    func refreshFullHistory() async {
        guard !isRefreshing else { return }
        await loadSnapshot(
            statusPrefix: "Full history synced",
            refresh: true,
            options: MailiaRefreshOptions(fullHistory: true)
        )
    }

    func syncEntityHistory(_ entity: MailiaEntitySummary) {
        guard !isRefreshing else { return }
        let emailAddresses = Self.emailAddresses(for: entity)
        guard !emailAddresses.isEmpty else {
            refreshStatus = "No email address available for \(entity.displayName)"
            return
        }

        Task { [weak self] in
            await self?.syncEntityHistory(
                entityID: entity.id,
                displayName: entity.displayName,
                emailAddresses: emailAddresses,
                workspace: entity.workspace
            )
        }
    }

    func refreshCacheSummaries() async {
        do {
            cacheSummaries = [
                await avatarResolver.cacheSummary(),
                try await messageBodyCacheSummary()
            ]
            cacheOperationStatus = nil
        } catch {
            cacheOperationStatus = "Unable to load cache sizes: \(error.localizedDescription)"
            NSLog("Unable to load cache summaries: \(error.localizedDescription)")
        }
    }

    func clearCache(_ kind: MailiaCacheKind) {
        Task { [weak self] in
            guard let self else { return }
            do {
                switch kind {
                case .avatars:
                    await avatarResolver.clearCache()
                    clearInMemoryAvatars()
                case .messageBodies:
                    try await provider.clearMessageBodyCache()
                    clearInMemoryBodyCache()
                }
                cacheOperationStatus = "\(kind.displayName) cache cleared."
                await refreshCacheSummaries()
            } catch {
                cacheOperationStatus = "Unable to clear \(kind.displayName.lowercased()): \(error.localizedDescription)"
                NSLog("Unable to clear \(kind.displayName) cache: \(error.localizedDescription)")
            }
        }
    }

    private func syncEntityHistory(
        entityID: Int64,
        displayName: String,
        emailAddresses: Set<String>,
        workspace syncWorkspace: MailiaWorkspace
    ) async {
        requestGeneration += 1
        let generation = requestGeneration
        let searchQuerySnapshot = searchQuery
        isRefreshing = true
        refreshStatus = "Syncing \(displayName)..."
        refreshActivity = MailiaRefreshProgress(
            phase: .discovering,
            title: "Syncing conversation",
            detail: displayName,
            fraction: nil
        )
        defer {
            if generation == requestGeneration {
                isRefreshing = false
                refreshActivity = nil
            }
        }

        do {
            let snapshot = try await provider.syncEntityHistory(
                emailAddresses: emailAddresses,
                workspace: syncWorkspace,
                searchQuery: searchQuerySnapshot
            ) { [weak self] progress in
                guard let self, generation == requestGeneration else { return }
                refreshActivity = progress
                refreshStatus = progress.detail.map { "\(progress.title) — \($0)" } ?? progress.title
            }
            guard generation == requestGeneration else { return }
            applySnapshot(snapshot, reloadTimelineIfSelectionKept: selectedEntityID == entityID)
            refreshStatus = "Synced \(displayName) history"
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration else { return }
            refreshStatus = "Unable to sync \(displayName): \(error.localizedDescription)"
            NSLog("Unable to sync entity history: \(error.localizedDescription)")
        }
    }

    func performEntityAction(_ action: MailiaEntityAction, entity: MailiaEntitySummary) {
        if EntityActionPolicy.hidesEntityInCurrentWorkspace(action, workspace: entity.workspace.coreWorkspace) {
            optimisticallyHideEntity(entity.id)
        } else {
            refreshStatus = action.statusLabel
        }

        Task { [weak self] in
            await self?.performEntityAction(action, entityID: entity.id, actionWorkspace: entity.workspace)
        }
    }

    func setMessageFlag(item: MailiaTimelineItem, isFlagged: Bool) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await provider.setMessageFlag(item: item, isFlagged: isFlagged)
                invalidateTimelineCache(entityID: item.entityID)
                if let selectedEntityID {
                    loadTimelineForSelection()
                    let snapshot = try await provider.loadSnapshot(workspace: workspace, searchQuery: searchQuery)
                    applySnapshot(snapshot, reloadTimelineIfSelectionKept: false)
                    if !entities.contains(where: { $0.id == selectedEntityID }) {
                        self.selectedEntityID = entities.first?.id
                    }
                }
            } catch {
                NSLog("Unable to update flag: \(error.localizedDescription)")
            }
        }
    }

    private func scheduleMarkSelectedEntityReadIfNeeded() {
        pendingMarkReadTask?.cancel()

        guard let selectedEntityID,
              let entity = entities.first(where: { $0.id == selectedEntityID }),
              entity.unreadCount > 0
        else {
            return
        }

        let workspaceSnapshot = workspace
        pendingMarkReadTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(1_500))
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            self?.markEntityReadAfterViewing(
                entityID: selectedEntityID,
                workspace: workspaceSnapshot
            )
        }
    }

    private func markEntityReadAfterViewing(entityID: Int64, workspace workspaceSnapshot: MailiaWorkspace) {
        pendingMarkReadTask = nil

        guard selectedEntityID == entityID,
              workspace == workspaceSnapshot,
              entities.first(where: { $0.id == entityID })?.unreadCount ?? 0 > 0
        else {
            return
        }

        optimisticReadEntityIDs.insert(entityID)
        setUnreadCount(0, for: entityID)

        guard markReadTasks[entityID] == nil else { return }

        markReadTasks[entityID] = Task { [weak self] in
            guard let self else { return }
            do {
                try await provider.markEntityRead(entityID: entityID, workspace: workspaceSnapshot)
                markReadTasks[entityID] = nil
                optimisticReadEntityIDs.remove(entityID)
            } catch {
                markReadTasks[entityID] = nil
                NSLog("Unable to mark entity read: \(error.localizedDescription)")
            }
        }
    }

    private func setUnreadCount(_ unreadCount: Int, for entityID: Int64) {
        guard let index = entities.firstIndex(where: { $0.id == entityID }) else { return }
        entities[index].unreadCount = unreadCount
    }

    func downloadAttachments(for item: MailiaTimelineItem) {
        guard item.hasAttachments else { return }
        if case .downloading = attachmentDownloadStates[item.id] {
            return
        }
        attachmentDownloadStates[item.id] = .downloading

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await provider.downloadAttachments(for: item)
                attachmentDownloadStates[item.id] = .downloaded(result)
            } catch {
                attachmentDownloadStates[item.id] = .failed(error.localizedDescription)
            }
        }
    }

    func sendReply(to item: MailiaTimelineItem, body: String, replyAll: Bool = false, accountKey: String? = nil) {
        sendReply(
            to: item,
            content: MailiaComposerContent(plainText: body),
            replyAll: replyAll,
            accountKey: accountKey
        )
    }

    func sendReply(
        to item: MailiaTimelineItem,
        content: MailiaComposerContent,
        replyAll: Bool = false,
        accountKey: String? = nil
    ) {
        guard content.hasRenderableContent else { return }
        if case .sending = replySendState {
            return
        }

        replySendState = .sending
        refreshStatus = "Sending reply..."

        Task { [weak self] in
            guard let self else { return }
            let sendAccountKey = resolvedSendAccountKey(accountKey, fallback: item.accountLabel)
            let refreshAccountKeys = postSendRefreshAccountKeys(
                sendAccountKey: sendAccountKey,
                entityID: item.entityID,
                recipientValues: [item.fromLabel, item.toLabel]
            )
            do {
                try await provider.sendReply(
                    to: item,
                    content: content,
                    replyAll: replyAll,
                    accountKey: sendAccountKey
                )
                replySendState = .sent
                refreshStatus = "Reply sent. Updating conversation..."
                invalidateTimelineCache(entityID: item.entityID)

                await refreshAfterSuccessfulSend(
                    accountKeys: refreshAccountKeys,
                    reloadEntityID: item.entityID,
                    finalStatus: "Reply sent"
                )
            } catch {
                replySendState = .failed(error.localizedDescription)
                refreshStatus = "Unable to send reply: \(error.localizedDescription)"
                NSLog("Unable to send reply: \(error.localizedDescription)")
            }
        }
    }

    func startComposingNewMessage() {
        replySendState = .idle
        hasComposeDraft = true
        isComposingNewMessage = true
        if selectedEntityID != nil {
            selectedEntityID = nil
        }
        loadRecipientSuggestions()
    }

    private func loadRecipientSuggestions() {
        Task { [weak self] in
            guard let self else { return }
            do {
                var suggestions = try await provider.recipientSuggestions()
                guard isComposingNewMessage else { return }
                suggestions = enrichSuggestionsWithAvatars(suggestions)
                recipientSuggestions = suggestions
                resolveSuggestionAvatarsIfNeeded(suggestions)
            } catch {
                NSLog("Unable to load recipient suggestions: \(error.localizedDescription)")
            }
        }
    }

    private func enrichSuggestionsWithAvatars(
        _ suggestions: [MailiaRecipientSuggestion]
    ) -> [MailiaRecipientSuggestion] {
        let avatarByEmail = avatarURLByEmail(from: entities)
        return suggestions.map { suggestion in
            guard suggestion.avatarImageDataURL == nil,
                  let avatarImageDataURL = avatarByEmail[suggestion.email.lowercased()]
            else {
                return suggestion
            }

            return MailiaRecipientSuggestion(
                id: suggestion.id,
                name: suggestion.name,
                email: suggestion.email,
                entityID: suggestion.entityID,
                avatarImageDataURL: avatarImageDataURL
            )
        }
    }

    private func avatarURLByEmail(from entities: [MailiaEntitySummary]) -> [String: String] {
        var avatarByEmail: [String: String] = [:]
        for entity in entities {
            guard let avatarImageDataURL = entity.avatarImageDataURL else { continue }
            for address in [entity.primaryEmailAddress].compactMap({ $0 }) + entity.emailAddresses {
                let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalized.isEmpty else { continue }
                avatarByEmail[normalized] = avatarImageDataURL
            }
        }
        return avatarByEmail
    }

    private func resolveSuggestionAvatarsIfNeeded(_ suggestions: [MailiaRecipientSuggestion]) {
        for suggestion in suggestions {
            guard suggestion.avatarImageDataURL == nil,
                  suggestionAvatarResolutionTasks[suggestion.id] == nil
            else {
                continue
            }

            suggestionAvatarResolutionTasks[suggestion.id] = Task { [weak self] in
                guard let self else { return }
                let dataURL = await avatarResolver.avatarDataURL(forEmailAddress: suggestion.email)
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    suggestionAvatarResolutionTasks[suggestion.id] = nil
                    guard let dataURL else { return }
                    applyRecipientSuggestionAvatar(dataURL, forEmail: suggestion.email)
                }
            }
        }
    }

    private func applyRecipientSuggestionAvatar(_ dataURL: String, forEmail email: String) {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEmail.isEmpty,
              let index = recipientSuggestions.firstIndex(where: {
                  $0.email.lowercased() == normalizedEmail && $0.avatarImageDataURL == nil
              })
        else {
            return
        }

        let suggestion = recipientSuggestions[index]
        recipientSuggestions[index] = MailiaRecipientSuggestion(
            id: suggestion.id,
            name: suggestion.name,
            email: suggestion.email,
            entityID: suggestion.entityID,
            avatarImageDataURL: dataURL
        )
    }

    private func clearSuggestionAvatarResolutionTasks() {
        for task in suggestionAvatarResolutionTasks.values {
            task.cancel()
        }
        suggestionAvatarResolutionTasks.removeAll()
    }

    func cancelComposingNewMessage() {
        guard hasComposeDraft || isComposingNewMessage else { return }
        replySendState = .idle
        hasComposeDraft = false
        isComposingNewMessage = false
        clearSuggestionAvatarResolutionTasks()
        selectFirstEntityIfNeeded()
    }

    func clearReplySendFailure() {
        if case .failed = replySendState {
            replySendState = .idle
        }
    }

    func selectSendAccount(_ accountKey: String) {
        guard sendAccounts.contains(where: { $0.id == accountKey }) else { return }
        selectedSendAccountKey = accountKey
    }

    func refreshConfiguredAccounts() async {
        do {
            applySendAccounts(try await provider.loadSendAccounts())
        } catch {
            NSLog("Unable to load configured accounts: \(error.localizedDescription)")
        }
    }

    func setDefaultSendAccount(accountKey: String) async {
        do {
            try await provider.updateAccountSettings([
                MailiaAccountSettingsUpdate(
                    accountKey: accountKey,
                    displayName: nil,
                    emoji: nil,
                    isDefault: true
                )
            ])
            applySendAccounts(try await provider.loadSendAccounts())
            selectedSendAccountKey = accountKey
        } catch {
            NSLog("Unable to update default account: \(error.localizedDescription)")
        }
    }

    func setAccountEmoji(accountKey: String, emoji: String) async {
        let normalizedEmoji = MailiaSendAccount.normalizedEmoji(emoji)
        do {
            try await provider.updateAccountSettings([
                MailiaAccountSettingsUpdate(
                    accountKey: accountKey,
                    displayName: nil,
                    emoji: normalizedEmoji,
                    isDefault: nil
                )
            ])
            applySendAccounts(try await provider.loadSendAccounts())
        } catch {
            NSLog("Unable to update account emoji: \(error.localizedDescription)")
        }
    }

    func setAccountAlias(accountKey: String, alias: String) async {
        do {
            try await provider.updateAccountSettings([
                MailiaAccountSettingsUpdate(
                    accountKey: accountKey,
                    displayName: alias,
                    emoji: nil,
                    isDefault: nil
                )
            ])
            applySendAccounts(try await provider.loadSendAccounts())
        } catch {
            NSLog("Unable to update account alias: \(error.localizedDescription)")
        }
    }

    func saveAccountSettings(_ updates: [MailiaAccountSettingsUpdate]) async {
        do {
            try await provider.updateAccountSettings(updates)
            applySendAccounts(try await provider.loadSendAccounts())
        } catch {
            NSLog("Unable to update account settings: \(error.localizedDescription)")
        }
    }

    func sendNewMessage(to recipients: [String], subject: String?, body: String, accountKey: String?) {
        sendNewMessage(
            to: recipients,
            subject: subject,
            content: MailiaComposerContent(plainText: body),
            accountKey: accountKey
        )
    }

    func sendNewMessage(
        to recipients: [String],
        subject: String?,
        content: MailiaComposerContent,
        accountKey: String?
    ) {
        let cleanedRecipients = recipients
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard content.hasRenderableContent, !cleanedRecipients.isEmpty else { return }
        if case .sending = replySendState {
            return
        }

        replySendState = .sending
        refreshStatus = "Sending message..."

        Task { [weak self] in
            guard let self else { return }
            let sendAccountKey = resolvedSendAccountKey(accountKey)
            let refreshAccountKeys = postSendRefreshAccountKeys(
                sendAccountKey: sendAccountKey,
                entityID: nil,
                recipientValues: cleanedRecipients
            )
            do {
                try await provider.sendNewMessage(
                    to: cleanedRecipients,
                    subject: subject?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                    content: content,
                    accountKey: sendAccountKey
                )
                replySendState = .sent
                refreshStatus = "Message sent. Updating conversation..."
                hasComposeDraft = false
                isComposingNewMessage = false

                await refreshAfterSuccessfulSend(
                    accountKeys: refreshAccountKeys,
                    reloadEntityID: nil,
                    finalStatus: "Message sent"
                )
            } catch {
                replySendState = .failed(error.localizedDescription)
                refreshStatus = "Unable to send message: \(error.localizedDescription)"
                NSLog("Unable to send message: \(error.localizedDescription)")
            }
        }
    }

    private func refreshAfterSuccessfulSend(
        accountKeys: Set<String>,
        reloadEntityID: Int64?,
        finalStatus: String
    ) async {
        let workspaceSnapshot = workspace
        let searchQuerySnapshot = searchQuery
        let wasRefreshing = isRefreshing
        isRefreshing = true
        if !wasRefreshing {
            refreshActivity = MailiaRefreshProgress(
                phase: .downloading,
                title: "Updating conversation",
                detail: nil,
                fraction: nil
            )
        }
        defer {
            if !wasRefreshing {
                isRefreshing = false
                refreshActivity = nil
            }
        }

        do {
            let snapshot = try await provider.refreshAfterSendingMessage(
                accountKeys: accountKeys,
                workspace: workspaceSnapshot,
                searchQuery: searchQuerySnapshot
            )
            guard workspace == workspaceSnapshot, searchQuery == searchQuerySnapshot else { return }
            let shouldReloadTimeline = reloadEntityID == nil || selectedEntityID == reloadEntityID
            applySnapshot(snapshot, reloadTimelineIfSelectionKept: shouldReloadTimeline)
            refreshStatus = finalStatus
            schedulePostSendFollowUpRefresh(
                accountKeys: accountKeys,
                workspace: workspaceSnapshot,
                searchQuery: searchQuerySnapshot
            )
        } catch {
            refreshStatus = "\(finalStatus). Unable to update conversation: \(error.localizedDescription)"
            NSLog("Unable to refresh after sending message: \(error.localizedDescription)")
            schedulePostSendFollowUpRefresh(
                accountKeys: accountKeys,
                workspace: workspaceSnapshot,
                searchQuery: searchQuerySnapshot
            )
        }
    }

    private func schedulePostSendFollowUpRefresh(
        accountKeys: Set<String>,
        workspace workspaceSnapshot: MailiaWorkspace,
        searchQuery searchQuerySnapshot: String
    ) {
        let normalizedAccountKeys = Set(
            accountKeys
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard !normalizedAccountKeys.isEmpty,
              !postSendFollowUpRefreshDelaysNanoseconds.isEmpty
        else {
            return
        }

        let taskID = UUID()
        let delays = postSendFollowUpRefreshDelaysNanoseconds
        postSendFollowUpRefreshTasks[taskID] = Task { [weak self] in
            for delay in delays {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await self?.runPostSendFollowUpRefresh(
                    accountKeys: normalizedAccountKeys,
                    workspace: workspaceSnapshot,
                    searchQuery: searchQuerySnapshot
                )
            }

            await MainActor.run {
                self?.postSendFollowUpRefreshTasks[taskID] = nil
            }
        }
    }

    private func runPostSendFollowUpRefresh(
        accountKeys: Set<String>,
        workspace workspaceSnapshot: MailiaWorkspace,
        searchQuery searchQuerySnapshot: String
    ) async {
        guard workspace == workspaceSnapshot,
              searchQuery == searchQuerySnapshot
        else {
            return
        }

        do {
            let snapshot = try await provider.refreshAfterSendingMessage(
                accountKeys: accountKeys,
                workspace: workspaceSnapshot,
                searchQuery: searchQuerySnapshot
            )
            guard workspace == workspaceSnapshot,
                  searchQuery == searchQuerySnapshot
            else {
                return
            }
            applySnapshot(snapshot, reloadTimelineIfSelectionKept: true)
        } catch {
            NSLog("Unable to run delayed post-send refresh: \(error.localizedDescription)")
        }
    }

    private func postSendRefreshAccountKeys(
        sendAccountKey: String?,
        entityID: Int64?,
        recipientValues: [String]
    ) -> Set<String> {
        var accountKeys = Set<String>()
        if let sendAccountKey = sendAccountKey?.nilIfBlank {
            accountKeys.insert(sendAccountKey)
        }
        if let entityID {
            accountKeys.formUnion(localAccountKeys(forEntityID: entityID))
        }
        accountKeys.formUnion(localAccountKeys(forEmailValues: recipientValues))
        return accountKeys
    }

    private func resolvedSendAccountKey(_ requestedAccountKey: String?, fallback: String? = nil) -> String? {
        requestedAccountKey?.nilIfBlank
            ?? selectedSendAccountKey?.nilIfBlank
            ?? sendAccounts.first(where: { $0.isDefault })?.id.nilIfBlank
            ?? sendAccounts.first?.id.nilIfBlank
            ?? fallback?.nilIfBlank
    }

    private func localAccountKeys(forEntityID entityID: Int64) -> Set<String> {
        guard let entity = entities.first(where: { $0.id == entityID }) else { return [] }
        return localAccountKeys(forEmailValues: [entity.primaryEmailAddress].compactMap { $0 } + entity.emailAddresses)
    }

    private static func emailAddresses(for entity: MailiaEntitySummary) -> Set<String> {
        let values = entity.emailAddresses.isEmpty
            ? [entity.primaryEmailAddress].compactMap { $0 }
            : entity.emailAddresses
        return Set(values.flatMap(normalizedEmailAddresses(in:)))
    }

    private func localAccountKeys(forEmailValues values: [String]) -> Set<String> {
        let normalizedEmails = Set(values.flatMap(Self.normalizedEmailAddresses(in:)))
        guard !normalizedEmails.isEmpty else { return [] }

        return Set(sendAccounts.compactMap { account in
            guard let emailAddress = account.emailAddress,
                  let normalizedEmail = Self.normalizedEmailAddresses(in: emailAddress).first,
                  normalizedEmails.contains(normalizedEmail)
            else {
                return nil
            }
            return account.id
        })
    }

    private static func normalizedEmailAddresses(in value: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",;")
        return value
            .components(separatedBy: separators)
            .compactMap { component in
                var candidate = component.trimmingCharacters(in: .whitespacesAndNewlines)
                if let open = candidate.firstIndex(of: "<"),
                   let close = candidate[open...].firstIndex(of: ">") {
                    candidate = String(candidate[candidate.index(after: open)..<close])
                }
                candidate = candidate.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'<>")))
                guard candidate.contains("@") else { return nil }
                return candidate.lowercased()
            }
    }

    private func reloadForCurrentFilters() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            await self?.loadSnapshot(statusPrefix: "Filtered", refresh: false)
        }
    }

    private func clearPresentationForFilterChange() {
        requestGeneration += 1
        timelineGeneration += 1
        reloadTask?.cancel()
        partialRefreshSnapshotTask?.cancel()
        partialRefreshSnapshotTask = nil
        partialRefreshSnapshotNeedsReload = false
        listFetchQueue.cancelAll()
        avatarCacheHydrationTask?.cancel()
        reloadTask = nil
        isLoadingEntityList = true
        selectedEntityID = nil
        entities = []
        timeline = []
        timelineBodyStates = [:]
        attachmentDownloadStates = [:]
        isLoadingTimeline = false
        resetTimelineWindowState()
    }

    private func loadSnapshot(
        statusPrefix: String,
        refresh: Bool,
        refreshIfEmpty: Bool = false,
        refreshIfStaleAfter: TimeInterval? = nil,
        options explicitRefreshOptions: MailiaRefreshOptions? = nil
    ) async {
        requestGeneration += 1
        let generation = requestGeneration
        let workspaceSnapshot = workspace
        let searchQuerySnapshot = searchQuery
        let refreshOptions = refresh ? (explicitRefreshOptions ?? currentRefreshOptions()) : MailiaRefreshOptions()
        beginRefreshPresentation(title: refresh ? "Refreshing" : "Loading")
        defer {
            if generation == requestGeneration {
                partialRefreshSnapshotTask?.cancel()
                partialRefreshSnapshotTask = nil
                partialRefreshSnapshotNeedsReload = false
                isRefreshing = false
                isLoadingEntityList = false
                refreshActivity = nil
            }
        }

        do {
            let handleRefreshProgress: @MainActor (MailiaRefreshProgress) -> Void = { [weak self] progress in
                guard let self, generation == requestGeneration else { return }
                refreshActivity = progress
                refreshStatus = progress.detail.map { "\(progress.title) — \($0)" } ?? progress.title
                if progress.phase == .downloading, (progress.fraction ?? 0) > 0 {
                    schedulePartialRefreshSnapshot(
                        generation: generation,
                        workspace: workspaceSnapshot,
                        searchQuery: searchQuerySnapshot
                    )
                }
            }
            var snapshot: MailiaSnapshot
            var finalStatusPrefix = statusPrefix
            var publishedSnapshotBeforeRefresh = false
            if refresh {
                snapshot = try await provider.refresh(
                    workspace: workspaceSnapshot,
                    searchQuery: searchQuerySnapshot,
                    options: refreshOptions
                ) { progress in handleRefreshProgress(progress) }
            } else {
                snapshot = try await provider.loadSnapshot(workspace: workspaceSnapshot, searchQuery: searchQuerySnapshot)
                let canStartupRefresh = searchQuerySnapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let shouldRefreshEmptySnapshot = refreshIfEmpty && snapshot.entities.isEmpty && canStartupRefresh
                let shouldRefreshStaleSnapshot = try await shouldRefreshStartupSnapshot(
                    after: refreshIfStaleAfter,
                    canRefresh: canStartupRefresh,
                    hasLocalEntities: !snapshot.entities.isEmpty
                )
                if shouldRefreshEmptySnapshot || shouldRefreshStaleSnapshot {
                    if shouldRefreshStaleSnapshot {
                        applySnapshot(snapshot, reloadTimelineIfSelectionKept: false)
                        publishedSnapshotBeforeRefresh = true
                    }
                    refreshStatus = shouldRefreshEmptySnapshot
                        ? "No local mail. Fetching messages..."
                        : "Mail is stale. Refreshing..."
                    snapshot = try await provider.refresh(
                        workspace: workspaceSnapshot,
                        searchQuery: searchQuerySnapshot,
                        options: MailiaRefreshOptions()
                    ) { progress in handleRefreshProgress(progress) }
                    finalStatusPrefix = "Refreshed"
                }
            }

            guard generation == requestGeneration else { return }

            applySnapshot(snapshot, reloadTimelineIfSelectionKept: refresh || publishedSnapshotBeforeRefresh)
            await refreshSendAccounts()
            refreshStatus = "\(finalStatusPrefix) \(Self.statusFormatter.string(from: snapshot.loadedAt))"
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration else { return }
            let failureStatus = "\(refresh ? "Unable to refresh mail" : "Unable to load mail"): \(error.localizedDescription)"
            if refresh || refreshIfEmpty {
                do {
                    let snapshot = try await provider.loadSnapshot(
                        workspace: workspaceSnapshot,
                        searchQuery: searchQuerySnapshot
                    )
                    guard generation == requestGeneration else { return }
                    applySnapshot(snapshot, reloadTimelineIfSelectionKept: false)
                } catch {
                    if entities.isEmpty {
                        timeline = []
                        timelineBodyStates = [:]
                        resetTimelineWindowState()
                    }
                }
            } else if entities.isEmpty {
                timeline = []
                timelineBodyStates = [:]
                resetTimelineWindowState()
            }
            await refreshSendAccounts()
            refreshStatus = failureStatus
        }
    }

    private func shouldRefreshStartupSnapshot(
        after stalenessThreshold: TimeInterval?,
        canRefresh: Bool,
        hasLocalEntities: Bool
    ) async throws -> Bool {
        guard let stalenessThreshold, canRefresh, hasLocalEntities else {
            return false
        }
        guard let lastRefreshFinishedAt = try await provider.lastRefreshFinishedAt() else {
            return false
        }
        return now().timeIntervalSince(lastRefreshFinishedAt) > stalenessThreshold
    }

    private func beginRefreshPresentation(title: String) {
        isRefreshing = true
        isLoadingEntityList = true
        refreshStatus = "\(title)..."
        refreshActivity = MailiaRefreshProgress(
            phase: .discovering,
            title: title,
            detail: nil,
            fraction: nil
        )
    }

    private func refreshSendAccountsInBackground() {
        sendAccountsRefreshTask?.cancel()
        sendAccountsRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let accounts = try await provider.loadSendAccounts()
                guard !Task.isCancelled else { return }
                applySendAccounts(accounts)
            } catch is CancellationError {
                return
            } catch {
                NSLog("Unable to refresh send accounts: \(error.localizedDescription)")
            }
            sendAccountsRefreshTask = nil
        }
    }

    private func refreshSendAccounts() async {
        do {
            applySendAccounts(try await provider.loadSendAccounts())
        } catch {
            NSLog("Unable to refresh send accounts: \(error.localizedDescription)")
        }
    }

    private func currentRefreshOptions() -> MailiaRefreshOptions {
        var preferredAccountKeys: [String] = []
        var seen = Set<String>()

        func append(_ accountKey: String?) {
            guard let accountKey = accountKey?.nilIfBlank,
                  seen.insert(accountKey).inserted
            else {
                return
            }
            preferredAccountKeys.append(accountKey)
        }

        if let selectedEntityID,
           let selectedEntity = entities.first(where: { $0.id == selectedEntityID }) {
            for accountKey in selectedEntity.accountKeys {
                append(accountKey)
            }
        }
        for item in timeline.reversed() {
            append(item.accountLabel)
        }
        append(selectedSendAccountKey)

        return MailiaRefreshOptions(preferredAccountKeys: preferredAccountKeys)
    }

    private func schedulePartialRefreshSnapshot(
        generation: Int,
        workspace workspaceSnapshot: MailiaWorkspace,
        searchQuery searchQuerySnapshot: String
    ) {
        partialRefreshSnapshotNeedsReload = true
        guard partialRefreshSnapshotTask == nil else { return }

        let delay = partialRefreshSnapshotDelayNanoseconds
        partialRefreshSnapshotTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            await self?.applyPartialRefreshSnapshot(
                generation: generation,
                workspace: workspaceSnapshot,
                searchQuery: searchQuerySnapshot
            )
        }
    }

    private func applyPartialRefreshSnapshot(
        generation: Int,
        workspace workspaceSnapshot: MailiaWorkspace,
        searchQuery searchQuerySnapshot: String
    ) async {
        guard generation == requestGeneration,
              isRefreshing,
              workspace == workspaceSnapshot,
              searchQuery == searchQuerySnapshot
        else {
            partialRefreshSnapshotTask = nil
            partialRefreshSnapshotNeedsReload = false
            return
        }

        partialRefreshSnapshotNeedsReload = false
        do {
            let selectedBeforeReload = selectedEntityID
            let selectedEntityBeforeReload = selectedBeforeReload.flatMap { selectedEntityID in
                entities.first { $0.id == selectedEntityID }
            }
            let snapshot = try await provider.loadSnapshot(workspace: workspaceSnapshot, searchQuery: searchQuerySnapshot)
            guard generation == requestGeneration,
                  isRefreshing,
                  workspace == workspaceSnapshot,
                  searchQuery == searchQuerySnapshot
            else {
                partialRefreshSnapshotTask = nil
                partialRefreshSnapshotNeedsReload = false
                return
            }

            applySnapshot(snapshot, reloadTimelineIfSelectionKept: false)
            let selectedEntityAfterReload = selectedBeforeReload.flatMap { selectedEntityID in
                entities.first { $0.id == selectedEntityID }
            }
            if selectedEntityID == selectedBeforeReload,
               selectedEntityHasTimelineRelevantChanges(
                   before: selectedEntityBeforeReload,
                   after: selectedEntityAfterReload
               ) {
                refreshSelectedTimelineIncrementally()
            }
        } catch is CancellationError {
            partialRefreshSnapshotTask = nil
            return
        } catch {
            NSLog("Unable to apply partial refresh snapshot: \(error.localizedDescription)")
        }

        partialRefreshSnapshotTask = nil
        if partialRefreshSnapshotNeedsReload {
            schedulePartialRefreshSnapshot(
                generation: generation,
                workspace: workspaceSnapshot,
                searchQuery: searchQuerySnapshot
            )
        }
    }

    private func selectedEntityHasTimelineRelevantChanges(
        before: MailiaEntitySummary?,
        after: MailiaEntitySummary?
    ) -> Bool {
        guard let before, let after else { return before != nil || after != nil }
        return before.latestDate != after.latestDate
            || before.latestMessageID != after.latestMessageID
            || before.latestSubject != after.latestSubject
            || before.latestBodyPreview != after.latestBodyPreview
            || before.unreadCount != after.unreadCount
            || Set(before.accountKeys) != Set(after.accountKeys)
    }

    private func refreshSelectedTimelineIncrementally() {
        guard selectedEntityID != nil, !isLoadingTimeline, !isLoadingNewerTimeline else { return }
        guard let newestID = timeline.last?.id else {
            loadTimelineForSelection()
            return
        }
        loadTimelinePage(direction: .newer, anchorID: newestID, preserveAnchorID: newestID)
    }

    private func performEntityAction(
        _ action: MailiaEntityAction,
        entityID: Int64,
        actionWorkspace: MailiaWorkspace
    ) async {
        refreshStatus = action.statusLabel

        do {
            try await provider.performEntityAction(action, entityID: entityID, workspace: actionWorkspace) { [weak self] status in
                self?.refreshStatus = status
            }
            invalidateTimelineCache(entityID: entityID)
            optimisticHiddenEntityIDs.remove(entityID)
            refreshStatus = "Reloading mail..."
            await reconcileSnapshotAfterEntityAction(statusPrefix: "Updated")
        } catch {
            optimisticHiddenEntityIDs.remove(entityID)
            refreshStatus = "Unable to update entity: \(error.localizedDescription)"
            NSLog("Unable to update entity: \(error.localizedDescription)")
            await reconcileSnapshotAfterEntityAction(statusPrefix: "Restored")
        }
    }

    private func loadTimelineForSelection() {
        timelineGeneration += 1
        let generation = timelineGeneration
        let workspaceSnapshot = workspace
        listFetchQueue.cancelAll()
        cancelBodyLoadTasks()
        guard let selectedEntityID else {
            MailiaScrollDebugLog("[MailiaScrollDebug] loadTimelineForSelection cleared selection generation=\(generation)")
            timeline = []
            timelineBodyStates = [:]
            resetTimelineWindowState()
            return
        }

        resetTimelineWindowState()
        let hasCachedPage = timelineWindowStore.hasCachedPage(workspace: workspaceSnapshot, entityID: selectedEntityID)
        MailiaScrollDebugLog("[MailiaScrollDebug] loadTimelineForSelection start entityID=\(selectedEntityID) generation=\(generation) hasCachedPage=\(hasCachedPage)")
        if let cached = timelineWindowStore.cachedPage(workspace: workspaceSnapshot, entityID: selectedEntityID) {
            timeline = cached.items
            applyAccountVisualsToTimeline()
            timelineBodyStates = cachedBodyStates(for: cached.items)
            hasOlderTimeline = cached.hasOlderTimeline
            hasNewerTimeline = cached.hasNewerTimeline
            timelineWindowStore.primeBodyAccessOrder(items: cached.items, bodyStates: timelineBodyStates)
            MailiaScrollDebugLog("[MailiaScrollDebug] applied cached timeline entityID=\(selectedEntityID) generation=\(generation) itemCount=\(cached.items.count) latestID=\(cached.items.last?.id.description ?? "nil")")
            if let latestID = cached.items.last?.id {
                publishTimelineScrollAnchor(id: latestID, edge: .bottom)
            }
            prefetchSelectedTimelineBodies()
        } else if !timeline.contains(where: { $0.entityID == selectedEntityID }) {
            timeline = []
            timelineBodyStates = [:]
        }
        isLoadingTimeline = !hasCachedPage

        listFetchQueue.enqueue(
            id: .selectedTimeline(entityID: selectedEntityID),
            priority: .selected
        ) { [weak self] in
            guard let self else { return }
            do {
                let page = try await provider.loadTimelinePage(
                    entityID: selectedEntityID,
                    workspace: workspaceSnapshot,
                    direction: .latest,
                    anchorID: nil,
                    limit: timelinePageSize
                )
                guard generation == timelineGeneration else { return }
                cacheTimelinePage(
                    workspace: workspaceSnapshot,
                    entityID: selectedEntityID,
                    items: page.items,
                    hasOlderTimeline: page.hasMore,
                    hasNewerTimeline: false
                )
                timeline = page.items
                applyAccountVisualsToTimeline()
                timelineBodyStates = cachedBodyStates(for: page.items)
                hasOlderTimeline = page.hasMore
                hasNewerTimeline = false
                MailiaScrollDebugLog("[MailiaScrollDebug] loaded latest timeline entityID=\(selectedEntityID) generation=\(generation) itemCount=\(page.items.count) latestID=\(page.items.last?.id.description ?? "nil") hasOlder=\(page.hasMore)")
                if let latestID = page.items.last?.id {
                    publishTimelineScrollAnchor(id: latestID, edge: .bottom)
                }
                prefetchSelectedTimelineBodies()
                isLoadingTimeline = false
            } catch is CancellationError {
                if generation == timelineGeneration {
                    isLoadingTimeline = false
                }
            } catch {
                guard generation == timelineGeneration else { return }
                if !timeline.contains(where: { $0.entityID == selectedEntityID }) {
                    timeline = []
                    timelineBodyStates = [:]
                    resetTimelineWindowState()
                }
                isLoadingTimeline = false
                NSLog("Unable to load timeline: \(error.localizedDescription)")
            }
        }
    }

    func loadOlderTimelineIfNeeded() {
        guard !isLoadingTimeline, !isLoadingOlderTimeline, hasOlderTimeline else { return }
        guard selectedEntityID != nil, let oldestID = timeline.first?.id else { return }
        loadTimelinePage(direction: .older, anchorID: oldestID, preserveAnchorID: oldestID)
    }

    func loadNewerTimelineIfNeeded() {
        guard !isLoadingTimeline, !isLoadingNewerTimeline, hasNewerTimeline else { return }
        guard selectedEntityID != nil, let newestID = timeline.last?.id else { return }
        loadTimelinePage(direction: .newer, anchorID: newestID, preserveAnchorID: newestID)
    }

    func refreshNewerTimelineForSelection() {
        guard !isLoadingTimeline, !isLoadingNewerTimeline else { return }
        if hasNewerTimeline {
            loadNewerTimelineIfNeeded()
            return
        }

        Task { [weak self] in
            await self?.refreshNewerTimelineForSelection()
        }
    }

    private func refreshNewerTimelineForSelection() async {
        guard !isRefreshing,
              let selectedEntityID,
              let entity = entities.first(where: { $0.id == selectedEntityID })
        else {
            return
        }

        let accountKeys = Set(entity.accountKeys)
        guard !accountKeys.isEmpty else {
            loadNewerTimelineIfNeeded()
            return
        }

        let workspaceSnapshot = workspace
        let searchQuerySnapshot = searchQuery
        isRefreshing = true
        isLoadingNewerTimeline = true
        refreshActivity = MailiaRefreshProgress(
            phase: .downloading,
            title: "Checking for new messages",
            detail: entity.displayName,
            fraction: nil
        )
        refreshStatus = "Checking for new messages..."

        do {
            let snapshot = try await provider.refreshNewerTimelineMessages(
                accountKeys: accountKeys,
                workspace: workspaceSnapshot,
                searchQuery: searchQuerySnapshot
            )
            guard self.selectedEntityID == selectedEntityID,
                  workspace == workspaceSnapshot,
                  searchQuery == searchQuerySnapshot
            else {
                isRefreshing = false
                isLoadingNewerTimeline = false
                refreshActivity = nil
                return
            }

            isRefreshing = false
            isLoadingNewerTimeline = false
            refreshActivity = nil
            applySnapshot(snapshot, reloadTimelineIfSelectionKept: false)
            refreshSelectedTimelineIncrementally()
            refreshStatus = "Checked for new messages"
        } catch is CancellationError {
            isRefreshing = false
            isLoadingNewerTimeline = false
            refreshActivity = nil
        } catch {
            isRefreshing = false
            isLoadingNewerTimeline = false
            refreshActivity = nil
            refreshStatus = "Unable to check new messages: \(error.localizedDescription)"
            NSLog("Unable to refresh newer timeline messages: \(error.localizedDescription)")
        }
    }

    func loadBodyIfNeeded(for item: MailiaTimelineItem, priority requestedPriority: Int? = nil) {
        bodyLoadQueue.loadIfNeeded(for: item, priority: BodyFetchPriority(webPriority: requestedPriority))
    }

    private func prefetchSelectedTimelineBodies() {
        guard selectedEntityID != nil, !timeline.isEmpty else { return }
        for item in timeline.suffix(selectedTimelineBodyPrefetchLimit).reversed() {
            bodyLoadQueue.loadIfNeeded(for: item, priority: .selectedPage)
        }
    }

    private func scheduleEntityPreviewBodyPrefetch() {
        entityPreviewBodyPrefetchTask?.cancel()
        entityPreviewBodyPrefetchTask = nil
        let workspaceSnapshot = workspace
        let generation = requestGeneration
        let candidateEntityIDs = entities
            .filter { entity in
                entity.latestMessageID != nil &&
                    entity.latestBodyPreview?.nilIfBlank == nil
            }
            .prefix(entityPreviewBodyPrefetchLimit)
            .map(\.id)
        guard !candidateEntityIDs.isEmpty else { return }

        entityPreviewBodyPrefetchTask = Task { [weak self] in
            guard let self else { return }
            defer { entityPreviewBodyPrefetchTask = nil }
            do {
                let items = try await provider.loadLatestTimelineItems(
                    entityIDs: Array(candidateEntityIDs),
                    workspace: workspaceSnapshot
                )
                guard generation == requestGeneration,
                      workspace == workspaceSnapshot,
                      !Task.isCancelled else {
                    return
                }
                for item in items {
                    bodyLoadQueue.loadIfNeeded(
                        for: item,
                        priority: .entityPreview,
                        requiresTimelineMembership: false
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                NSLog("Unable to prefetch entity preview bodies: \(error.localizedDescription)")
            }
        }
    }

    private func loadTimelinePage(direction: MailiaTimelinePageDirection, anchorID: Int64, preserveAnchorID: Int64) {
        let generation = timelineGeneration
        let workspaceSnapshot = workspace
        guard let selectedEntityID else { return }

        switch direction {
        case .older:
            isLoadingOlderTimeline = true
        case .newer:
            isLoadingNewerTimeline = true
        case .latest:
            isLoadingTimeline = true
        }

        listFetchQueue.enqueue(
            id: .timelinePage(direction: direction),
            priority: .incremental
        ) { [weak self] in
            guard let self else { return }
            do {
                let page = try await provider.loadTimelinePage(
                    entityID: selectedEntityID,
                    workspace: workspaceSnapshot,
                    direction: direction,
                    anchorID: anchorID,
                    limit: timelinePageSize
                )
                guard generation == timelineGeneration else { return }
                applyTimelinePage(page, direction: direction, preserveAnchorID: preserveAnchorID)
            } catch is CancellationError {
                if generation == timelineGeneration {
                    clearTimelinePageLoadingFlag(direction)
                }
                return
            } catch {
                guard generation == timelineGeneration else { return }
                NSLog("Unable to load timeline page: \(error.localizedDescription)")
            }
            clearTimelinePageLoadingFlag(direction)
        }
    }

    private func optimisticallyHideEntity(_ entityID: Int64) {
        optimisticHiddenEntityIDs.insert(entityID)
        invalidateTimelineCache(entityID: entityID)

        let previousEntities = entities
        guard previousEntities.contains(where: { $0.id == entityID }) else { return }

        let replacementSelection: Int64?
        if selectedEntityID == entityID {
            replacementSelection = nextEntityID(afterRemoving: entityID, from: previousEntities)
        } else {
            replacementSelection = selectedEntityID
        }

        entities = previousEntities.filter { $0.id != entityID }
        if selectedEntityID != replacementSelection {
            selectedEntityID = replacementSelection
        } else if selectedEntityID == nil {
            timeline = []
            timelineBodyStates = [:]
            resetTimelineWindowState()
        }
    }

    private func nextEntityID(afterRemoving entityID: Int64, from entities: [MailiaEntitySummary]) -> Int64? {
        guard let index = entities.firstIndex(where: { $0.id == entityID }) else {
            return entities.first?.id
        }
        let nextIndex = entities.index(after: index)
        if entities.indices.contains(nextIndex) {
            return entities[nextIndex].id
        }
        if index > entities.startIndex {
            let previousIndex = entities.index(before: index)
            return entities[previousIndex].id
        }
        return nil
    }

    private func applyAccountVisualsToTimeline() {
        let userEmojiByAccount: [String: String] = Dictionary(
            uniqueKeysWithValues: sendAccounts.compactMap { account -> (String, String)? in
                guard let emoji = MailiaSendAccount.normalizedEmoji(account.emoji) else { return nil }
                return (account.id, emoji)
            }
        )
        let avatarByAccount: [String: String] = Dictionary(
            uniqueKeysWithValues: sendAccounts.compactMap { account -> (String, String)? in
                guard MailiaSendAccount.normalizedEmoji(account.emoji) == nil,
                      let avatarImageDataURL = account.avatarImageDataURL?.nilIfBlank
                else {
                    return nil
                }
                return (account.id, avatarImageDataURL)
            }
        )
        let fallbackEmojiByAccount: [String: String] = Dictionary(
            uniqueKeysWithValues: sendAccounts.compactMap { account -> (String, String)? in
                guard userEmojiByAccount[account.id] == nil,
                      avatarByAccount[account.id] == nil
                else {
                    return nil
                }
                return (account.id, AccountEmojiFallback.emoji(for: account.id, in: sendAccounts))
            }
        )
        guard !userEmojiByAccount.isEmpty
            || !avatarByAccount.isEmpty
            || !fallbackEmojiByAccount.isEmpty
            || timeline.contains(where: { $0.accountEmoji != nil || $0.accountAvatarImageDataURL != nil })
        else {
            return
        }

        timeline = timeline.map { item in
            let emoji = userEmojiByAccount[item.accountLabel] ?? fallbackEmojiByAccount[item.accountLabel]
            let avatar = userEmojiByAccount[item.accountLabel] == nil ? avatarByAccount[item.accountLabel] : nil
            return MailiaTimelineItem(
                id: item.id,
                entityID: item.entityID,
                direction: item.direction,
                subject: item.subject,
                preview: item.preview,
                html: item.html,
                htmlVariants: item.htmlVariants,
                date: item.date,
                accountLabel: item.accountLabel,
                accountEmoji: emoji,
                accountAvatarImageDataURL: avatar,
                folderLabel: item.folderLabel,
                envelopeID: item.envelopeID,
                isFlagged: item.isFlagged,
                fromLabel: item.fromLabel,
                toLabel: item.toLabel,
                hasAttachments: item.hasAttachments
            )
        }
    }

    private func applySnapshot(_ snapshot: MailiaSnapshot, reloadTimelineIfSelectionKept: Bool) {
        applySendAccounts(snapshot.sendAccounts)
        if let selectedSendAccountKey,
           !snapshot.sendAccounts.contains(where: { $0.id == selectedSendAccountKey }) {
            self.selectedSendAccountKey = nil
        }
        let visibleEntities = snapshot.entities
            .filter { !optimisticHiddenEntityIDs.contains($0.id) }
            .map { entity in
                guard optimisticReadEntityIDs.contains(entity.id) else { return entity }
                var readEntity = entity
                readEntity.unreadCount = 0
                return readEntity
            }
        entities = mergeExistingAvatarImages(into: visibleEntities)
        if let currentSelection = selectedEntityID, visibleEntities.contains(where: { $0.id == currentSelection }) {
            if reloadTimelineIfSelectionKept {
                loadTimelineForSelection()
            }
        } else if isComposingNewMessage {
            selectedEntityID = nil
        } else {
            selectedEntityID = visibleEntities.first?.id
        }
        if selectedEntityID == nil {
            timeline = []
            timelineBodyStates = [:]
            resetTimelineWindowState()
        } else {
            scheduleMarkSelectedEntityReadIfNeeded()
        }
        scheduleEntityPreviewBodyPrefetch()
        hydrateCachedAvatarImagesThenResolve()
    }

    private func applySendAccounts(_ accounts: [MailiaSendAccount]) {
        sendAccounts = mergeExistingAccountAvatarImages(into: accounts)
        cancelAccountAvatarTasksNoLongerNeeded()
        applyAccountVisualsToTimeline()
        hydrateAccountAvatarImagesIfNeeded()
    }

    private func mergeExistingAccountAvatarImages(into accounts: [MailiaSendAccount]) -> [MailiaSendAccount] {
        let existingByID = Dictionary(uniqueKeysWithValues: sendAccounts.map { ($0.id, $0) })
        return accounts.map { account in
            guard MailiaSendAccount.normalizedEmoji(account.emoji) == nil,
                  let existing = existingByID[account.id],
                  existing.emailAddress == account.emailAddress,
                  let avatarImageDataURL = existing.avatarImageDataURL?.nilIfBlank
            else {
                return accountWithAvatar(account, avatarImageDataURL: nil)
            }

            return accountWithAvatar(account, avatarImageDataURL: avatarImageDataURL)
        }
    }

    private func hydrateAccountAvatarImagesIfNeeded() {
        for account in sendAccounts {
            guard MailiaSendAccount.normalizedEmoji(account.emoji) == nil,
                  account.avatarImageDataURL?.nilIfBlank == nil,
                  let emailAddress = account.emailAddress?.nilIfBlank,
                  accountAvatarResolutionTasks[account.id] == nil
            else {
                continue
            }

            accountAvatarResolutionTasks[account.id] = Task { [weak self] in
                guard let self else { return }
                let cachedDataURL = await avatarResolver.cachedGravatarDataURL(forEmailAddress: emailAddress)
                let dataURL: String?
                if let cachedDataURL {
                    dataURL = cachedDataURL
                } else {
                    dataURL = await avatarResolver.gravatarDataURL(forEmailAddress: emailAddress)
                }
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    self.accountAvatarResolutionTasks[account.id] = nil
                    guard let dataURL else { return }
                    self.applyAccountAvatarDataURL(dataURL, accountID: account.id, emailAddress: emailAddress)
                    self.applyAccountVisualsToTimeline()
                }
            }
        }
    }

    private func cancelAccountAvatarTasksNoLongerNeeded() {
        let accountsByID = Dictionary(uniqueKeysWithValues: sendAccounts.map { ($0.id, $0) })
        for (accountID, task) in Array(accountAvatarResolutionTasks) {
            guard let account = accountsByID[accountID],
                  MailiaSendAccount.normalizedEmoji(account.emoji) == nil,
                  account.avatarImageDataURL?.nilIfBlank == nil,
                  account.emailAddress?.nilIfBlank != nil
            else {
                task.cancel()
                accountAvatarResolutionTasks[accountID] = nil
                continue
            }
        }
    }

    private func applyAccountAvatarDataURL(
        _ dataURL: String,
        accountID: String,
        emailAddress: String
    ) {
        guard let index = sendAccounts.firstIndex(where: {
            $0.id == accountID
                && MailiaSendAccount.normalizedEmoji($0.emoji) == nil
                && $0.emailAddress == emailAddress
                && $0.avatarImageDataURL?.nilIfBlank == nil
        }) else {
            return
        }

        var updatedAccounts = sendAccounts
        updatedAccounts[index] = accountWithAvatar(updatedAccounts[index], avatarImageDataURL: dataURL)
        sendAccounts = updatedAccounts
    }

    private func accountWithAvatar(
        _ account: MailiaSendAccount,
        avatarImageDataURL: String?
    ) -> MailiaSendAccount {
        MailiaSendAccount(
            id: account.id,
            label: account.label,
            emailAddress: account.emailAddress,
            displayName: account.displayName,
            isDefault: account.isDefault,
            emoji: account.emoji,
            sortOrder: account.sortOrder,
            syncStatus: account.syncStatus,
            syncErrorMessage: account.syncErrorMessage,
            syncCheckedAt: account.syncCheckedAt,
            avatarImageDataURL: avatarImageDataURL?.nilIfBlank
        )
    }

    private func selectFirstEntityIfNeeded() {
        guard selectedEntityID == nil,
              !isComposingNewMessage
        else {
            return
        }
        selectedEntityID = entities.first?.id
    }

    private func reconcileSnapshotAfterEntityAction(statusPrefix: String) async {
        let workspaceSnapshot = workspace
        let searchQuerySnapshot = searchQuery
        do {
            let snapshot = try await provider.loadSnapshot(workspace: workspaceSnapshot, searchQuery: searchQuerySnapshot)
            guard workspace == workspaceSnapshot, searchQuery == searchQuerySnapshot else { return }
            applySnapshot(snapshot, reloadTimelineIfSelectionKept: true)
            refreshStatus = "\(statusPrefix) \(Self.statusFormatter.string(from: snapshot.loadedAt))"
        } catch {
            refreshStatus = "Unable to reload mail: \(error.localizedDescription)"
            NSLog("Unable to reload mail: \(error.localizedDescription)")
        }
    }

    private func mergeExistingAvatarImages(into nextEntities: [MailiaEntitySummary]) -> [MailiaEntitySummary] {
        let existingByID = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })
        return nextEntities.map { entity in
            guard let existing = existingByID[entity.id],
                  existing.primaryEmailAddress == entity.primaryEmailAddress,
                  existing.emailAddresses == entity.emailAddresses,
                  let avatarImageDataURL = existing.avatarImageDataURL
            else {
                return entity
            }

            var merged = entity
            merged.avatarImageDataURL = avatarImageDataURL
            return merged
        }
    }

    private func hydrateCachedAvatarImagesThenResolve() {
        avatarCacheHydrationTask?.cancel()

        let candidates = entities.filter { entity in
            entity.avatarImageDataURL == nil &&
                (entity.primaryEmailAddress?.nilIfBlank != nil || !entity.emailAddresses.isEmpty)
        }
        guard !candidates.isEmpty else {
            resolveFocusedAvatarImagesIfNeeded()
            return
        }

        let generation = requestGeneration
        let resolver = avatarResolver
        avatarCacheHydrationTask = Task { [weak self] in
            var cachedAvatars: [Int64: String] = [:]
            for entity in candidates {
                guard !Task.isCancelled else { return }
                if let dataURL = await resolver.cachedAvatarDataURL(
                    primaryEmailAddress: entity.primaryEmailAddress,
                    emailAddresses: entity.emailAddresses
                ) {
                    cachedAvatars[entity.id] = dataURL
                }
            }

            await MainActor.run {
                guard let self,
                      self.requestGeneration == generation,
                      !Task.isCancelled
                else {
                    return
                }

                if !cachedAvatars.isEmpty {
                    self.entities = self.entities.map { entity in
                        guard entity.avatarImageDataURL == nil,
                              let dataURL = cachedAvatars[entity.id]
                        else {
                            return entity
                        }
                        var updated = entity
                        updated.avatarImageDataURL = dataURL
                        return updated
                    }
                }
                self.resolveFocusedAvatarImagesIfNeeded()
            }
        }
    }

    private func resolveAvatarImagesIfNeeded(
        for entities: [MailiaEntitySummary],
        cancelTasksOutsideSet: Bool = true,
        source: String? = nil,
        priority requestedPriority: AvatarResolutionPriority? = nil
    ) {
        if cancelTasksOutsideSet {
            let visibleEntityIDs = Set(entities.map(\.id))
            for (entityID, task) in avatarResolutionTasks where !visibleEntityIDs.contains(entityID) {
                task.cancel()
                finishAvatarResolutionTask(entityID: entityID, outcome: .canceled)
            }
            for entityID in Array(pendingAvatarResolutionRequests.keys) where !visibleEntityIDs.contains(entityID) {
                finishAvatarResolutionTask(entityID: entityID, outcome: .canceled)
            }
        }

        let candidates = entities.filter { entity in
            entity.avatarImageDataURL == nil &&
                (entity.primaryEmailAddress?.nilIfBlank != nil || !entity.emailAddresses.isEmpty)
        }
        guard !candidates.isEmpty else {
            updateAvatarResolutionActivity()
            return
        }

        let generation = requestGeneration
        let resolver = avatarResolver
        Task { [weak self] in
            var cachedAvatars: [Int64: String] = [:]
            var uncachedEntityIDs: Set<Int64> = []

            for entity in candidates {
                guard !Task.isCancelled else { return }
                switch await resolver.cachedAvatarStatus(
                    primaryEmailAddress: entity.primaryEmailAddress,
                    emailAddresses: entity.emailAddresses
                ) {
                case .dataURL(let dataURL):
                    cachedAvatars[entity.id] = dataURL
                case .missing:
                    continue
                case nil:
                    uncachedEntityIDs.insert(entity.id)
                }
            }

            await MainActor.run {
                guard let self,
                      self.requestGeneration == generation,
                      !Task.isCancelled
                else {
                    return
                }

                if !cachedAvatars.isEmpty {
                    self.entities = self.entities.map { entity in
                        guard entity.avatarImageDataURL == nil,
                              let dataURL = cachedAvatars[entity.id]
                        else {
                            return entity
                        }
                        var updated = entity
                        updated.avatarImageDataURL = dataURL
                        return updated
                    }
                }

                let uncachedEntities = self.entities.filter { entity in
                    uncachedEntityIDs.contains(entity.id)
                }
                self.enqueueAvatarResolutionTasksIfNeeded(
                    for: uncachedEntities,
                    source: source,
                    priority: requestedPriority
                )
            }
        }
    }

    private func enqueueAvatarResolutionTasksIfNeeded(
        for entities: [MailiaEntitySummary],
        source: String? = nil,
        priority requestedPriority: AvatarResolutionPriority? = nil
    ) {
        var currentBatchID: Int?
        for entity in entities {
            let isSelectedEntity = entity.id == selectedEntityID
            let priority = isSelectedEntity ? .selected : (requestedPriority ?? .background)
            let taskSource = isSelectedEntity ? "selected" : (source ?? "background")

            if isSelectedEntity, let existingTask = avatarResolutionTasks[entity.id] {
                let info = avatarResolutionTaskInfo[entity.id]
                if info?.source != "selected" {
                    existingTask.cancel()
                    finishAvatarResolutionTask(entityID: entity.id, outcome: .canceled)
                }
            }

            guard entity.avatarImageDataURL == nil,
                  avatarResolutionTasks[entity.id] == nil,
                  entity.primaryEmailAddress?.nilIfBlank != nil || !entity.emailAddresses.isEmpty
            else {
                continue
            }

            if var pending = pendingAvatarResolutionRequests[entity.id] {
                if priority < pending.priority {
                    pending.priority = priority
                    pending.source = taskSource
                    pending.entity = entity
                    pendingAvatarResolutionRequests[entity.id] = pending
                    if var info = avatarResolutionTaskInfo[entity.id] {
                        info = AvatarResolutionTaskInfo(
                            source: taskSource,
                            displayName: entity.displayName,
                            primaryEmailAddress: entity.primaryEmailAddress,
                            emailAddresses: entity.emailAddresses,
                            startedAt: info.startedAt,
                            batchID: info.batchID
                        )
                        avatarResolutionTaskInfo[entity.id] = info
                    }
                }
                continue
            }

            let batchID: Int
            if let currentBatchID {
                batchID = currentBatchID
            } else {
                batchID = startAvatarResolutionBatch(
                    source: taskSource
                )
                currentBatchID = batchID
            }
            enqueueAvatarResolutionTask(
                batchID: batchID,
                entity: entity,
                source: taskSource,
                priority: priority
            )
        }

        drainAvatarResolutionQueue()
    }

    private enum AvatarResolutionOutcome: String {
        case succeeded
        case failed
        case canceled
        case timedOut
    }

    private enum AvatarResolutionFetchResult: Sendable {
        case resolved(String)
        case failed
        case timedOut
    }

    private func startAvatarResolutionBatch(source: String) -> Int {
        nextAvatarResolutionBatchID += 1
        let id = nextAvatarResolutionBatchID
        avatarResolutionBatches[id] = AvatarResolutionProgressBatch(
            id: id,
            source: source,
            startedAt: Date(),
            total: 0,
            completed: 0,
            succeeded: 0,
            failed: 0,
            canceled: 0,
            timedOut: 0
        )
        updateAvatarResolutionActivity()
        return id
    }

    private func enqueueAvatarResolutionTask(
        batchID: Int,
        entity: MailiaEntitySummary,
        source: String,
        priority: AvatarResolutionPriority
    ) {
        guard var batch = avatarResolutionBatches[batchID] else { return }
        batch.total += 1
        avatarResolutionBatches[batchID] = batch
        nextAvatarResolutionSequence += 1
        pendingAvatarResolutionRequests[entity.id] = PendingAvatarResolutionRequest(
            entity: entity,
            source: source,
            priority: priority,
            batchID: batchID,
            sequence: nextAvatarResolutionSequence
        )
        avatarResolutionTaskInfo[entity.id] = AvatarResolutionTaskInfo(
            source: source,
            displayName: entity.displayName,
            primaryEmailAddress: entity.primaryEmailAddress,
            emailAddresses: entity.emailAddresses,
            startedAt: Date(),
            batchID: batchID
        )
        updateAvatarResolutionActivity()
    }

    private func drainAvatarResolutionQueue() {
        while avatarResolutionTasks.count < maxConcurrentAvatarResolutions,
              let next = nextPendingAvatarResolution() {
            pendingAvatarResolutionRequests[next.entity.id] = nil
            startAvatarResolutionTask(next)
        }
        updateAvatarResolutionActivity()
    }

    private func nextPendingAvatarResolution() -> PendingAvatarResolutionRequest? {
        pendingAvatarResolutionRequests.values.min { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            return lhs.sequence < rhs.sequence
        }
    }

    private func startAvatarResolutionTask(_ request: PendingAvatarResolutionRequest) {
        let entity = request.entity
        let forceRefresh = false
        avatarResolutionTasks[entity.id] = Task { [weak self] in
            guard let self else { return }
            let result = await self.avatarDataURLWithTimeout(
                primaryEmailAddress: entity.primaryEmailAddress,
                emailAddresses: entity.emailAddresses,
                forceRefresh: forceRefresh,
                lateResult: { [weak self] dataURL in
                    guard let self, let dataURL else { return }
                    self.applyAvatarDataURL(dataURL, for: entity)
                }
            )
            guard !Task.isCancelled else { return }

            await MainActor.run {
                let outcome: AvatarResolutionOutcome
                let dataURL: String?
                switch result {
                case .resolved(let resolvedDataURL):
                    outcome = .succeeded
                    dataURL = resolvedDataURL
                case .failed:
                    outcome = .failed
                    dataURL = nil
                case .timedOut:
                    outcome = .timedOut
                    dataURL = nil
                }

                self.finishAvatarResolutionTask(
                    entityID: entity.id,
                    outcome: outcome
                )
                guard let dataURL,
                      self.applyAvatarDataURL(dataURL, for: entity)
                else {
                    self.drainAvatarResolutionQueue()
                    return
                }
                self.drainAvatarResolutionQueue()
            }
        }
        updateAvatarResolutionActivity()
    }

    @discardableResult
    private func applyAvatarDataURL(
        _ dataURL: String,
        for entity: MailiaEntitySummary
    ) -> Bool {
        guard let index = entities.firstIndex(where: {
            $0.id == entity.id && $0.avatarImageDataURL == nil
        }) else {
            return false
        }

        var updatedEntities = entities
        updatedEntities[index].avatarImageDataURL = dataURL
        entities = updatedEntities
        if let primaryEmailAddress = entity.primaryEmailAddress {
            applyRecipientSuggestionAvatar(dataURL, forEmail: primaryEmailAddress)
        }
        return true
    }

    private func finishAvatarResolutionTask(
        entityID: Int64,
        outcome: AvatarResolutionOutcome
    ) {
        let info = avatarResolutionTaskInfo[entityID]
        avatarResolutionTasks[entityID] = nil
        pendingAvatarResolutionRequests[entityID] = nil
        avatarResolutionTaskInfo[entityID] = nil

        guard let info,
              var batch = avatarResolutionBatches[info.batchID]
        else {
            return
        }

        batch.completed += 1
        switch outcome {
        case .succeeded:
            batch.succeeded += 1
        case .failed:
            batch.failed += 1
        case .canceled:
            batch.canceled += 1
        case .timedOut:
            batch.timedOut += 1
        }
        avatarResolutionBatches[batch.id] = batch

        if batch.completed >= batch.total {
            avatarResolutionBatches[batch.id] = nil
        }
        updateAvatarResolutionActivity()
    }

    private func updateAvatarResolutionActivity() {
        let total = avatarResolutionBatches.values.reduce(0) { $0 + $1.total }
        guard total > 0 else {
            avatarResolutionActivity = nil
            return
        }

        let completed = avatarResolutionBatches.values.reduce(0) { $0 + $1.completed }

        avatarResolutionActivity = MailiaRefreshProgress(
            phase: .downloading,
            title: "Downloading avatars",
            detail: "\(completed) of \(total) avatars",
            fraction: Double(completed) / Double(total)
        )
    }

    private func resolveSelectedEntityAvatarIfNeeded() {
        guard let selectedEntityID,
              let entity = entities.first(where: { $0.id == selectedEntityID })
        else {
            return
        }
        resolveAvatarImagesIfNeeded(for: [entity], cancelTasksOutsideSet: false, source: "selected", priority: .selected)
    }

    func resolveAvatarForVisibleEntity(_ entityID: Int64) {
        guard let entity = entities.first(where: { $0.id == entityID }) else { return }
        resolveAvatarImagesIfNeeded(for: [entity], cancelTasksOutsideSet: false, source: "visible-row", priority: .visible)
    }

    private func avatarDataURLWithTimeout(
        primaryEmailAddress: String?,
        emailAddresses: [String],
        forceRefresh: Bool,
        lateResult: @escaping @MainActor (String?) -> Void
    ) async -> AvatarResolutionFetchResult {
        let resolver = avatarResolver
        let timeoutNanoseconds = avatarResolutionTimeoutNanoseconds
        return await withCheckedContinuation { continuation in
            var didResume = false
            _ = Task {
                let dataURL = await resolver.avatarDataURL(
                    primaryEmailAddress: primaryEmailAddress,
                    emailAddresses: emailAddresses,
                    debugLabel: nil,
                    forceRefresh: forceRefresh
                )
                await MainActor.run {
                    guard !didResume else {
                        lateResult(dataURL)
                        return
                    }
                    didResume = true
                    continuation.resume(returning: dataURL.map(AvatarResolutionFetchResult.resolved) ?? .failed)
                }
            }

            Task {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
                await MainActor.run {
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: .timedOut)
                }
            }
        }
    }

    private func resolveFocusedAvatarImagesIfNeeded() {
        var candidates: [MailiaEntitySummary] = []
        var seenEntityIDs: Set<Int64> = []

        if let selectedEntityID,
           let selectedEntity = entities.first(where: { $0.id == selectedEntityID }),
           seenEntityIDs.insert(selectedEntity.id).inserted {
            candidates.append(selectedEntity)
        }

        for entity in entities
            where seenEntityIDs.insert(entity.id).inserted {
            candidates.append(entity)
        }

        resolveAvatarImagesIfNeeded(for: candidates, source: "background", priority: .background)
    }

    private func applyTimelinePage(_ page: MailiaTimelinePage, direction: MailiaTimelinePageDirection, preserveAnchorID: Int64? = nil) {
        switch direction {
        case .latest:
            timeline = page.items
            timelineBodyStates = cachedBodyStates(for: page.items)
            hasOlderTimeline = page.hasMore
            hasNewerTimeline = false
        case .older:
            timeline = mergeTimeline(page.items + timeline)
            timelineBodyStates.merge(cachedBodyStates(for: timeline)) { current, _ in current }
            hasOlderTimeline = page.hasMore
            if let preserveAnchorID {
                publishTimelineScrollAnchor(id: preserveAnchorID, edge: .top)
            }
        case .newer:
            timeline = mergeTimeline(timeline + page.items)
            timelineBodyStates.merge(cachedBodyStates(for: timeline)) { current, _ in current }
            hasNewerTimeline = page.hasMore
            if let preserveAnchorID {
                publishTimelineScrollAnchor(id: preserveAnchorID, edge: .bottom)
            }
        }
        applyAccountVisualsToTimeline()
        prefetchSelectedTimelineBodies()
        if let selectedEntityID {
            cacheTimelinePage(
                workspace: workspace,
                entityID: selectedEntityID,
                items: timeline,
                hasOlderTimeline: hasOlderTimeline,
                hasNewerTimeline: hasNewerTimeline
            )
        }
        trimBodyStateWindow()
    }

    private func clearTimelinePageLoadingFlag(_ direction: MailiaTimelinePageDirection) {
        switch direction {
        case .latest:
            isLoadingTimeline = false
        case .older:
            isLoadingOlderTimeline = false
        case .newer:
            isLoadingNewerTimeline = false
        }
    }

    private func mergeTimeline(_ items: [MailiaTimelineItem]) -> [MailiaTimelineItem] {
        var seen: Set<Int64> = []
        return items.filter { item in
            seen.insert(item.id).inserted
        }
    }

    private func resetTimelineWindowState() {
        listFetchQueue.cancelAll()
        bodyLoadQueue.reset()
        hasOlderTimeline = false
        hasNewerTimeline = false
        isLoadingOlderTimeline = false
        isLoadingNewerTimeline = false
        timelineWindowStore.resetWindowState()
        timelineScrollAnchor = nil
    }

    private func cancelBodyLoadTasks() {
        bodyLoadQueue.cancelAll()
    }

    private func clearInMemoryBodyCache() {
        cancelBodyLoadTasks()
        timelineBodyStates = timelineWindowStore.clearBodyCache(timeline: timeline)
    }

    private func clearInMemoryAvatars() {
        avatarCacheHydrationTask?.cancel()
        for task in avatarResolutionTasks.values {
            task.cancel()
        }
        for task in accountAvatarResolutionTasks.values {
            task.cancel()
        }
        for task in suggestionAvatarResolutionTasks.values {
            task.cancel()
        }
        avatarResolutionTasks.removeAll()
        accountAvatarResolutionTasks.removeAll()
        suggestionAvatarResolutionTasks.removeAll()
        avatarResolutionTaskInfo.removeAll()
        avatarResolutionBatches.removeAll()
        pendingAvatarResolutionRequests.removeAll()
        entities = entities.map { entity in
            var updated = entity
            updated.avatarImageDataURL = nil
            return updated
        }
        sendAccounts = sendAccounts.map { account in
            accountWithAvatar(account, avatarImageDataURL: nil)
        }
        applyAccountVisualsToTimeline()
    }

    private func messageBodyCacheSummary() async throws -> MailiaCacheSummary {
        let stats = try await provider.messageBodyCacheStats()
        return MailiaCacheSummary(
            kind: .messageBodies,
            itemCount: stats.itemCount,
            byteSize: stats.byteSize
        )
    }

    private func publishTimelineScrollAnchor(id: Int64, edge: MailiaTimelineScrollAnchor.Edge) {
        timelineScrollAnchor = timelineWindowStore.publishScrollAnchor(id: id, edge: edge)
        if let timelineScrollAnchor {
            MailiaScrollDebugLog("[MailiaScrollDebug] publishTimelineScrollAnchor id=\(id) edge=\(edge) generation=\(timelineScrollAnchor.generation) timelineCount=\(timeline.count)")
        }
    }

    private func cachedBodyStates(for items: [MailiaTimelineItem]) -> [Int64: MailiaTimelineBodyState] {
        timelineWindowStore.cachedBodyStates(for: items, currentStates: timelineBodyStates)
    }

    private func cacheTimelinePage(
        workspace: MailiaWorkspace,
        entityID: Int64,
        items: [MailiaTimelineItem],
        hasOlderTimeline: Bool,
        hasNewerTimeline: Bool
    ) {
        timelineWindowStore.cachePage(
            workspace: workspace,
            entityID: entityID,
            items: items,
            hasOlderTimeline: hasOlderTimeline,
            hasNewerTimeline: hasNewerTimeline
        )
    }

    private func invalidateTimelineCache(entityID: Int64) {
        timelineWindowStore.invalidateTimelineCache(entityID: entityID)
    }

    private func trimBodyStateWindow() {
        let removedIDs = timelineWindowStore.trimBodyStateWindow(
            timeline: timeline,
            bodyStates: &timelineBodyStates
        )
        bodyLoadQueue.cancelLoads(ids: removedIDs)
        let visibleIDs = Set(timeline.map(\.id))
        for id in attachmentDownloadStates.keys where !visibleIDs.contains(id) {
            attachmentDownloadStates[id] = nil
        }
    }

    private static let statusFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

extension AppViewModel: BodyFetchQueueDelegate {
    var currentTimelineGeneration: Int {
        timelineGeneration
    }

    func timelineContainsItem(id: Int64) -> Bool {
        timeline.contains { $0.id == id }
    }

    func timelineItem(id: Int64) -> MailiaTimelineItem? {
        timeline.first { $0.id == id }
    }

    func bodyState(id: Int64) -> MailiaTimelineBodyState? {
        timelineBodyStates[id]
    }

    func setBodyState(_ state: MailiaTimelineBodyState?, id: Int64) {
        let previousState = timelineBodyStates[id]
        timelineBodyStates[id] = state
        if previousState != state {
            let status = state?.bodyDebugStatus ?? "nil"
            let previousStatus = previousState?.bodyDebugStatus ?? "nil"
            let loadedBody: MailiaTimelineBody?
            if case .loaded(let body) = state {
                loadedBody = body
            } else {
                loadedBody = nil
            }
            MailiaScrollDebugLog(
                "[MailiaBodyDebug] nativeBodyState messageID=\(id) previous=\(previousStatus) next=\(status) hasHTML=\(loadedBody?.html?.nilIfBlank != nil) hasHTMLVariants=\(loadedBody?.htmlVariants != nil) hasAttachments=\(loadedBody?.hasAttachments ?? false)"
            )
        }
        if case .loaded(let body) = state, body.hasAttachments {
            markTimelineItemHasAttachments(id: id)
        }
    }

    func cachedBodyState(id: Int64) -> MailiaTimelineBodyState? {
        timelineWindowStore.cachedBodyState(for: id)
    }

    func cacheBodyState(_ state: MailiaTimelineBodyState, id: Int64) {
        timelineWindowStore.cacheBodyState(state, for: id)
    }

    func rememberBodyAccess(id: Int64) {
        timelineWindowStore.rememberBodyAccess(id)
    }

    func bodyFetchQueueDidLoadBody(_ body: MailiaTimelineBody, for item: MailiaTimelineItem, priority: BodyFetchPriority) {
        if body.hasAttachments {
            markTimelineItemHasAttachments(id: item.id)
        }
        applyBodyPreviewIfNeeded(body, for: item)
    }

    func bodyFetchQueueDidUpdateBodyStates() {
        trimBodyStateWindow()
    }

    private func applyBodyPreviewIfNeeded(_ body: MailiaTimelineBody, for item: MailiaTimelineItem) {
        guard let html = body.html?.nilIfBlank,
              let preview = htmlTextExtractor.previewText(from: html)?.nilIfBlank else {
            return
        }

        var didUpdate = false
        entities = entities.map { entity in
            guard entity.latestMessageID == item.id,
                  entity.latestBodyPreview?.nilIfBlank != preview else {
                return entity
            }
            var updated = entity
            updated.latestBodyPreview = preview
            didUpdate = true
            return updated
        }

        if didUpdate {
            scheduleEntityPreviewBodyPrefetch()
        }
    }

    private func markTimelineItemHasAttachments(id: Int64) {
        guard let index = timeline.firstIndex(where: { $0.id == id }),
              !timeline[index].hasAttachments else {
            return
        }

        let item = timeline[index]
        timeline[index] = MailiaTimelineItem(
            id: item.id,
            entityID: item.entityID,
            direction: item.direction,
            subject: item.subject,
            preview: item.preview,
            html: item.html,
            htmlVariants: item.htmlVariants,
            date: item.date,
            accountLabel: item.accountLabel,
            accountEmoji: item.accountEmoji,
            accountAvatarImageDataURL: item.accountAvatarImageDataURL,
            folderLabel: item.folderLabel,
            envelopeID: item.envelopeID,
            isFlagged: item.isFlagged,
            fromLabel: item.fromLabel,
            toLabel: item.toLabel,
            hasAttachments: true
        )
    }
}

extension MailiaEntitySummary {
    func sidebarPreview(hideReplySubjects: Bool, hideQuotedReplyText: Bool) -> String {
        if hideReplySubjects,
           latestSubject.isReplySubject {
            if let replyPreview = latestBodyPreview?.nilIfBlank {
                let visiblePreview = hideQuotedReplyText
                    ? MessageTextNormalizer().removingTrailingQuotedReplyText(replyPreview)
                    : replyPreview
                if let compactPreview = visiblePreview.compactedPreviewText.nilIfBlank {
                    return compactPreview
                }
            }

            return ""
        }

        if !latestSubject.isEmpty {
            return latestSubject
        }

        return primaryEmailAddress ?? kind.rawValue
    }
}

private extension String {
    var isReplySubject: Bool {
        let trimmed = drop(while: \.isWhitespace)
        let prefixes = ["re", "回复", "答复", "回覆"]

        for prefix in prefixes {
            guard trimmed.count >= prefix.count,
                  trimmed.prefix(prefix.count).localizedCaseInsensitiveCompare(prefix) == .orderedSame
            else {
                continue
            }

            let remainder = trimmed.dropFirst(prefix.count).drop(while: \.isWhitespace)
            guard let first = remainder.first else { continue }
            if first == ":" || first == "：" {
                return true
            }
        }

        return false
    }

    var compactedPreviewText: String {
        var result = ""
        result.reserveCapacity(count)
        var isCollapsingWhitespace = false

        for character in self {
            if character.isWhitespace {
                if !result.isEmpty {
                    isCollapsingWhitespace = true
                }
            } else {
                if isCollapsingWhitespace {
                    result.append(" ")
                    isCollapsingWhitespace = false
                }
                result.append(character)
            }
        }

        return result
    }

    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
