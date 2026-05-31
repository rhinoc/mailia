import Foundation

struct TimelineWindowSnapshot {
    let items: [MailiaTimelineItem]
    let hasOlderTimeline: Bool
    let hasNewerTimeline: Bool
}

struct TimelineWindowStore {
    private struct CacheKey: Hashable {
        let workspace: MailiaWorkspace
        let entityID: Int64
    }

    private var pageCache: [CacheKey: TimelineWindowSnapshot] = [:]
    private var pageCacheAccessOrder: [CacheKey] = []
    private var bodyStateCache: [Int64: MailiaTimelineBodyState] = [:]
    private var bodyStateCacheAccessOrder: [Int64] = []
    private var bodyAccessOrder: [Int64] = []
    private var scrollAnchorGeneration = 0

    private let maxCachedTimelinePages: Int
    private let maxCachedBodyStates: Int
    private let maxLoadedBodyStates: Int

    init(
        maxCachedTimelinePages: Int = 24,
        maxCachedBodyStates: Int = 240,
        maxLoadedBodyStates: Int = 32
    ) {
        self.maxCachedTimelinePages = maxCachedTimelinePages
        self.maxCachedBodyStates = maxCachedBodyStates
        self.maxLoadedBodyStates = maxLoadedBodyStates
    }

    mutating func resetWindowState() {
        bodyAccessOrder.removeAll()
    }

    mutating func clearBodyCache(timeline: [MailiaTimelineItem]) -> [Int64: MailiaTimelineBodyState] {
        bodyStateCache.removeAll()
        bodyStateCacheAccessOrder.removeAll()
        bodyAccessOrder.removeAll()
        return Dictionary(uniqueKeysWithValues: timeline.map { item in
            (item.id, MailiaTimelineBodyState.notRequested)
        })
    }

    mutating func cachedPage(workspace: MailiaWorkspace, entityID: Int64) -> TimelineWindowSnapshot? {
        let key = CacheKey(workspace: workspace, entityID: entityID)
        guard let cached = pageCache[key] else { return nil }
        rememberPageCacheAccess(key)
        return cached
    }

    mutating func hasCachedPage(workspace: MailiaWorkspace, entityID: Int64) -> Bool {
        pageCache[CacheKey(workspace: workspace, entityID: entityID)] != nil
    }

    mutating func cachePage(
        workspace: MailiaWorkspace,
        entityID: Int64,
        items: [MailiaTimelineItem],
        hasOlderTimeline: Bool,
        hasNewerTimeline: Bool
    ) {
        let key = CacheKey(workspace: workspace, entityID: entityID)
        pageCache[key] = TimelineWindowSnapshot(
            items: items,
            hasOlderTimeline: hasOlderTimeline,
            hasNewerTimeline: hasNewerTimeline
        )
        rememberPageCacheAccess(key)
        while pageCacheAccessOrder.count > maxCachedTimelinePages,
              let oldestKey = pageCacheAccessOrder.first {
            pageCache[oldestKey] = nil
            pageCacheAccessOrder.removeFirst()
        }
    }

    mutating func invalidateTimelineCache(entityID: Int64) {
        for key in pageCache.keys where key.entityID == entityID {
            pageCache[key] = nil
        }
        pageCacheAccessOrder.removeAll { $0.entityID == entityID }
    }

    mutating func publishScrollAnchor(id: Int64, edge: MailiaTimelineScrollAnchor.Edge) -> MailiaTimelineScrollAnchor {
        scrollAnchorGeneration += 1
        return MailiaTimelineScrollAnchor(
            id: id,
            edge: edge,
            generation: scrollAnchorGeneration
        )
    }

    mutating func rememberBodyAccess(_ id: Int64) {
        bodyAccessOrder.removeAll { $0 == id }
        bodyAccessOrder.append(id)
    }

    mutating func cachedBodyState(for id: Int64) -> MailiaTimelineBodyState? {
        guard let cached = bodyStateCache[id] else { return nil }
        rememberBodyStateCacheAccess(id)
        return cached
    }

    mutating func cacheBodyState(_ state: MailiaTimelineBodyState, for id: Int64) {
        bodyStateCache[id] = state
        rememberBodyStateCacheAccess(id)
    }

    mutating func cachedBodyStates(
        for items: [MailiaTimelineItem],
        currentStates: [Int64: MailiaTimelineBodyState]
    ) -> [Int64: MailiaTimelineBodyState] {
        var states: [Int64: MailiaTimelineBodyState] = [:]
        for item in items {
            if let current = currentStates[item.id], current != .notRequested {
                states[item.id] = current
            } else if let cached = bodyStateCache[item.id] {
                states[item.id] = cached
                rememberBodyStateCacheAccess(item.id)
            }
        }
        return states
    }

    mutating func primeBodyAccessOrder(items: [MailiaTimelineItem], bodyStates: [Int64: MailiaTimelineBodyState]) {
        bodyAccessOrder = items.map(\.id).filter { bodyStates[$0] != nil }
    }

    mutating func trimBodyStateWindow(
        timeline: [MailiaTimelineItem],
        bodyStates: inout [Int64: MailiaTimelineBodyState]
    ) -> [Int64] {
        let visibleIDs = Set(timeline.map(\.id))
        var removedIDs: [Int64] = []
        for id in bodyStates.keys where !visibleIDs.contains(id) {
            bodyStates[id] = nil
            removedIDs.append(id)
        }

        bodyAccessOrder.removeAll { !visibleIDs.contains($0) }

        var loadedIDs = bodyAccessOrder.filter { id in
            if case .loaded = bodyStates[id] {
                return true
            }
            return false
        }
        while loadedIDs.count > maxLoadedBodyStates, let id = loadedIDs.first {
            bodyStates[id] = .notRequested
            bodyAccessOrder.removeAll { $0 == id }
            loadedIDs.removeFirst()
        }

        return removedIDs
    }

    private mutating func rememberPageCacheAccess(_ key: CacheKey) {
        pageCacheAccessOrder.removeAll { $0 == key }
        pageCacheAccessOrder.append(key)
    }

    private mutating func rememberBodyStateCacheAccess(_ id: Int64) {
        bodyStateCacheAccessOrder.removeAll { $0 == id }
        bodyStateCacheAccessOrder.append(id)
        while bodyStateCacheAccessOrder.count > maxCachedBodyStates,
              let oldestID = bodyStateCacheAccessOrder.first {
            bodyStateCache[oldestID] = nil
            bodyStateCacheAccessOrder.removeFirst()
        }
    }
}
