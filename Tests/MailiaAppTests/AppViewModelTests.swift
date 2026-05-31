import Foundation
import MailiaCore
import Testing
@testable import MailiaApp

@MainActor
@Test
func loadRefreshesWhenInitialSnapshotHasNoEntities() async {
    let refreshedSnapshot = MailiaSnapshot(
        entities: [mailiaEntitySummary(id: 1, displayName: "Alice")],
        sendAccounts: [],
        loadedAt: Date()
    )
    let provider = FakeMailiaAppDataProvider(
        loadSnapshots: [MailiaSnapshot(entities: [], sendAccounts: [], loadedAt: Date())],
        refreshSnapshots: [refreshedSnapshot]
    )
    let viewModel = AppViewModel(provider: provider)

    await viewModel.load()

    #expect(provider.loadSnapshotCallCount == 1)
    #expect(provider.refreshCallCount == 1)
    #expect(viewModel.entities == refreshedSnapshot.entities)
}

@MainActor
@Test
func loadDoesNotRefreshWhenInitialSnapshotHasEntities() async {
    let localSnapshot = MailiaSnapshot(
        entities: [mailiaEntitySummary(id: 1, displayName: "Alice")],
        sendAccounts: [],
        loadedAt: Date()
    )
    let provider = FakeMailiaAppDataProvider(
        loadSnapshots: [localSnapshot],
        refreshSnapshots: []
    )
    let viewModel = AppViewModel(provider: provider)

    await viewModel.load()

    #expect(provider.loadSnapshotCallCount == 1)
    #expect(provider.refreshCallCount == 0)
    #expect(viewModel.entities == localSnapshot.entities)
}

@MainActor
@Test
func loadRefreshesWhenLastRefreshIsOlderThanStartupThreshold() async {
    let now = Date(timeIntervalSince1970: 1_800_100_000)
    let localSnapshot = MailiaSnapshot(
        entities: [mailiaEntitySummary(id: 1, displayName: "Alice")],
        sendAccounts: [],
        loadedAt: now
    )
    let refreshedSnapshot = MailiaSnapshot(
        entities: [mailiaEntitySummary(id: 2, displayName: "Bob")],
        sendAccounts: [],
        loadedAt: now
    )
    let provider = FakeMailiaAppDataProvider(
        loadSnapshots: [localSnapshot],
        refreshSnapshots: [refreshedSnapshot],
        lastRefreshFinishedAt: now.addingTimeInterval(-601)
    )
    let viewModel = AppViewModel(provider: provider, now: { now })

    await viewModel.load()

    #expect(provider.loadSnapshotCallCount == 1)
    #expect(provider.lastRefreshFinishedAtCallCount == 1)
    #expect(provider.refreshCallCount == 1)
    #expect(viewModel.entities == refreshedSnapshot.entities)
}

@MainActor
@Test
func loadPublishesStaleLocalSnapshotBeforeStartupRefreshCompletes() async {
    let now = Date(timeIntervalSince1970: 1_800_100_000)
    let localSnapshot = MailiaSnapshot(
        entities: [mailiaEntitySummary(id: 1, displayName: "Alice")],
        sendAccounts: [],
        loadedAt: now
    )
    let refreshedSnapshot = MailiaSnapshot(
        entities: [mailiaEntitySummary(id: 2, displayName: "Bob")],
        sendAccounts: [],
        loadedAt: now
    )
    let provider = FakeMailiaAppDataProvider(
        loadSnapshots: [localSnapshot],
        refreshSnapshots: [refreshedSnapshot],
        lastRefreshFinishedAt: now.addingTimeInterval(-601),
        refreshDelayNanoseconds: 100_000_000
    )
    let viewModel = AppViewModel(provider: provider, now: { now })

    let loadTask = Task {
        await viewModel.load()
    }
    await waitUntil {
        provider.refreshCallCount == 1
    }

    #expect(viewModel.entities == localSnapshot.entities)

    await loadTask.value

    #expect(viewModel.entities == refreshedSnapshot.entities)
}

