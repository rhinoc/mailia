import Foundation
import GRDB
import MailiaCore
import AppKit

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

enum MailiaEntityAction: Sendable {
    case moveToInbox
    case moveToJunk
    case moveToTrash
    case flagImportant
    case removeFlag

    var statusLabel: String {
        switch self {
        case .moveToInbox:
            "Moving to Inbox..."
        case .moveToJunk:
            "Moving to Junk..."
        case .moveToTrash:
            "Moving to Trash..."
        case .flagImportant:
            "Flagging..."
        case .removeFlag:
            "Removing flag..."
        }
    }

    func progressStatus(current: Int, total: Int) -> String {
        switch self {
        case .moveToInbox:
            "Moving \(current) of \(total) to Inbox..."
        case .moveToJunk:
            "Moving \(current) of \(total) to Junk..."
        case .moveToTrash:
            "Moving \(current) of \(total) to Trash..."
        case .flagImportant:
            "Flagging \(current) of \(total)..."
        case .removeFlag:
            "Removing flag \(current) of \(total)..."
        }
    }

    var sourceRoles: [FolderRole] {
        switch self {
        case .moveToInbox:
            [.junk]
        case .moveToJunk:
            [.normal]
        case .moveToTrash:
            [.normal, .sent, .junk]
        case .flagImportant, .removeFlag:
            [.normal, .sent, .junk]
        }
    }

    var targetRole: FolderRole? {
        switch self {
        case .moveToInbox:
            .normal
        case .moveToJunk:
            .junk
        case .moveToTrash:
            .trash
        case .flagImportant, .removeFlag:
            nil
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
    let latestDate: Date?
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
    let date: Date?
    let accountLabel: String
    let accountEmoji: String?
    let folderLabel: String
    let envelopeID: String
    let isFlagged: Bool
    let fromLabel: String
    let toLabel: String
    let hasAttachments: Bool
}

struct MailiaTimelineBody: Equatable, Sendable {
    let html: String?
    let text: String?
}

enum MailiaTimelineBodyState: Equatable, Sendable {
    case notRequested
    case loading
    case loaded(MailiaTimelineBody)
    case failed(String)
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
}

struct MailiaAccountSettingsUpdate: Equatable, Sendable {
    var accountKey: String
    var displayName: String?
    var emoji: String?
    var isDefault: Bool?
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
            emoji: account.emoji?.nilIfBlank
        )
    }

