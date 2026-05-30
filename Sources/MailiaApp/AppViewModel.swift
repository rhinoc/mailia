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
    let kind: EntityKind
    let unreadCount: Int
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

enum MailiaAttachmentDownloadState: Equatable, Sendable {
    case idle
    case downloading
    case downloaded(MailiaAttachmentDownloadResult)
    case failed(String)
}

struct MailiaSnapshot: Equatable, Sendable {
    let entities: [MailiaEntitySummary]
    let loadedAt: Date
}

enum MailiaTimelinePageDirection: Sendable {
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
    func refresh(
        workspace: MailiaWorkspace,
        searchQuery: String,
        progress: @escaping @MainActor (String) -> Void
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
    func setMessageFlag(item: MailiaTimelineItem, isFlagged: Bool) async throws
    func downloadAttachments(for item: MailiaTimelineItem) async throws -> MailiaAttachmentDownloadResult
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var searchQuery: String = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            reloadForCurrentFilters()
        }
    }

    @Published var workspace: MailiaWorkspace = .main {
        didSet {
            guard workspace != oldValue else { return }
            reloadForCurrentFilters()
        }
    }

    @Published var selectedEntityID: Int64? {
        didSet {
            guard selectedEntityID != oldValue else { return }
            loadTimelineForSelection()
        }
    }

    @Published private(set) var entities: [MailiaEntitySummary] = []
    @Published private(set) var timeline: [MailiaTimelineItem] = []
    @Published private(set) var refreshStatus: String = "Ready"
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingTimeline = false
    @Published private(set) var isLoadingOlderTimeline = false
    @Published private(set) var isLoadingNewerTimeline = false
    @Published private(set) var hasOlderTimeline = false
    @Published private(set) var hasNewerTimeline = false
    @Published private(set) var timelineBodyStates: [Int64: MailiaTimelineBodyState] = [:]
    @Published private(set) var attachmentDownloadStates: [Int64: MailiaAttachmentDownloadState] = [:]
    @Published private(set) var timelineScrollAnchor: MailiaTimelineScrollAnchor?

    private let provider: any MailiaAppDataProviding
    private var requestGeneration = 0
    private var timelineGeneration = 0
    private var pendingBodyLoads: [Int64: MailiaTimelineItem] = [:]
    private var pendingBodyLoadOrder: [Int64] = []
    private var inFlightBodyLoads: Set<Int64> = []
    private var bodyAccessOrder: [Int64] = []
    private var timelinePageCache: [MailiaTimelineCacheKey: MailiaTimelineCacheEntry] = [:]
    private var timelinePageCacheAccessOrder: [MailiaTimelineCacheKey] = []
    private var timelineBodyStateCache: [Int64: MailiaTimelineBodyState] = [:]
    private var timelineBodyStateCacheAccessOrder: [Int64] = []
    private var avatarResolutionTasks: [Int64: Task<Void, Never>] = [:]
    private var optimisticHiddenEntityIDs: Set<Int64> = []
    private var scrollAnchorGeneration = 0
    private let avatarResolver = EntityBrandAvatarResolver()
    private let timelinePageSize = 80
    private let maxConcurrentBodyLoads = 3
    private let maxLoadedBodyStates = 32
    private let maxCachedTimelinePages = 24
    private let maxCachedBodyStates = 240

    init(provider: any MailiaAppDataProviding = LiveMailiaAppDataProvider()) {
        self.provider = provider
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

    private func reloadForCurrentFilters() {
        Task { [weak self] in
            await self?.loadSnapshot(statusPrefix: "Filtered", refresh: false)
        }
    }

    private func loadSnapshot(statusPrefix: String, refresh: Bool) async {
        requestGeneration += 1
        let generation = requestGeneration
        isRefreshing = true
        refreshStatus = refresh ? "Refreshing..." : "Loading..."
        defer {
            if generation == requestGeneration {
                isRefreshing = false
            }
        }

        do {
            let snapshot: MailiaSnapshot
            if refresh {
                snapshot = try await provider.refresh(workspace: workspace, searchQuery: searchQuery) { [weak self] status in
                    self?.refreshStatus = status
                }
            } else {
                snapshot = try await provider.loadSnapshot(workspace: workspace, searchQuery: searchQuery)
            }

            guard generation == requestGeneration else { return }

            applySnapshot(snapshot, reloadTimelineIfSelectionKept: refresh)
            refreshStatus = "\(statusPrefix) \(Self.statusFormatter.string(from: snapshot.loadedAt))"
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
        } else {
            timeline = []
            timelineBodyStates = [:]
        }
        isLoadingTimeline = !hasCachedPage

        Task { [weak self] in
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
            } catch {
                guard generation == timelineGeneration else { return }
                timeline = []
                timelineBodyStates = [:]
                resetTimelineWindowState()
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

    func loadBodyIfNeeded(for item: MailiaTimelineItem) {
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
        case .loading, .loaded, .failed:
            return
        }

        timelineBodyStates[item.id] = .loading
        if pendingBodyLoads[item.id] == nil {
            pendingBodyLoads[item.id] = item
            pendingBodyLoadOrder.append(item.id)
        }
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

        Task { [weak self] in
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
            } catch {
                guard generation == timelineGeneration else { return }
                NSLog("Unable to load timeline page: \(error.localizedDescription)")
            }
            clearTimelinePageLoadingFlag(direction)
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

    private func applySnapshot(_ snapshot: MailiaSnapshot, reloadTimelineIfSelectionKept: Bool) {
        let visibleEntities = snapshot.entities.filter { !optimisticHiddenEntityIDs.contains($0.id) }
        entities = mergeExistingAvatarImages(into: visibleEntities)
        resolveAvatarImagesIfNeeded(for: entities)
        if let currentSelection = selectedEntityID, visibleEntities.contains(where: { $0.id == currentSelection }) {
            if reloadTimelineIfSelectionKept {
                loadTimelineForSelection()
            }
        } else {
            selectedEntityID = visibleEntities.first?.id
        }
        if selectedEntityID == nil {
            timeline = []
            timelineBodyStates = [:]
            resetTimelineWindowState()
        }
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
                  let avatarImageDataURL = existing.avatarImageDataURL
            else {
                return entity
            }

            var merged = entity
            merged.avatarImageDataURL = avatarImageDataURL
            return merged
        }
    }

    private func resolveAvatarImagesIfNeeded(for entities: [MailiaEntitySummary]) {
        let visibleEntityIDs = Set(entities.map(\.id))
        for (entityID, task) in avatarResolutionTasks where !visibleEntityIDs.contains(entityID) {
            task.cancel()
            avatarResolutionTasks[entityID] = nil
        }

        for entity in entities {
            guard entity.avatarImageDataURL == nil,
                  avatarResolutionTasks[entity.id] == nil,
                  let primaryEmailAddress = entity.primaryEmailAddress?.nilIfBlank
            else {
                continue
            }

            avatarResolutionTasks[entity.id] = Task { [weak self] in
                guard let self else { return }
                let dataURL = await avatarResolver.avatarDataURL(forEmailAddress: primaryEmailAddress)
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    self.avatarResolutionTasks[entity.id] = nil
                    guard let dataURL,
                          let index = self.entities.firstIndex(where: {
                              $0.id == entity.id && $0.primaryEmailAddress == entity.primaryEmailAddress
                          })
                    else {
                        return
                    }

                    self.entities[index].avatarImageDataURL = dataURL
                }
            }
        }
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
        hasOlderTimeline = false
        hasNewerTimeline = false
        isLoadingOlderTimeline = false
        isLoadingNewerTimeline = false
        pendingBodyLoads = [:]
        pendingBodyLoadOrder = []
        inFlightBodyLoads = []
        bodyAccessOrder = []
        timelineScrollAnchor = nil
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
            guard let nextID = pendingBodyLoadOrder.first(where: { pendingBodyLoads[$0] != nil }),
                  let item = pendingBodyLoads.removeValue(forKey: nextID) else {
                pendingBodyLoadOrder.removeAll()
                return
            }
            pendingBodyLoadOrder.removeAll { $0 == nextID }
            guard timeline.contains(where: { $0.id == item.id }) else {
                timelineBodyStates[item.id] = nil
                continue
            }
            startBodyLoad(for: item)
        }
    }

    private func startBodyLoad(for item: MailiaTimelineItem) {
        let generation = timelineGeneration
        inFlightBodyLoads.insert(item.id)

        Task { [weak self] in
            guard let self else { return }
            do {
                let body = try await provider.loadBody(for: item)
                timelineBodyStateCache[item.id] = .loaded(body)
                rememberTimelineBodyStateCacheAccess(item.id)
                if generation == timelineGeneration,
                   timeline.contains(where: { $0.id == item.id }) {
                    timelineBodyStates[item.id] = .loaded(body)
                    rememberBodyAccess(item.id)
                }
            } catch {
                timelineBodyStateCache[item.id] = .failed(error.localizedDescription)
                rememberTimelineBodyStateCacheAccess(item.id)
                if generation == timelineGeneration,
                   timeline.contains(where: { $0.id == item.id }) {
                    timelineBodyStates[item.id] = .failed(error.localizedDescription)
                }
            }
            if generation == timelineGeneration {
                inFlightBodyLoads.remove(item.id)
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
            inFlightBodyLoads.remove(id)
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
        revealDownloadedFiles: @MainActor @escaping ([URL], URL) -> Void = Self.revealInFinder
    ) {
        let commandLimiter = himalayaCommandLimiter
            ?? HimalayaCommandLimiter(maxConcurrentCommands: policy.maxConcurrentHimalayaProcesses)
        self.databaseQueue = databaseQueue
        self.repository = MailRepository(databaseQueue: databaseQueue)
        self.bridge = bridge
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
        return MailiaSnapshot(
            entities: filterAndMap(entities, workspace: workspace, searchQuery: searchQuery),
            loadedAt: Date()
        )
    }

    func refresh(
        workspace: MailiaWorkspace,
        searchQuery: String,
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> MailiaSnapshot {
        progress("Discovering folders...")
        _ = try await syncService.discoverFoldersForDiscoveredAccounts(timeout: 45)
        progress("Syncing Main and Junk...")
        async let mainSync: Int = syncService.syncWorkspace(.main, timeout: 45)
        async let junkSync: Int = syncService.syncWorkspace(.junk, timeout: 45)
        _ = try await (mainSync, junkSync)
        progress("Reloading mail...")
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
        let items = pageMessages.map { message in
            makeTimelineItem(message: message, entityID: entityID)
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
            sanitizerVersion: 1
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
                            _ = try await commandLimiter.run(command, bridge: bridge, timeout: 30).requireSuccess()
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
        _ = try await runHimalaya(command, timeout: 30).requireSuccess()
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
            timeout: 300
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

    private func makeTimelineItem(message: TimelineMessage, entityID: Int64) -> MailiaTimelineItem {
        MailiaTimelineItem(
            id: message.messageID,
            entityID: entityID,
            direction: message.direction,
            subject: message.subject?.nilIfBlank ?? "(No subject)",
            preview: preview(for: message),
            html: displayHTML(message.sanitizedHTML),
            date: HimalayaDateParser.parse(message.messageDate),
            accountLabel: message.accountKey,
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
                timeout: 30
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
            timeout: 20
        ).requireSuccess()
        return (nil, messageTextNormalizer.normalize(try result.decodeJSON(as: String.self)))
    }

    private func displayHTML(_ html: String?) -> String? {
        guard let html = html?.nilIfBlank else {
            return nil
        }
        return htmlDisplayNormalizer.normalize(html).nilIfBlank
    }

    private func runHimalaya(_ command: HimalayaCommand, timeout: TimeInterval?) async throws -> HimalayaResult {
        try await himalayaCommandLimiter.run(command, bridge: bridge, timeout: timeout)
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
                    || (item.latestSubject?.localizedCaseInsensitiveContains(query) ?? false)
                    || item.accountKeys.joined(separator: " ").localizedCaseInsensitiveContains(query)
            }
            .map { item in
                MailiaEntitySummary(
                    id: item.id,
                    displayName: item.displayName,
                    primaryEmailAddress: item.primaryEmailAddress?.nilIfBlank,
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