@MainActor
@Test
func startupRefreshReloadsTimelineWhenStaleSelectionIsKept() async {
    let now = Date(timeIntervalSince1970: 1_800_100_000)
    let entity = mailiaEntitySummary(id: 1, displayName: "Alice")
    let localItem = mailiaTimelineItem(id: 10, entityID: entity.id)
    let refreshedItem = mailiaTimelineItem(id: 11, entityID: entity.id)
    let provider = FakeMailiaAppDataProvider(
        loadSnapshots: [
            MailiaSnapshot(entities: [entity], sendAccounts: [], loadedAt: now)
        ],
        refreshSnapshots: [
            MailiaSnapshot(entities: [entity], sendAccounts: [], loadedAt: now)
        ],
        timelinePages: [
            MailiaTimelinePage(items: [localItem], hasMore: false),
            MailiaTimelinePage(items: [refreshedItem], hasMore: false)
        ],
        lastRefreshFinishedAt: now.addingTimeInterval(-601),
        refreshDelayNanoseconds: 100_000_000
    )
    let viewModel = AppViewModel(provider: provider, now: { now })

    let loadTask = Task {
        await viewModel.load()
    }
    await waitUntil {
        viewModel.timeline == [localItem]
    }

    #expect(viewModel.timeline == [localItem])

    await loadTask.value
    await waitUntil {
        viewModel.timeline == [refreshedItem]
    }

    #expect(viewModel.timeline == [refreshedItem])
}

@MainActor
@Test
func loadDoesNotRefreshWhenLastRefreshIsWithinStartupThreshold() async {
    let now = Date(timeIntervalSince1970: 1_800_100_000)
    let localSnapshot = MailiaSnapshot(
        entities: [mailiaEntitySummary(id: 1, displayName: "Alice")],
        sendAccounts: [],
        loadedAt: now
    )
    let provider = FakeMailiaAppDataProvider(
        loadSnapshots: [localSnapshot],
        refreshSnapshots: [],
        lastRefreshFinishedAt: now.addingTimeInterval(-600)
    )
    let viewModel = AppViewModel(provider: provider, now: { now })

    await viewModel.load()

    #expect(provider.loadSnapshotCallCount == 1)
    #expect(provider.lastRefreshFinishedAtCallCount == 1)
    #expect(provider.refreshCallCount == 0)
    #expect(viewModel.entities == localSnapshot.entities)
}

@MainActor
@Test
func refreshFailureKeepsCurrentEntitiesAndReportsRefreshFailure() async {
    let localSnapshot = MailiaSnapshot(
        entities: [mailiaEntitySummary(id: 1, displayName: "Alice")],
        sendAccounts: [],
        loadedAt: Date()
    )
    let provider = FakeMailiaAppDataProvider(
        loadSnapshots: [localSnapshot, localSnapshot],
        refreshSnapshots: [],
        refreshError: FakeMailiaAppDataProviderError.refreshFailed
    )
    let viewModel = AppViewModel(provider: provider)

    await viewModel.load()
    await viewModel.refresh()

    #expect(provider.loadSnapshotCallCount == 2)
    #expect(provider.refreshCallCount == 1)
    #expect(viewModel.entities == localSnapshot.entities)
    #expect(viewModel.refreshStatus.contains("Unable to refresh mail"))
}

@MainActor
@Test
func newerTimelineRefreshDrivesGlobalRefreshState() async {
    let initialEntity = mailiaEntitySummary(id: 1, displayName: "Alice", accountKeys: ["gmail"])
    let initialSnapshot = MailiaSnapshot(
        entities: [initialEntity],
        sendAccounts: [],
        loadedAt: Date()
    )
    let refreshedSnapshot = MailiaSnapshot(
        entities: [initialEntity],
        sendAccounts: [],
        loadedAt: Date()
    )
    let provider = FakeMailiaAppDataProvider(
        loadSnapshots: [initialSnapshot],
        refreshSnapshots: [],
        refreshNewerTimelineSnapshots: [refreshedSnapshot],
        refreshAfterSendingDelayNanoseconds: 100_000_000
    )
    let viewModel = AppViewModel(provider: provider)

    await viewModel.load()
    viewModel.selectedEntityID = initialEntity.id
    await waitUntil {
        !viewModel.isLoadingTimeline
    }
    viewModel.refreshNewerTimelineForSelection()
    await waitUntil {
        provider.refreshNewerTimelineCallCount == 1
    }

    #expect(viewModel.isRefreshing)
    #expect(viewModel.isLoadingNewerTimeline)
    #expect(viewModel.refreshActivity?.title == "Checking for new messages")

    await waitUntil {
        !viewModel.isRefreshing && !viewModel.isLoadingNewerTimeline
    }

    #expect(provider.refreshNewerTimelineAccountKeys == [Set(["gmail"])])
    #expect(viewModel.refreshActivity == nil)
}