    var menuLabel: String {
        let base = emailAddress ?? label
        return Self.prefixed(base, emoji: emoji)
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

private struct MailiaTimelineCacheKey: Hashable {
    let workspace: MailiaWorkspace
    let entityID: Int64
}

private struct MailiaTimelineCacheEntry {
    let items: [MailiaTimelineItem]
    let hasOlderTimeline: Bool
    let hasNewerTimeline: Bool
}

private struct EntityActionPresentation {
    let hidesEntityInCurrentWorkspace: Bool
}

@MainActor
protocol MailiaAppDataProviding {
    func loadSnapshot(workspace: MailiaWorkspace, searchQuery: String) async throws -> MailiaSnapshot
    func recipientSuggestions() async throws -> [MailiaRecipientSuggestion]
    func refresh(
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

    private let provider: any MailiaAppDataProviding
    private var requestGeneration = 0
    private var timelineGeneration = 0
    private var pendingBodyLoads: [Int64: MailiaTimelineItem] = [:]
    private var pendingBodyLoadOrder: [Int64] = []
    private var pendingBodyLoadPriorities: [Int64: Int] = [:]
    private var inFlightBodyLoads: Set<Int64> = []
    private var inFlightBodyLoadPriorities: [Int64: Int] = [:]
    private var bodyLoadTokens: [Int64: Int] = [:]
    private var nextBodyLoadPriority = 0
    private var nextBodyLoadToken = 0
    private var bodyAccessOrder: [Int64] = []
    private var timelinePageCache: [MailiaTimelineCacheKey: MailiaTimelineCacheEntry] = [:]
    private var timelinePageCacheAccessOrder: [MailiaTimelineCacheKey] = []
    private var timelineBodyStateCache: [Int64: MailiaTimelineBodyState] = [:]
    private var timelineBodyStateCacheAccessOrder: [Int64] = []
    private var avatarResolutionTasks: [Int64: Task<Void, Never>] = [:]
    private var avatarResolutionTaskInfo: [Int64: AvatarResolutionTaskInfo] = [:]
    private var avatarResolutionBatches: [Int: AvatarResolutionProgressBatch] = [:]
    private var pendingAvatarResolutionRequests: [Int64: PendingAvatarResolutionRequest] = [:]
    private var nextAvatarResolutionBatchID = 0
    private var nextAvatarResolutionSequence = 0
    private var avatarCacheHydrationTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var timelineLoadTask: Task<Void, Never>?
    private var timelinePageTasks: [MailiaTimelinePageDirection: Task<Void, Never>] = [:]
    private var bodyLoadTasks: [Int64: Task<Void, Never>] = [:]
    private var optimisticHiddenEntityIDs: Set<Int64> = []
    private var optimisticReadEntityIDs: Set<Int64> = []
    private var pendingMarkReadTask: Task<Void, Never>?
    private var markReadTasks: [Int64: Task<Void, Never>] = [:]
    private var scrollAnchorGeneration = 0
    private let avatarResolver = EntityBrandAvatarResolver()
    private let timelinePageSize = 80
    private let maxConcurrentBodyLoads = 3
    private let maxLoadedBodyStates = 32
    private let maxCachedTimelinePages = 24
    private let maxCachedBodyStates = 240
    private let maxConcurrentAvatarResolutions = 4
    private let avatarResolutionTimeoutNanoseconds: UInt64 = 12_000_000_000

    init(provider: any MailiaAppDataProviding = LiveMailiaAppDataProvider()) {
        self.provider = provider
    }

    deinit {
        reloadTask?.cancel()
        timelineLoadTask?.cancel()
        for task in timelinePageTasks.values {
            task.cancel()
        }
        for task in bodyLoadTasks.values {
            task.cancel()
        }
        pendingMarkReadTask?.cancel()
        for task in markReadTasks.values {
            task.cancel()
        }
        for task in avatarResolutionTasks.values {
            task.cancel()
        }
        avatarCacheHydrationTask?.cancel()
        avatarResolutionTasks.removeAll()
        avatarResolutionTaskInfo.removeAll()
        avatarResolutionBatches.removeAll()
        pendingAvatarResolutionRequests.removeAll()
        for task in suggestionAvatarResolutionTasks.values {
            task.cancel()
        }
    }

    func load() async {
        await loadSnapshot(statusPrefix: "Loaded", refresh: false)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        await loadSnapshot(statusPrefix: "Refreshed", refresh: true)
    }

    func performEntityAction(_ action: MailiaEntityAction, entity: MailiaEntitySummary) {
        let presentation = presentation(for: action, workspace: entity.workspace)
        if presentation.hidesEntityInCurrentWorkspace {
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
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else { return }
        if case .sending = replySendState {
            return
        }

        replySendState = .sending
        refreshStatus = "Sending reply..."

        Task { [weak self] in
            guard let self else { return }
            do {
                try await provider.sendReply(
                    to: item,
                    body: trimmedBody,
                    replyAll: replyAll,
                    accountKey: accountKey?.nilIfBlank
                )
                replySendState = .sent
                refreshStatus = "Reply sent"
                invalidateTimelineCache(entityID: item.entityID)

                if selectedEntityID == item.entityID {
                    loadTimelineForSelection()
                }

                let snapshot = try await provider.loadSnapshot(workspace: workspace, searchQuery: searchQuery)
                applySnapshot(snapshot, reloadTimelineIfSelectionKept: false)
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
            sendAccounts = try await provider.loadSendAccounts()
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
            sendAccounts = try await provider.loadSendAccounts()
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
            sendAccounts = try await provider.loadSendAccounts()
            applyAccountEmojisToTimeline()
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
            sendAccounts = try await provider.loadSendAccounts()
        } catch {
            NSLog("Unable to update account alias: \(error.localizedDescription)")
        }
    }

    func saveAccountSettings(_ updates: [MailiaAccountSettingsUpdate]) async {
        do {
            try await provider.updateAccountSettings(updates)
            sendAccounts = try await provider.loadSendAccounts()
            applyAccountEmojisToTimeline()
        } catch {
            NSLog("Unable to update account settings: \(error.localizedDescription)")
        }
    }

    func sendNewMessage(to recipients: [String], subject: String?, body: String, accountKey: String?) {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedRecipients = recipients
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmedBody.isEmpty, !cleanedRecipients.isEmpty else { return }
        if case .sending = replySendState {
            return
        }

        replySendState = .sending
        refreshStatus = "Sending message..."

        Task { [weak self] in
            guard let self else { return }
            do {
                try await provider.sendNewMessage(
                    to: cleanedRecipients,
                    subject: subject?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                    body: trimmedBody,
                    accountKey: accountKey?.nilIfBlank ?? selectedSendAccountKey
                )
                replySendState = .sent
                refreshStatus = "Message sent"
                hasComposeDraft = false
                isComposingNewMessage = false

                let snapshot = try await provider.loadSnapshot(workspace: workspace, searchQuery: searchQuery)
                applySnapshot(snapshot, reloadTimelineIfSelectionKept: false)
            } catch {
                replySendState = .failed(error.localizedDescription)
                refreshStatus = "Unable to send message: \(error.localizedDescription)"
                NSLog("Unable to send message: \(error.localizedDescription)")
            }
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
        timelineLoadTask?.cancel()
        avatarCacheHydrationTask?.cancel()
        reloadTask = nil
        timelineLoadTask = nil
        isLoadingEntityList = true
        selectedEntityID = nil
        entities = []
        timeline = []
        timelineBodyStates = [:]
        attachmentDownloadStates = [:]
        isLoadingTimeline = false
        resetTimelineWindowState()
    }

    private func loadSnapshot(statusPrefix: String, refresh: Bool) async {
        requestGeneration += 1
        let generation = requestGeneration
        isRefreshing = true
        isLoadingEntityList = true
        refreshStatus = refresh ? "Refreshing..." : "Loading..."
        refreshActivity = MailiaRefreshProgress(
            phase: .discovering,
            title: refresh ? "Refreshing" : "Loading",
            detail: nil,
            fraction: nil
        )
        defer {
            if generation == requestGeneration {
                isRefreshing = false
                isLoadingEntityList = false
                refreshActivity = nil
            }
        }

        do {
            let snapshot: MailiaSnapshot
            if refresh {
                snapshot = try await provider.refresh(workspace: workspace, searchQuery: searchQuery) { [weak self] progress in
                    guard let self, generation == requestGeneration else { return }
                    refreshActivity = progress
                    refreshStatus = progress.detail.map { "\(progress.title) — \($0)" } ?? progress.title
                }
            } else {
                snapshot = try await provider.loadSnapshot(workspace: workspace, searchQuery: searchQuery)
            }

            guard generation == requestGeneration else { return }

            applySnapshot(snapshot, reloadTimelineIfSelectionKept: refresh)
            refreshStatus = "\(statusPrefix) \(Self.statusFormatter.string(from: snapshot.loadedAt))"
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration else { return }
            entities = []
            timeline = []
            timelineBodyStates = [:]
            refreshStatus = "Unable to load mail: \(error.localizedDescription)"
        }
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
        timelineLoadTask?.cancel()
        cancelTimelinePageTasks()
        cancelBodyLoadTasks()
        guard let selectedEntityID else {
            timeline = []
            timelineBodyStates = [:]
            resetTimelineWindowState()
            return
        }

        let cacheKey = MailiaTimelineCacheKey(workspace: workspaceSnapshot, entityID: selectedEntityID)
        resetTimelineWindowState()
        let hasCachedPage = timelinePageCache[cacheKey] != nil
        if let cached = timelinePageCache[cacheKey] {
            rememberTimelinePageCacheAccess(cacheKey)
            timeline = cached.items
            timelineBodyStates = cachedBodyStates(for: cached.items)
            hasOlderTimeline = cached.hasOlderTimeline
            hasNewerTimeline = cached.hasNewerTimeline
            bodyAccessOrder = cached.items.map(\.id).filter { timelineBodyStates[$0] != nil }
            if let latestID = cached.items.last?.id {
                publishTimelineScrollAnchor(id: latestID, edge: .bottom)
            }
        } else if !timeline.contains(where: { $0.entityID == selectedEntityID }) {
            timeline = []
            timelineBodyStates = [:]
        }
        isLoadingTimeline = !hasCachedPage

        timelineLoadTask = Task { [weak self] in
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
                    key: cacheKey,
                    items: page.items,
                    hasOlderTimeline: page.hasMore,
                    hasNewerTimeline: false
                )
                timeline = page.items
                timelineBodyStates = cachedBodyStates(for: page.items)
                hasOlderTimeline = page.hasMore
                hasNewerTimeline = false
                if let latestID = page.items.last?.id {
                    publishTimelineScrollAnchor(id: latestID, edge: .bottom)
                }
                isLoadingTimeline = false
                timelineLoadTask = nil
            } catch is CancellationError {
                if generation == timelineGeneration {
                    timelineLoadTask = nil
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
                timelineLoadTask = nil
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

    func loadBodyIfNeeded(for item: MailiaTimelineItem, priority requestedPriority: Int? = nil) {
        guard timeline.contains(where: { $0.id == item.id }) else { return }
        rememberBodyAccess(item.id)
        if let cachedState = timelineBodyStateCache[item.id] {
            rememberTimelineBodyStateCacheAccess(item.id)
            timelineBodyStates[item.id] = cachedState
            return
        }
        switch timelineBodyStates[item.id] ?? .notRequested {
        case .notRequested:
            break
        case .loading:
            reprioritizeBodyLoadIfNeeded(for: item, requestedPriority: requestedPriority)
            return
        case .loaded, .failed:
            return
        }

        if pendingBodyLoads[item.id] != nil || inFlightBodyLoads.contains(item.id) {
            reprioritizeBodyLoadIfNeeded(for: item, requestedPriority: requestedPriority)
            return
        }

        enqueueBodyLoad(item, requestedPriority: requestedPriority)
        startPendingBodyLoads()
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

        timelinePageTasks[direction]?.cancel()
        timelinePageTasks[direction] = Task { [weak self] in
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
                    timelinePageTasks[direction] = nil
                }
                return
            } catch {
                guard generation == timelineGeneration else { return }
                NSLog("Unable to load timeline page: \(error.localizedDescription)")
            }
            clearTimelinePageLoadingFlag(direction)
            if generation == timelineGeneration {
                timelinePageTasks[direction] = nil
            }
        }
    }

    private func presentation(for action: MailiaEntityAction, workspace: MailiaWorkspace) -> EntityActionPresentation {
        let hidesEntity: Bool
        switch action {
        case .moveToInbox, .moveToJunk, .moveToTrash:
            hidesEntity = true
        case .flagImportant:
            hidesEntity = false
        case .removeFlag:
            hidesEntity = workspace == .flagged
        }
        return EntityActionPresentation(hidesEntityInCurrentWorkspace: hidesEntity)
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

    private func applyAccountEmojisToTimeline() {
        let emojiByAccount: [String: String] = Dictionary(
            uniqueKeysWithValues: sendAccounts.compactMap { account -> (String, String)? in
                guard let emoji = account.emoji?.nilIfBlank else { return nil }
                return (account.id, emoji)
            }
        )
        guard !emojiByAccount.isEmpty || timeline.contains(where: { $0.accountEmoji != nil }) else { return }

        timeline = timeline.map { item in
            MailiaTimelineItem(
                id: item.id,
                entityID: item.entityID,
                direction: item.direction,
                subject: item.subject,
                preview: item.preview,
                html: item.html,
                date: item.date,
                accountLabel: item.accountLabel,
                accountEmoji: emojiByAccount[item.accountLabel],
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
        sendAccounts = snapshot.sendAccounts
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
        hydrateCachedAvatarImagesThenResolve()
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

        var currentBatchID: Int?
        for entity in entities {
            let isSelectedEntity = entity.id == selectedEntityID
            let priority = isSelectedEntity ? .selected : (requestedPriority ?? .background)
            let taskSource = isSelectedEntity ? "selected" : (source ?? "background")

            if isSelectedEntity, let existingTask = avatarResolutionTasks[entity.id] {
                let info = avatarResolutionTaskInfo[entity.id]
                let age = info.map { String(format: "%.2fs", Date().timeIntervalSince($0.startedAt)) } ?? "unknown"
                logAvatar(
                    "[MailiaAvatar] entity=\(entity.id) name=\(entity.displayName) selected blocked by existing task source=\(info?.source ?? "unknown") age=\(age) primary=\(info?.primaryEmailAddress ?? "nil") emails=\(info?.emailAddresses ?? [])"
                )
                if info?.source != "selected" {
                    existingTask.cancel()
                    finishAvatarResolutionTask(entityID: entity.id, outcome: .canceled)
                    logAvatar("[MailiaAvatar] entity=\(entity.id) name=\(entity.displayName) cancel existing lower-priority avatar task")
                }
            }

            guard entity.avatarImageDataURL == nil,
                  avatarResolutionTasks[entity.id] == nil,
                  entity.primaryEmailAddress?.nilIfBlank != nil || !entity.emailAddresses.isEmpty
            else {
                if isSelectedEntity {
                    logAvatar(
                        "[MailiaAvatar] entity=\(entity.id) name=\(entity.displayName) skip hasAvatar=\(entity.avatarImageDataURL != nil) inFlight=\(avatarResolutionTasks[entity.id] != nil) primary=\(entity.primaryEmailAddress ?? "nil") emails=\(entity.emailAddresses)"
                    )
                }
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

            let debugLabel = isSelectedEntity
                ? "entity=\(entity.id) name=\(entity.displayName)"
                : nil
            if let debugLabel {
                logAvatar(
                    "[MailiaAvatar] \(debugLabel) start primary=\(entity.primaryEmailAddress ?? "nil") emails=\(entity.emailAddresses)"
                )
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
        let debugLabel = request.priority == .selected
            ? "entity=\(entity.id) name=\(entity.displayName)"
            : nil
        let forceRefresh = request.priority == .selected
        avatarResolutionTasks[entity.id] = Task { [weak self] in
            guard let self else { return }
            let result = await self.avatarDataURLWithTimeout(
                entityID: entity.id,
                primaryEmailAddress: entity.primaryEmailAddress,
                emailAddresses: entity.emailAddresses,
                debugLabel: debugLabel,
                forceRefresh: forceRefresh,
                lateResult: { [weak self] dataURL in
                    guard let self, let dataURL else { return }
                    self.applyAvatarDataURL(dataURL, for: entity, debugLabel: debugLabel)
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
                      self.applyAvatarDataURL(dataURL, for: entity, debugLabel: debugLabel)
                else {
                    if let debugLabel, outcome != .timedOut {
                        self.logAvatar("[MailiaAvatar] \(debugLabel) finished without UI update dataURL=\(dataURL != nil)")
                    }
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
        for entity: MailiaEntitySummary,
        debugLabel: String?
    ) -> Bool {
        guard let index = entities.firstIndex(where: {
            $0.id == entity.id && $0.avatarImageDataURL == nil
        }) else {
            return false
        }

        var updatedEntities = entities
        updatedEntities[index].avatarImageDataURL = dataURL
        entities = updatedEntities
        if let debugLabel {
            logAvatar("[MailiaAvatar] \(debugLabel) applied length=\(dataURL.count)")
        }
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
            let elapsed = String(format: "%.2fs", Date().timeIntervalSince(info.startedAt))
            logAvatar(
                "[MailiaAvatar] failed entity=\(entityID) name=\(info.displayName) source=\(info.source) age=\(elapsed) primary=\(info.primaryEmailAddress ?? "nil") emails=\(info.emailAddresses)"
            )
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

    private func logAvatar(_ message: String) {
        NSLog("%@", message)
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
        entityID: Int64,
        primaryEmailAddress: String?,
        emailAddresses: [String],
        debugLabel: String?,
        forceRefresh: Bool,
        lateResult: @escaping @MainActor (String?) -> Void
    ) async -> AvatarResolutionFetchResult {
        let resolver = avatarResolver
        let timeoutNanoseconds = avatarResolutionTimeoutNanoseconds
        return await withCheckedContinuation { continuation in
            var didResume = false
            let resolverTask = Task {
                let dataURL = await resolver.avatarDataURL(
                    primaryEmailAddress: primaryEmailAddress,
                    emailAddresses: emailAddresses,
                    debugLabel: debugLabel,
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
                    if let debugLabel {
                        NSLog("%@", "[MailiaAvatar] \(debugLabel) timeout entity=\(entityID) seconds=12")
                    } else {
                        NSLog("%@", "[MailiaAvatar] timeout entity=\(entityID) seconds=12")
                    }
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
        if let selectedEntityID {
            cacheTimelinePage(
                key: MailiaTimelineCacheKey(workspace: workspace, entityID: selectedEntityID),
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
        cancelTimelinePageTasks()
        cancelBodyLoadTasks()
        hasOlderTimeline = false
        hasNewerTimeline = false
        isLoadingOlderTimeline = false
        isLoadingNewerTimeline = false
        pendingBodyLoads = [:]
        pendingBodyLoadOrder = []
        pendingBodyLoadPriorities = [:]
        inFlightBodyLoads = []
        inFlightBodyLoadPriorities = [:]
        bodyLoadTokens = [:]
        bodyAccessOrder = []
        timelineScrollAnchor = nil
    }

    private func cancelTimelinePageTasks() {
        for task in timelinePageTasks.values {
            task.cancel()
        }
        timelinePageTasks.removeAll()
    }

    private func cancelBodyLoadTasks() {
        for task in bodyLoadTasks.values {
            task.cancel()
        }
        bodyLoadTasks.removeAll()
        inFlightBodyLoads.removeAll()
        inFlightBodyLoadPriorities.removeAll()
        bodyLoadTokens.removeAll()
    }

    private func publishTimelineScrollAnchor(id: Int64, edge: MailiaTimelineScrollAnchor.Edge) {
        scrollAnchorGeneration += 1
        timelineScrollAnchor = MailiaTimelineScrollAnchor(
            id: id,
            edge: edge,
            generation: scrollAnchorGeneration
        )
    }

    private func startPendingBodyLoads() {
        while inFlightBodyLoads.count < maxConcurrentBodyLoads {
            guard let nextID = nextPendingBodyLoadID(),
                  let item = pendingBodyLoads.removeValue(forKey: nextID) else {
                pendingBodyLoadOrder.removeAll()
                return
            }
            let priority = pendingBodyLoadPriorities.removeValue(forKey: nextID) ?? 0
            pendingBodyLoadOrder.removeAll { $0 == nextID }
            guard timeline.contains(where: { $0.id == item.id }) else {
                timelineBodyStates[item.id] = nil
                continue
            }
            startBodyLoad(for: item, priority: priority)
        }
    }

    private func enqueueBodyLoad(_ item: MailiaTimelineItem, requestedPriority: Int?) {
        let priority = nextBodyLoadPriorityValue(requestedPriority: requestedPriority)
        pendingBodyLoads[item.id] = item
        pendingBodyLoadPriorities[item.id] = priority
        pendingBodyLoadOrder.removeAll { $0 == item.id }
        pendingBodyLoadOrder.append(item.id)
        preemptOlderBodyLoadIfNeeded(forPriority: priority)
    }

    private func reprioritizePendingBodyLoad(for item: MailiaTimelineItem, requestedPriority: Int?) {
        let priority = nextBodyLoadPriorityValue(requestedPriority: requestedPriority)
        pendingBodyLoads[item.id] = item
        pendingBodyLoadPriorities[item.id] = priority
        pendingBodyLoadOrder.removeAll { $0 == item.id }
        pendingBodyLoadOrder.append(item.id)
        preemptOlderBodyLoadIfNeeded(forPriority: priority)
    }

    private func reprioritizeBodyLoadIfNeeded(for item: MailiaTimelineItem, requestedPriority: Int?) {
        if pendingBodyLoads[item.id] != nil {
            reprioritizePendingBodyLoad(for: item, requestedPriority: requestedPriority)
            startPendingBodyLoads()
        }
    }

    private func nextBodyLoadPriorityValue(requestedPriority: Int?) -> Int {
        if let requestedPriority {
            nextBodyLoadPriority = max(nextBodyLoadPriority, requestedPriority)
            return requestedPriority
        }
        nextBodyLoadPriority += 1
        return nextBodyLoadPriority
    }

    private func nextPendingBodyLoadID() -> Int64? {
        pendingBodyLoadOrder
            .filter { pendingBodyLoads[$0] != nil }
            .max {
                (pendingBodyLoadPriorities[$0] ?? 0) < (pendingBodyLoadPriorities[$1] ?? 0)
            }
    }

    private func preemptOlderBodyLoadIfNeeded(forPriority priority: Int) {
        guard inFlightBodyLoads.count >= maxConcurrentBodyLoads,
              let preemptedID = inFlightBodyLoads.min(by: {
                  (inFlightBodyLoadPriorities[$0] ?? 0) < (inFlightBodyLoadPriorities[$1] ?? 0)
              }),
              (inFlightBodyLoadPriorities[preemptedID] ?? 0) < priority
        else {
            return
        }

        bodyLoadTasks[preemptedID]?.cancel()
        bodyLoadTasks[preemptedID] = nil
        inFlightBodyLoads.remove(preemptedID)
        let preemptedPriority = inFlightBodyLoadPriorities[preemptedID] ?? 0
        inFlightBodyLoadPriorities[preemptedID] = nil
        bodyLoadTokens[preemptedID] = nil
        if let item = timeline.first(where: { $0.id == preemptedID }),
           pendingBodyLoads[preemptedID] == nil {
            pendingBodyLoads[preemptedID] = item
            pendingBodyLoadPriorities[preemptedID] = preemptedPriority
            pendingBodyLoadOrder.removeAll { $0 == preemptedID }
            pendingBodyLoadOrder.append(preemptedID)
        }
    }

    private func startBodyLoad(for item: MailiaTimelineItem, priority: Int) {
        let generation = timelineGeneration
        nextBodyLoadToken += 1
        let token = nextBodyLoadToken
        bodyLoadTokens[item.id] = token
        inFlightBodyLoads.insert(item.id)
        inFlightBodyLoadPriorities[item.id] = priority
        timelineBodyStates[item.id] = .loading

        bodyLoadTasks[item.id]?.cancel()
        bodyLoadTasks[item.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let body = try await provider.loadBody(for: item)
                if generation == timelineGeneration,
                   bodyLoadTokens[item.id] == token,
                   timeline.contains(where: { $0.id == item.id }) {
                    timelineBodyStateCache[item.id] = .loaded(body)
                    rememberTimelineBodyStateCacheAccess(item.id)
                    timelineBodyStates[item.id] = .loaded(body)
                    rememberBodyAccess(item.id)
                }
            } catch is CancellationError {
                if generation == timelineGeneration,
                   bodyLoadTokens[item.id] == token {
                    timelineBodyStates[item.id] = .notRequested
                }
            } catch {
                if generation == timelineGeneration,
                   bodyLoadTokens[item.id] == token,
                   timeline.contains(where: { $0.id == item.id }) {
                    timelineBodyStateCache[item.id] = .failed(error.localizedDescription)
                    rememberTimelineBodyStateCacheAccess(item.id)
                    timelineBodyStates[item.id] = .failed(error.localizedDescription)
                }
            }
            if generation == timelineGeneration,
               bodyLoadTokens[item.id] == token {
                inFlightBodyLoads.remove(item.id)
                inFlightBodyLoadPriorities[item.id] = nil
                bodyLoadTokens[item.id] = nil
                bodyLoadTasks[item.id] = nil
                trimBodyStateWindow()
                startPendingBodyLoads()
            }
        }
    }

    private func rememberBodyAccess(_ id: Int64) {
        bodyAccessOrder.removeAll { $0 == id }
        bodyAccessOrder.append(id)
    }

    private func cachedBodyStates(for items: [MailiaTimelineItem]) -> [Int64: MailiaTimelineBodyState] {
        var states: [Int64: MailiaTimelineBodyState] = [:]
        for item in items {
            if let current = timelineBodyStates[item.id], current != .notRequested {
                states[item.id] = current
            } else if let cached = timelineBodyStateCache[item.id] {
                states[item.id] = cached
                rememberTimelineBodyStateCacheAccess(item.id)
            }
        }
        return states
    }

    private func cacheTimelinePage(
        key: MailiaTimelineCacheKey,
        items: [MailiaTimelineItem],
        hasOlderTimeline: Bool,
        hasNewerTimeline: Bool
    ) {
        timelinePageCache[key] = MailiaTimelineCacheEntry(
            items: items,
            hasOlderTimeline: hasOlderTimeline,
            hasNewerTimeline: hasNewerTimeline
        )
        rememberTimelinePageCacheAccess(key)
        while timelinePageCacheAccessOrder.count > maxCachedTimelinePages,
              let oldestKey = timelinePageCacheAccessOrder.first {
            timelinePageCache[oldestKey] = nil
            timelinePageCacheAccessOrder.removeFirst()
        }
    }

    private func rememberTimelinePageCacheAccess(_ key: MailiaTimelineCacheKey) {
        timelinePageCacheAccessOrder.removeAll { $0 == key }
        timelinePageCacheAccessOrder.append(key)
    }

    private func invalidateTimelineCache(entityID: Int64) {
        for key in timelinePageCache.keys where key.entityID == entityID {
            timelinePageCache[key] = nil
        }
        timelinePageCacheAccessOrder.removeAll { $0.entityID == entityID }
    }

    private func rememberTimelineBodyStateCacheAccess(_ id: Int64) {
        timelineBodyStateCacheAccessOrder.removeAll { $0 == id }
        timelineBodyStateCacheAccessOrder.append(id)
        while timelineBodyStateCacheAccessOrder.count > maxCachedBodyStates,
              let oldestID = timelineBodyStateCacheAccessOrder.first {
            timelineBodyStateCache[oldestID] = nil
            timelineBodyStateCacheAccessOrder.removeFirst()
        }
    }

    private func trimBodyStateWindow() {
        let visibleIDs = Set(timeline.map(\.id))
        for id in timelineBodyStates.keys where !visibleIDs.contains(id) {
            timelineBodyStates[id] = nil
            pendingBodyLoads[id] = nil
            pendingBodyLoadPriorities[id] = nil
            bodyLoadTasks[id]?.cancel()
            bodyLoadTasks[id] = nil
            inFlightBodyLoads.remove(id)
            inFlightBodyLoadPriorities[id] = nil
            bodyLoadTokens[id] = nil
        }
        pendingBodyLoadOrder.removeAll { pendingBodyLoads[$0] == nil }
        bodyAccessOrder.removeAll { !visibleIDs.contains($0) }
        for id in attachmentDownloadStates.keys where !visibleIDs.contains(id) {
            attachmentDownloadStates[id] = nil
        }

        var loadedIDs = bodyAccessOrder.filter { id in
            if case .loaded = timelineBodyStates[id] {
                return true
            }
            return false
        }
        while loadedIDs.count > maxLoadedBodyStates, let id = loadedIDs.first {
            timelineBodyStates[id] = .notRequested
            bodyAccessOrder.removeAll { $0 == id }
            loadedIDs.removeFirst()
        }
    }

    private static let statusFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
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

    func refresh(
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
        _ = try await syncService.discoverFoldersForDiscoveredAccounts(timeout: 45)

        let aggregator = RefreshProgressAggregator()
        let report: @Sendable (SyncWorkspaceProgress) -> Void = { workspaceProgress in
            Task { @MainActor in
                progress(await aggregator.update(workspaceProgress))
            }
        }

        async let mainSync: Int = syncService.syncWorkspace(.main, timeout: 45, onProgress: report)
        async let junkSync: Int = syncService.syncWorkspace(.junk, timeout: 45, onProgress: report)
        _ = try await (mainSync, junkSync)

        progress(MailiaRefreshProgress(
            phase: .finishing,
            title: "Updating",
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
            sourceRoles: action.sourceRoles
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

        guard let targetRole = action.targetRole else { return }
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

        let bridge = bridge
        let commandLimiter = himalayaCommandLimiter
        await withTaskGroup(of: Void.self) { group in
            for location in locations {
                group.addTask {
                    do {
                        _ = try await commandLimiter.run(
                            .flagSeen(
                                id: location.himalayaEnvelopeID,
                                folder: location.sourceFolderName,
                                account: location.accountKey
                            ),
                            bridge: bridge,
                            timeout: 30,
                            priority: .backgroundSync
                        ).requireSuccess()
                    } catch {
                        NSLog("Unable to mark message read remotely: \(Self.errorDescription(error))")
                    }
                }
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

        let existingFiles = downloadedFileNames(in: downloadsDirectory)
        _ = try await runHimalaya(
            .attachmentDownload(
                messageID: envelopeID,
                folder: folderName,
                account: item.accountLabel,
                downloadsDirectory: downloadsDirectory
            ),
            timeout: 300,
            priority: .userDownload
        ).requireSuccess()

        let currentFiles = downloadedFileNames(in: downloadsDirectory)
        let newFiles = currentFiles.filter { !existingFiles.contains($0) }
        let newFileURLs = newFiles.map { downloadsDirectory.appendingPathComponent($0) }
        revealDownloadedFiles(newFileURLs, downloadsDirectory)
        return MailiaAttachmentDownloadResult(
            directoryPath: downloadsDirectory.path,
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

        let template = (try? templateResult.decodeJSON(as: String.self)) ?? templateResult.stdout
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

        let template = (try? templateResult.decodeJSON(as: String.self)) ?? templateResult.stdout
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
                    latestDate: item.latestDate,
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
