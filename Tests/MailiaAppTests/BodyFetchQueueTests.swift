import Foundation
import MailiaCore
import Testing
@testable import MailiaApp

@Test
func bodyFetchPriorityMapsWebPriorityBuckets() {
    #expect(BodyFetchPriority(webPriority: nil) == .visible)
    #expect(BodyFetchPriority(webPriority: 500) == .visible)
    #expect(BodyFetchPriority(webPriority: 499) == .nearby)
    #expect(BodyFetchPriority(webPriority: 400) == .nearby)
    #expect(BodyFetchPriority(webPriority: 399) == .selectedPage)
    #expect(BodyFetchPriority(webPriority: 300) == .selectedPage)
    #expect(BodyFetchPriority(webPriority: 299) == .entityPreview)
    #expect(BodyFetchPriority(webPriority: 200) == .entityPreview)
    #expect(BodyFetchPriority(webPriority: 199) == .background)
}

@MainActor
@Test
func bodyFetchQueueRestartsOrphanedLoadingState() async {
    let item = mailiaTimelineItem(id: 10, entityID: 1)
    let body = MailiaTimelineBody(html: "<p>Hello</p>")
    let provider = BodyFetchQueueProvider(body: body)
    let queue = BodyFetchQueue(provider: provider, maxConcurrentBodyLoads: 1)
    let delegate = BodyFetchQueueTestDelegate(
        items: [item],
        bodyStates: [item.id: .loading]
    )
    queue.delegate = delegate

    queue.loadIfNeeded(for: item, priority: .visible)

    await waitUntil {
        delegate.bodyState(id: item.id) == .loaded(body)
    }

    #expect(provider.loadBodyCallCount == 1)
    #expect(delegate.bodyStateTransitions[item.id] == [.notRequested, .loading, .loaded(body)])
}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 500_000_000,
    predicate: @escaping @MainActor () -> Bool
) async {
    let startedAt = DispatchTime.now().uptimeNanoseconds
    while !predicate(),
          DispatchTime.now().uptimeNanoseconds - startedAt < timeoutNanoseconds {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

private func mailiaTimelineItem(id: Int64, entityID: Int64) -> MailiaTimelineItem {
    MailiaTimelineItem(
        id: id,
        entityID: entityID,
        direction: .incoming,
        subject: "Hello",
        preview: "Hello",
        html: nil,
        htmlVariants: nil,
        date: nil,
        accountLabel: "gmail",
        accountEmoji: nil,
        accountAvatarImageDataURL: nil,
        folderLabel: "Inbox",
        envelopeID: "envelope-\(id)",
        isFlagged: false,
        fromLabel: "Alice <alice@example.com>",
        toLabel: "Ryan <ryan@example.com>",
        hasAttachments: false
    )
}

@MainActor
private final class BodyFetchQueueTestDelegate: BodyFetchQueueDelegate {
    var currentTimelineGeneration = 1
    var bodyStateTransitions: [Int64: [MailiaTimelineBodyState]] = [:]

    private var items: [Int64: MailiaTimelineItem]
    private var bodyStates: [Int64: MailiaTimelineBodyState]
    private var cachedStates: [Int64: MailiaTimelineBodyState] = [:]

    init(items: [MailiaTimelineItem], bodyStates: [Int64: MailiaTimelineBodyState]) {
        self.items = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        self.bodyStates = bodyStates
    }

    func timelineContainsItem(id: Int64) -> Bool {
        items[id] != nil
    }

    func timelineItem(id: Int64) -> MailiaTimelineItem? {
        items[id]
    }

    func bodyState(id: Int64) -> MailiaTimelineBodyState? {
        bodyStates[id]
    }

    func setBodyState(_ state: MailiaTimelineBodyState?, id: Int64) {
        bodyStates[id] = state
        if let state {
            bodyStateTransitions[id, default: []].append(state)
        }
    }

    func cachedBodyState(id: Int64) -> MailiaTimelineBodyState? {
        cachedStates[id]
    }

    func cacheBodyState(_ state: MailiaTimelineBodyState, id: Int64) {
        cachedStates[id] = state
    }

    func rememberBodyAccess(id: Int64) {}

    func bodyFetchQueueDidLoadBody(_ body: MailiaTimelineBody, for item: MailiaTimelineItem, priority: BodyFetchPriority) {}

    func bodyFetchQueueDidUpdateBodyStates() {}
}

@MainActor
private final class BodyFetchQueueProvider: MailiaAppDataProviding {
    private let body: MailiaTimelineBody
    private(set) var loadBodyCallCount = 0

    init(body: MailiaTimelineBody) {
        self.body = body
    }

    func loadBody(for item: MailiaTimelineItem) async throws -> MailiaTimelineBody {
        loadBodyCallCount += 1
        return body
    }

    func loadSnapshot(workspace: MailiaWorkspace, searchQuery: String) async throws -> MailiaSnapshot {
        fatalError("loadSnapshot is not used in this test")
    }

    func lastRefreshFinishedAt() async throws -> Date? {
        fatalError("lastRefreshFinishedAt is not used in this test")
    }

    func recipientSuggestions() async throws -> [MailiaRecipientSuggestion] {
        fatalError("recipientSuggestions is not used in this test")
    }

    func refresh(
        workspace: MailiaWorkspace,
        searchQuery: String,
        options: MailiaRefreshOptions,
        progress: @escaping @MainActor (MailiaRefreshProgress) -> Void
    ) async throws -> MailiaSnapshot {
        fatalError("refresh is not used in this test")
    }

    func refreshAfterSendingMessage(
        accountKeys: Set<String>,
        workspace: MailiaWorkspace,
        searchQuery: String
    ) async throws -> MailiaSnapshot {
        fatalError("refreshAfterSendingMessage is not used in this test")
    }

    func refreshNewerTimelineMessages(
        accountKeys: Set<String>,
        workspace: MailiaWorkspace,
        searchQuery: String
    ) async throws -> MailiaSnapshot {
        fatalError("refreshNewerTimelineMessages is not used in this test")
    }

    func syncEntityHistory(
        emailAddresses: Set<String>,
        workspace: MailiaWorkspace,
        searchQuery: String,
        progress: @escaping @MainActor (MailiaRefreshProgress) -> Void
    ) async throws -> MailiaSnapshot {
        fatalError("syncEntityHistory is not used in this test")
    }

    func loadTimelinePage(
        entityID: Int64,
        workspace: MailiaWorkspace,
        direction: MailiaTimelinePageDirection,
        anchorID: Int64?,
        limit: Int
    ) async throws -> MailiaTimelinePage {
        fatalError("loadTimelinePage is not used in this test")
    }

    func loadLatestTimelineItems(entityIDs: [Int64], workspace: MailiaWorkspace) async throws -> [MailiaTimelineItem] {
        fatalError("loadLatestTimelineItems is not used in this test")
    }

    func performEntityAction(
        _ action: MailiaEntityAction,
        entityID: Int64,
        workspace: MailiaWorkspace,
        progress: @escaping @MainActor (String) -> Void
    ) async throws {
        fatalError("performEntityAction is not used in this test")
    }

    func markEntityRead(entityID: Int64, workspace: MailiaWorkspace) async throws {
        fatalError("markEntityRead is not used in this test")
    }

    func setMessageFlag(item: MailiaTimelineItem, isFlagged: Bool) async throws {
        fatalError("setMessageFlag is not used in this test")
    }

    func downloadAttachments(for item: MailiaTimelineItem) async throws -> MailiaAttachmentDownloadResult {
        fatalError("downloadAttachments is not used in this test")
    }

    func sendReply(to item: MailiaTimelineItem, content: MailiaComposerContent, replyAll: Bool, accountKey: String?) async throws {
        fatalError("sendReply is not used in this test")
    }

    func sendNewMessage(to recipients: [String], subject: String?, content: MailiaComposerContent, accountKey: String?) async throws {
        fatalError("sendNewMessage is not used in this test")
    }

    func loadSendAccounts() async throws -> [MailiaSendAccount] {
        fatalError("loadSendAccounts is not used in this test")
    }

    func updateAccountSettings(_ updates: [MailiaAccountSettingsUpdate]) async throws {
        fatalError("updateAccountSettings is not used in this test")
    }

    func messageBodyCacheStats() async throws -> CacheStats {
        fatalError("messageBodyCacheStats is not used in this test")
    }

    func clearMessageBodyCache() async throws {
        fatalError("clearMessageBodyCache is not used in this test")
    }
}