@MainActor
@Test
func timelineBodyLoadPublishesLoadedStateAndReusesCache() async {
    let entity = mailiaEntitySummary(id: 1, displayName: "Alice")
    let item = mailiaTimelineItem(id: 10, entityID: entity.id)
    let body = MailiaTimelineBody(html: "<p>Hello</p>", text: "Hello")
    let provider = FakeMailiaAppDataProvider(
        loadSnapshots: [
            MailiaSnapshot(entities: [entity], sendAccounts: [], loadedAt: Date())
        ],
        refreshSnapshots: [],
        timelinePages: [
            MailiaTimelinePage(items: [item], hasMore: false)
        ],
        bodyResults: [
            .success(body)
        ]
    )
    let viewModel = AppViewModel(provider: provider)

    await viewModel.load()
    await waitUntil {
        !viewModel.isLoadingTimeline && viewModel.timeline == [item]
    }
    viewModel.loadBodyIfNeeded(for: item)
    await waitUntil {
        viewModel.timelineBodyStates[item.id] == .loaded(body)
    }
    viewModel.loadBodyIfNeeded(for: item)

    #expect(provider.loadBodyCallCount == 1)
    #expect(viewModel.timelineBodyStates[item.id] == .loaded(body))
}

@MainActor
@Test
func sendNewMessageRunsDelayedFollowUpRefreshForRecipientAccountCopies() async {
    let initialSnapshot = MailiaSnapshot(
        entities: [mailiaEntitySummary(id: 1, displayName: "Reno")],
        sendAccounts: [
            mailiaSendAccount(id: "primary", emailAddress: "primary@example.com", isDefault: true),
            mailiaSendAccount(id: "work", emailAddress: "work@example.net")
        ],
        loadedAt: Date()
    )
    let followUpSnapshot = MailiaSnapshot(
        entities: [mailiaEntitySummary(id: 2, displayName: "primary@example.com")],
        sendAccounts: initialSnapshot.sendAccounts,
        loadedAt: Date()
    )
    let provider = FakeMailiaAppDataProvider(
        loadSnapshots: [initialSnapshot],
        refreshSnapshots: [],
        refreshAfterSendingSnapshots: [initialSnapshot, followUpSnapshot]
    )
    let viewModel = AppViewModel(
        provider: provider,
        postSendFollowUpRefreshDelaysNanoseconds: [1_000_000]
    )

    await viewModel.load()
    viewModel.sendNewMessage(
        to: ["work@example.net"],
        subject: "hi reno",
        body: "hi reno",
        accountKey: nil
    )
    await waitUntil {
        provider.refreshAfterSendingCallCount >= 2
    }

    #expect(provider.sendNewMessageCallCount == 1)
    #expect(provider.sentNewMessageAccountKey == "primary")
    #expect(provider.refreshAfterSendingCallCount == 2)
    #expect(provider.refreshAfterSendingAccountKeys.allSatisfy { $0 == ["primary", "work"] })
    #expect(viewModel.entities == followUpSnapshot.entities)
}

@MainActor
@Test
func loadSkipsAvatarProgressForCachedMissingAvatar() async throws {
    let cacheDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MailiaAppAvatarCacheTest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: cacheDirectory)
        AppViewModelAvatarMissingURLProtocol.state.reset()
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AppViewModelAvatarMissingURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let snapshot = MailiaSnapshot(
        entities: [
            mailiaEntitySummary(
                id: 1,
                displayName: "Missing Avatar",
                primaryEmailAddress: "missing-avatar@gmail.com"
            )
        ],
        sendAccounts: [],
        loadedAt: Date()
    )

    let firstResolver = EntityBrandAvatarResolver(diskCacheDirectory: cacheDirectory, session: session)
    let firstViewModel = AppViewModel(
        provider: FakeMailiaAppDataProvider(loadSnapshots: [snapshot], refreshSnapshots: []),
        avatarResolver: firstResolver
    )

    await firstViewModel.load()
    await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        AppViewModelAvatarMissingURLProtocol.state.requestCount >= 1
    }
    await waitUntil {
        firstViewModel.avatarResolutionActivity == nil
    }
    #expect(AppViewModelAvatarMissingURLProtocol.state.requestCount == 1)

    let secondResolver = EntityBrandAvatarResolver(diskCacheDirectory: cacheDirectory, session: session)
    let secondViewModel = AppViewModel(
        provider: FakeMailiaAppDataProvider(loadSnapshots: [snapshot], refreshSnapshots: []),
        avatarResolver: secondResolver
    )

    await secondViewModel.load()
    try? await Task.sleep(nanoseconds: 100_000_000)

    #expect(secondViewModel.avatarResolutionActivity == nil)
    #expect(AppViewModelAvatarMissingURLProtocol.state.requestCount == 1)
}

@MainActor
@Test
func replyTemplateWithoutQuotedOriginalRemovesHimalayaReplyQuote() {
    let template = """
    From: Ryan <ryan@example.com>
    To: Alice <alice@example.com>
    In-Reply-To: <original@example.com>
    Subject: Re: Hello

    hello back

    On 31/05/2026 16:36, Alice wrote:
    > Full-header test from Himalaya CLI via Gmail SMTP.
    """

    let cleaned = LiveMailiaAppDataProvider.replyTemplateWithoutQuotedOriginal(template)

    #expect(cleaned == """
    From: Ryan <ryan@example.com>
    To: Alice <alice@example.com>
    In-Reply-To: <original@example.com>
    Subject: Re: Hello

    hello back
    """)
}

@MainActor
@Test
func replyTemplateWithoutQuotedOriginalKeepsTemplatesWithoutHimalayaQuote() {
    let template = """
    From: Ryan <ryan@example.com>
    To: Alice <alice@example.com>
    Subject: Re: Hello

    On call today, I wrote:
    please check the draft
    """

    #expect(LiveMailiaAppDataProvider.replyTemplateWithoutQuotedOriginal(template) == template)
}

@MainActor
@Test
func sidebarPreviewUsesCleanedBodyForHiddenReplySubjects() {
    let entity = mailiaEntitySummary(
        id: 1,
        displayName: "Alice",
        latestSubject: "Re: Roadmap",
        latestBodyPreview: """
        I will handle this today.

        On May 30, Alice wrote:
        > Can you look at this?
        """
    )

    #expect(entity.sidebarPreview(hideReplySubjects: true, hideQuotedReplyText: true) == "I will handle this today.")
}

@MainActor
@Test
func sidebarPreviewKeepsTopicForNonReplySubjects() {
    let entity = mailiaEntitySummary(
        id: 1,
        displayName: "Alice",
        latestSubject: "Roadmap",
        latestBodyPreview: "Body preview"
    )

    #expect(entity.sidebarPreview(hideReplySubjects: true, hideQuotedReplyText: true) == "Roadmap")
}

private func mailiaEntitySummary(
    id: Int64,
    displayName: String,
    primaryEmailAddress: String? = nil,
    latestSubject: String = "(No subject)",
    latestBodyPreview: String? = nil,
    accountKeys: [String] = []
) -> MailiaEntitySummary {
    MailiaEntitySummary(
        id: id,
        displayName: displayName,
        primaryEmailAddress: primaryEmailAddress,
        emailAddresses: primaryEmailAddress.map { [$0] } ?? [],
        kind: .unknown,
        unreadCount: 0,
        latestSubject: latestSubject,
        latestBodyPreview: latestBodyPreview,
        latestDate: nil,
        accountKeys: accountKeys,
        accountLabel: "",
        workspace: .main,
        avatarImageDataURL: nil
    )
}

private func mailiaSendAccount(
    id: String,
    emailAddress: String,
    isDefault: Bool = false
) -> MailiaSendAccount {
    MailiaSendAccount(
        id: id,
        label: id,
        emailAddress: emailAddress,
        displayName: nil,
        isDefault: isDefault,
        emoji: nil,
        avatarImageDataURL: nil
    )
}

private func mailiaTimelineItem(id: Int64, entityID: Int64) -> MailiaTimelineItem {
    MailiaTimelineItem(
        id: id,
        entityID: entityID,
        direction: .incoming,
        subject: "Hello",
        preview: "Hello",
        html: nil,
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

@MainActor
private final class FakeMailiaAppDataProvider: MailiaAppDataProviding {
    private var loadSnapshots: [MailiaSnapshot]
    private var refreshSnapshots: [MailiaSnapshot]
    private var refreshAfterSendingSnapshots: [MailiaSnapshot]
    private var refreshNewerTimelineSnapshots: [MailiaSnapshot]
    private var timelinePages: [MailiaTimelinePage]
    private var bodyResults: [Result<MailiaTimelineBody, Error>]
    private var storedSendAccounts: [MailiaSendAccount] = []
    private let lastRefreshFinishedAt: Date?
    private let refreshDelayNanoseconds: UInt64
    private let refreshAfterSendingDelayNanoseconds: UInt64
    private let refreshError: Error?
    private(set) var loadSnapshotCallCount = 0
    private(set) var lastRefreshFinishedAtCallCount = 0
    private(set) var refreshCallCount = 0
    private(set) var refreshAfterSendingCallCount = 0
    private(set) var refreshNewerTimelineCallCount = 0
    private(set) var loadBodyCallCount = 0
    private(set) var refreshAfterSendingAccountKeys: [Set<String>] = []
    private(set) var refreshNewerTimelineAccountKeys: [Set<String>] = []
    private(set) var sendNewMessageCallCount = 0
    private(set) var sentNewMessageAccountKey: String?

    init(
        loadSnapshots: [MailiaSnapshot],
        refreshSnapshots: [MailiaSnapshot],
        refreshAfterSendingSnapshots: [MailiaSnapshot] = [],
        refreshNewerTimelineSnapshots: [MailiaSnapshot] = [],
        timelinePages: [MailiaTimelinePage] = [],
        bodyResults: [Result<MailiaTimelineBody, Error>] = [],
        lastRefreshFinishedAt: Date? = nil,
        refreshDelayNanoseconds: UInt64 = 0,
        refreshAfterSendingDelayNanoseconds: UInt64 = 0,
        refreshError: Error? = nil
    ) {
        self.loadSnapshots = loadSnapshots
        self.refreshSnapshots = refreshSnapshots
        self.refreshAfterSendingSnapshots = refreshAfterSendingSnapshots
        self.refreshNewerTimelineSnapshots = refreshNewerTimelineSnapshots
        self.timelinePages = timelinePages
        self.bodyResults = bodyResults
        self.storedSendAccounts = loadSnapshots.first?.sendAccounts ?? []
        self.lastRefreshFinishedAt = lastRefreshFinishedAt
        self.refreshDelayNanoseconds = refreshDelayNanoseconds
        self.refreshAfterSendingDelayNanoseconds = refreshAfterSendingDelayNanoseconds
        self.refreshError = refreshError
    }

    func loadSnapshot(workspace: MailiaWorkspace, searchQuery: String) async throws -> MailiaSnapshot {
        loadSnapshotCallCount += 1
        let snapshot = loadSnapshots.removeFirst()
        storedSendAccounts = snapshot.sendAccounts
        return snapshot
    }

    func lastRefreshFinishedAt() async throws -> Date? {
        lastRefreshFinishedAtCallCount += 1
        return lastRefreshFinishedAt
    }

    func refresh(
        workspace: MailiaWorkspace,
        searchQuery: String,
        options: MailiaRefreshOptions,
        progress: @escaping @MainActor (MailiaRefreshProgress) -> Void
    ) async throws -> MailiaSnapshot {
        refreshCallCount += 1
        if let refreshError {
            throw refreshError
        }
        progress(MailiaRefreshProgress(
            phase: .downloading,
            title: "Downloading messages",
            detail: nil,
            fraction: 1
        ))
        if refreshDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: refreshDelayNanoseconds)
        }
        let snapshot = refreshSnapshots.removeFirst()
        storedSendAccounts = snapshot.sendAccounts
        return snapshot
    }

    func recipientSuggestions() async throws -> [MailiaRecipientSuggestion] {
        []
    }

    func refreshAfterSendingMessage(
        accountKeys: Set<String>,
        workspace: MailiaWorkspace,
        searchQuery: String
    ) async throws -> MailiaSnapshot {
        refreshAfterSendingCallCount += 1
        refreshAfterSendingAccountKeys.append(accountKeys)
        if refreshAfterSendingDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: refreshAfterSendingDelayNanoseconds)
        }
        let snapshot = refreshAfterSendingSnapshots.removeFirst()
        storedSendAccounts = snapshot.sendAccounts
        return snapshot
    }

    func refreshNewerTimelineMessages(
        accountKeys: Set<String>,
        workspace: MailiaWorkspace,
        searchQuery: String
    ) async throws -> MailiaSnapshot {
        refreshNewerTimelineCallCount += 1
        refreshNewerTimelineAccountKeys.append(accountKeys)
        if refreshAfterSendingDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: refreshAfterSendingDelayNanoseconds)
        }
        let snapshot = refreshNewerTimelineSnapshots.removeFirst()
        storedSendAccounts = snapshot.sendAccounts
        return snapshot
    }

    func syncEntityHistory(
        emailAddresses: Set<String>,
        workspace: MailiaWorkspace,
        searchQuery: String,
        progress: @escaping @MainActor (MailiaRefreshProgress) -> Void
    ) async throws -> MailiaSnapshot {
        fatalError("syncEntityHistory is not used in these tests")
    }

    func loadTimelinePage(
        entityID: Int64,
        workspace: MailiaWorkspace,
        direction: MailiaTimelinePageDirection,
        anchorID: Int64?,
        limit: Int
    ) async throws -> MailiaTimelinePage {
        guard !timelinePages.isEmpty else {
            return MailiaTimelinePage(items: [], hasMore: false)
        }
        return timelinePages.removeFirst()
    }

    func loadBody(for item: MailiaTimelineItem) async throws -> MailiaTimelineBody {
        loadBodyCallCount += 1
        return try bodyResults.removeFirst().get()
    }

    func performEntityAction(
        _ action: MailiaEntityAction,
        entityID: Int64,
        workspace: MailiaWorkspace,
        progress: @escaping @MainActor (String) -> Void
    ) async throws {
        fatalError("performEntityAction is not used in these tests")
    }

    func markEntityRead(entityID: Int64, workspace: MailiaWorkspace) async throws {
        fatalError("markEntityRead is not used in these tests")
    }

    func setMessageFlag(item: MailiaTimelineItem, isFlagged: Bool) async throws {
        fatalError("setMessageFlag is not used in these tests")
    }

    func downloadAttachments(for item: MailiaTimelineItem) async throws -> MailiaAttachmentDownloadResult {
        fatalError("downloadAttachments is not used in these tests")
    }

    func sendReply(to item: MailiaTimelineItem, body: String, replyAll: Bool, accountKey: String?) async throws {
        fatalError("sendReply is not used in these tests")
    }

    func sendNewMessage(
        to recipients: [String],
        subject: String?,
        body: String,
        accountKey: String?
    ) async throws {
        sendNewMessageCallCount += 1
        sentNewMessageAccountKey = accountKey
    }

    func loadSendAccounts() async throws -> [MailiaSendAccount] {
        storedSendAccounts
    }

    func updateAccountSettings(_ updates: [MailiaAccountSettingsUpdate]) async throws {}

    func messageBodyCacheStats() async throws -> CacheStats {
        CacheStats(itemCount: 0, byteSize: 0)
    }

    func clearMessageBodyCache() async throws {}
}

private enum FakeMailiaAppDataProviderError: LocalizedError {
    case refreshFailed

    var errorDescription: String? {
        "refresh failed"
    }
}

private final class AppViewModelAvatarMissingURLProtocol: URLProtocol {
    static let state = AppViewModelAvatarMissingURLProtocolState()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.state.recordRequest()
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: 404,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class AppViewModelAvatarMissingURLProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0

    var requestCount: Int {
        lock.withLock { requests }
    }

    func recordRequest() {
        lock.withLock {
            requests += 1
        }
    }

    func reset() {
        lock.withLock {
            requests = 0
        }
    }
}
