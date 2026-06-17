import AppKit
import Foundation
import GRDB
import MailiaCore
import Testing
@testable import MailiaApp

@MainActor
@Test
func himalayaExecutableSettingsUsesUserOverrideWhenPresent() throws {
    let suiteName = "MailiaHimalayaExecutableSettingsTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    defaults.set("/tmp/custom-himalaya", forKey: MailiaPreferenceKeys.himalayaExecutablePath)

    let displayPath = MailiaHimalayaExecutableSettings.effectiveDisplayPath(defaults: defaults)

    #expect(displayPath == "/tmp/custom-himalaya")
}

@MainActor
@Test
func himalayaExecutableSettingsUsesConfiguredAppServerPath() {
    let launch = MailiaHimalayaExecutableSettings.appServerLaunch(
        environment: [
            "MAILIA_APP_SERVER_PATH": "/tmp/mailia-mail"
        ]
    )

    #expect(launch.executableURL.path == "/tmp/mailia-mail")
    #expect(launch.arguments == ["app-server", "--listen", "stdio://"])
}

@MainActor
@Test
func himalayaExecutableSettingsUsesBundledAppServer() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailia-bundled-app-server-\(UUID().uuidString)", isDirectory: true)
    let macOSDirectory = temporaryDirectory.appendingPathComponent("Mailia.app/Contents/MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOSDirectory, withIntermediateDirectories: true)
    let mailiaExecutable = macOSDirectory.appendingPathComponent("Mailia")
    let appServerExecutable = macOSDirectory.appendingPathComponent("mailia-mail")
    try Data().write(to: mailiaExecutable)
    try Data().write(to: appServerExecutable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appServerExecutable.path)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let launch = MailiaHimalayaExecutableSettings.appServerLaunch(
        environment: [:],
        executableURL: mailiaExecutable,
        bundleURL: temporaryDirectory.appendingPathComponent("Mailia.app"),
        fileManager: .default
    )

    #expect(launch.executableURL.path == appServerExecutable.path)
    #expect(launch.arguments == ["app-server", "--listen", "stdio://"])
}

@MainActor
@Test
func himalayaExecutableSettingsUsesBundleAppServerPathWhenExecutableIsMissing() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailia-missing-app-server-\(UUID().uuidString)", isDirectory: true)
    let macOSDirectory = temporaryDirectory.appendingPathComponent("Mailia.app/Contents/MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOSDirectory, withIntermediateDirectories: true)
    let mailiaExecutable = macOSDirectory.appendingPathComponent("Mailia")
    try Data().write(to: mailiaExecutable)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let launch = MailiaHimalayaExecutableSettings.appServerLaunch(
        environment: [:],
        executableURL: mailiaExecutable,
        bundleURL: temporaryDirectory.appendingPathComponent("Mailia.app"),
        fileManager: .default
    )

    #expect(launch.executableURL.path == temporaryDirectory.appendingPathComponent("Mailia.app/Contents/MacOS/mailia-mail").path)
    #expect(launch.arguments == ["app-server", "--listen", "stdio://"])
}

@MainActor
@Test
func himalayaExecutableSettingsUsesDevelopmentAppServerForSwiftPMBuild() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailia-development-app-server-\(UUID().uuidString)", isDirectory: true)
    let swiftExecutableDirectory = temporaryDirectory
        .appendingPathComponent(".build/arm64-apple-macosx/debug", isDirectory: true)
    let appServerDirectory = temporaryDirectory
        .appendingPathComponent("mailia-mail/target/debug", isDirectory: true)
    try FileManager.default.createDirectory(at: swiftExecutableDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: appServerDirectory, withIntermediateDirectories: true)
    let mailiaExecutable = swiftExecutableDirectory.appendingPathComponent("Mailia")
    let appServerExecutable = appServerDirectory.appendingPathComponent("mailia-mail")
    try Data().write(to: mailiaExecutable)
    try Data().write(to: appServerExecutable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appServerExecutable.path)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let launch = MailiaHimalayaExecutableSettings.appServerLaunch(
        environment: [:],
        executableURL: mailiaExecutable,
        bundleURL: temporaryDirectory.appendingPathComponent(".build/arm64-apple-macosx/debug"),
        fileManager: .default
    )

    #expect(launch.executableURL.path == appServerExecutable.path)
    #expect(launch.arguments == ["app-server", "--listen", "stdio://"])
}

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
func selectedEntityMarksWholeEntityReadOnSelection() async {
    let entity = mailiaEntitySummary(
        id: 1,
        displayName: "Alice",
        unreadCount: 10,
        latestMessageID: 101
    )
    let olderItem = mailiaTimelineItem(id: 100, entityID: entity.id)
    let latestItem = mailiaTimelineItem(id: 101, entityID: entity.id)
    let readEntity = mailiaEntitySummary(
        id: 1,
        displayName: "Alice",
        unreadCount: 0,
        latestMessageID: 101
    )
    let provider = FakeMailiaAppDataProvider(
        loadSnapshots: [
            MailiaSnapshot(entities: [entity], sendAccounts: [], loadedAt: Date()),
            MailiaSnapshot(entities: [readEntity], sendAccounts: [], loadedAt: Date())
        ],
        refreshSnapshots: [],
        timelinePages: [
            MailiaTimelinePage(items: [olderItem, latestItem], hasMore: false)
        ]
    )
    let viewModel = AppViewModel(provider: provider, renderedReadBatchDelayNanoseconds: 50_000_000)

    await viewModel.load()
    await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        viewModel.timeline.count == 2
    }
    await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        provider.markEntityReadEntityIDs == [entity.id] &&
            viewModel.entities.first?.unreadCount == 0
    }

    #expect(provider.markMessagesReadBatches.isEmpty)
    #expect(provider.markMessageReadItems.isEmpty)
}

@MainActor
@Test
func renderedMessagesDoNotDoubleMarkWhileEntityReadIsInFlight() async {
    let entity = mailiaEntitySummary(
        id: 1,
        displayName: "Alice",
        unreadCount: 10,
        latestMessageID: 101
    )
    let olderItem = mailiaTimelineItem(id: 100, entityID: entity.id)
    let latestItem = mailiaTimelineItem(id: 101, entityID: entity.id)
    let readEntity = mailiaEntitySummary(
        id: 1,
        displayName: "Alice",
        unreadCount: 0,
        latestMessageID: 101
    )
    let provider = FakeMailiaAppDataProvider(
        loadSnapshots: [
            MailiaSnapshot(entities: [entity], sendAccounts: [], loadedAt: Date()),
            MailiaSnapshot(entities: [readEntity], sendAccounts: [], loadedAt: Date())
        ],
        refreshSnapshots: [],
        timelinePages: [
            MailiaTimelinePage(items: [olderItem, latestItem], hasMore: false)
        ],
        markEntityReadDelayNanoseconds: 100_000_000
    )
    let viewModel = AppViewModel(provider: provider, renderedReadBatchDelayNanoseconds: 50_000_000)

    await viewModel.load()
    await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        viewModel.timeline.count == 2
    }
    await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        provider.markEntityReadEntityIDs == [entity.id]
    }
    viewModel.noteMessageBodyRendered(olderItem)
    viewModel.noteMessageBodyRendered(latestItem)

    try? await Task.sleep(nanoseconds: 250_000_000)

    #expect(provider.markMessagesReadBatches.isEmpty)
    #expect(provider.markMessageReadItems.isEmpty)
    #expect(provider.markEntityReadEntityIDs == [entity.id])
}

@MainActor
@Test
func selectedEntityClearsUnreadBeforeRemoteMarkReadFinishes() async {
    let entity = mailiaEntitySummary(
        id: 1,
        displayName: "Alice",
        unreadCount: 10,
        latestMessageID: 101
    )
    let readEntity = mailiaEntitySummary(
        id: 1,
        displayName: "Alice",
        unreadCount: 0,
        latestMessageID: 101
    )
    let provider = FakeMailiaAppDataProvider(
        loadSnapshots: [
            MailiaSnapshot(entities: [entity], sendAccounts: [], loadedAt: Date()),
            MailiaSnapshot(entities: [readEntity], sendAccounts: [], loadedAt: Date())
        ],
        refreshSnapshots: [],
        timelinePages: [
            MailiaTimelinePage(items: [mailiaTimelineItem(id: 101, entityID: entity.id)], hasMore: false)
        ],
        markEntityReadDelayNanoseconds: 1_000_000_000
    )
    let viewModel = AppViewModel(provider: provider, renderedReadBatchDelayNanoseconds: 50_000_000)

    await viewModel.load()
    await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        provider.markEntityReadEntityIDs == [entity.id]
    }

    #expect(viewModel.entities.first?.unreadCount == 0)
    #expect(provider.loadSnapshotCallCount == 1)
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
func refreshKeepsResolvedAvatarWhenEntityEmailAddressesChangeOrder() async {
    let avatarImageDataURL = "data:image/png;base64,avatar"
    let localEntity = mailiaEntitySummary(
        id: 1,
        displayName: "Google",
        primaryEmailAddress: "no-reply@google.com",
        emailAddresses: ["no-reply@google.com", "accounts.google.com@google.com"],
        avatarImageDataURL: avatarImageDataURL
    )
    let refreshedEntity = mailiaEntitySummary(
        id: 1,
        displayName: "Google",
        primaryEmailAddress: "accounts.google.com@google.com",
        emailAddresses: ["accounts.google.com@google.com", "no-reply@google.com"]
    )
    let provider = FakeMailiaAppDataProvider(
        loadSnapshots: [
            MailiaSnapshot(entities: [localEntity], sendAccounts: [], loadedAt: Date())
        ],
        refreshSnapshots: [
            MailiaSnapshot(entities: [refreshedEntity], sendAccounts: [], loadedAt: Date())
        ]
    )
    let viewModel = AppViewModel(provider: provider)

    await viewModel.load()
    await viewModel.refresh()

    #expect(viewModel.entities.first?.avatarImageDataURL == avatarImageDataURL)
}

@MainActor
@Test
func mailboxSyncFailureMessagePointsAtAppServer() {
    let message = MailiaSyncFailure.mailboxSyncFailed.localizedDescription

    #expect(message.contains("Mailia app-server"))
    #expect(!message.contains("Himalaya CLI"))
}

@MainActor
@Test
func startRefreshPublishesRefreshingStateImmediately() async {
    let refreshedSnapshot = MailiaSnapshot(
        entities: [mailiaEntitySummary(id: 1, displayName: "Alice")],
        sendAccounts: [],
        loadedAt: Date()
    )
    let provider = FakeMailiaAppDataProvider(
        loadSnapshots: [],
        refreshSnapshots: [refreshedSnapshot],
        refreshDelayNanoseconds: 100_000_000
    )
    let viewModel = AppViewModel(provider: provider)

    viewModel.startRefresh()

    #expect(viewModel.isRefreshing)
    #expect(viewModel.refreshStatus == "Refreshing...")
    #expect(viewModel.refreshActivity?.title == "Refreshing")

    await waitUntil {
        provider.refreshCallCount == 1
    }

    #expect(provider.refreshCallCount == 1)

    await waitUntil {
        !viewModel.isRefreshing
    }
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
    let body = MailiaTimelineBody(html: "<p>Hello</p>")
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
func refreshResetsCancelledTimelineBodyLoadState() async {
    let entity = mailiaEntitySummary(id: 1, displayName: "Alice")
    let item = mailiaTimelineItem(id: 10, entityID: entity.id)
    let snapshot = MailiaSnapshot(entities: [entity], sendAccounts: [], loadedAt: Date())
    let body = MailiaTimelineBody(html: "<p>Hello</p>")
    let provider = FakeMailiaAppDataProvider(
        loadSnapshots: [snapshot],
        refreshSnapshots: [snapshot],
        timelinePages: [
            MailiaTimelinePage(items: [item], hasMore: false),
            MailiaTimelinePage(items: [item], hasMore: false)
        ],
        bodyResults: [
            .success(body)
        ],
        bodyDelayNanoseconds: 500_000_000
    )
    let viewModel = AppViewModel(provider: provider)

    await viewModel.load()
    await waitUntil {
        !viewModel.isLoadingTimeline && viewModel.timeline == [item]
    }
    viewModel.loadBodyIfNeeded(for: item)
    await waitUntil {
        viewModel.timelineBodyStates[item.id] == .loading
    }

    await viewModel.refresh()

    viewModel.loadBodyIfNeeded(for: item)
    await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        viewModel.timelineBodyStates[item.id] == .loaded(body)
    }

    #expect(viewModel.timelineBodyStates[item.id] == .loaded(body))
    #expect(provider.loadBodyCallCount == 2)
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
func liveProviderCoalescesBackgroundFolderRefreshes() async throws {
    let requestLog = temporaryAppServerRequestLog()
    let script = try makeFolderRefreshAppServerScript(requestLog: requestLog)
    defer {
        try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: requestLog)
    }

    let databaseQueue = try DatabaseQueue()
    try DatabaseSchemaFactory.initialize(databaseQueue)
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([
        DiscoveredAccount(accountKey: "work", isDefault: true)
    ])
    try repository.upsertFolders([
        DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal),
        DiscoveredFolder(accountKey: "work", providerName: "Spam", role: .junk)
    ])

    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 2
    )
    let provider = LiveMailiaAppDataProvider(
        databaseQueue: databaseQueue,
        appServerClient: client,
        downloadsDirectory: FileManager.default.temporaryDirectory,
        backgroundMailboxMaintenanceDelayNanoseconds: 0
    )

    do {
        _ = try await provider.refresh(
            workspace: .main,
            searchQuery: "",
            options: MailiaRefreshOptions(),
            progress: { _ in }
        )
        _ = try await provider.refresh(
            workspace: .main,
            searchQuery: "",
            options: MailiaRefreshOptions(),
            progress: { _ in }
        )

        await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            ((try? loggedAppServerMethods(from: requestLog)) ?? [])
                .filter { $0 == "folder/list" }
                .count == 1
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        let methods = try loggedAppServerMethods(from: requestLog)
        #expect(methods.filter { $0 == "folder/list" }.count == 1)
        try await client.shutdown()
    } catch {
        try? await client.shutdown()
        throw error
    }
}

@MainActor
@Test
func liveProviderSendsPlainNewMessageAsRawMimeWithoutTemplateWrite() async throws {
    let requestLog = temporaryAppServerRequestLog()
    let script = try makeSuccessfulSendAppServerScript(requestLog: requestLog)
    defer {
        try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: requestLog)
    }

    let databaseQueue = try DatabaseQueue()
    try DatabaseSchemaFactory.initialize(databaseQueue)
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([
        DiscoveredAccount(
            accountKey: "work",
            emailAddress: "sender@example.com",
            displayName: "Sender",
            isDefault: true
        )
    ])

    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 2
    )
    let provider = LiveMailiaAppDataProvider(
        databaseQueue: databaseQueue,
        appServerClient: client,
        downloadsDirectory: FileManager.default.temporaryDirectory
    )

    do {
        try await provider.sendNewMessage(
            to: ["recipient@example.net"],
            subject: "Hello",
            content: MailiaComposerContent(plainText: "Hello"),
            accountKey: "work"
        )
        try await client.shutdown()
    } catch {
        try? await client.shutdown()
        throw error
    }

    let raw = try #require(try sentRawMessages(from: requestLog).first)
    #expect(raw.contains("From: Sender <sender@example.com>"))
    #expect(raw.contains("To: recipient@example.net"))
    #expect(raw.contains("Subject: Hello"))
    #expect(raw.contains("Content-Type: text/plain; charset=utf-8"))
    #expect(raw.contains("SGVsbG8="))
}

@MainActor
@Test
func liveProviderSendsRichNewMessageAsRawMimeWithoutTemplateWrite() async throws {
    let requestLog = temporaryAppServerRequestLog()
    let script = try makeSuccessfulSendAppServerScript(requestLog: requestLog)
    defer {
        try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: requestLog)
    }

    let databaseQueue = try DatabaseQueue()
    try DatabaseSchemaFactory.initialize(databaseQueue)
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([
        DiscoveredAccount(
            accountKey: "work",
            emailAddress: "sender@example.com",
            displayName: "Sender",
            isDefault: true
        )
    ])

    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 2
    )
    let provider = LiveMailiaAppDataProvider(
        databaseQueue: databaseQueue,
        appServerClient: client,
        downloadsDirectory: FileManager.default.temporaryDirectory
    )

    let body = NSMutableAttributedString(
        string: "Hello",
        attributes: ComposerTextDefaults.bodyAttributes
    )
    let boldFont = NSFontManager.shared.convert(
        ComposerTextDefaults.bodyFont,
        toHaveTrait: .boldFontMask
    )
    body.addAttribute(.font, value: boldFont, range: NSRange(location: 0, length: 5))

    do {
        try await provider.sendNewMessage(
            to: ["recipient@example.net"],
            subject: "Hello",
            content: MailiaComposerContent(attributedBody: body, attachments: []),
            accountKey: "work"
        )
        try await client.shutdown()
    } catch {
        try? await client.shutdown()
        throw error
    }

    let raw = try #require(try sentRawMessages(from: requestLog).first)
    #expect(raw.contains("From: Sender <sender@example.com>"))
    #expect(raw.contains("To: recipient@example.net"))
    #expect(raw.contains("Subject: Hello"))
    #expect(raw.contains("Content-Type: multipart/alternative; boundary="))
    #expect(raw.contains("PGRpdj48c3Ryb25nPkhlbGxvPC9zdHJvbmc+PC9kaXY+"))
}

@MainActor
@Test
func liveProviderSendsNewMessageThroughAppServer() async throws {
    let script = try makeAppServerScript(body: """
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      method=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p')
      case "$method" in
        *initialize*)
          printf '{"id":%s,"result":{"serverName":"mailia-mail","protocolVersion":1}}\\n' "$id"
          ;;
        *noop*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          ;;
        *message*send*)
          printf '{"id":%s,"result":{"sent":true}}\\n' "$id"
          ;;
        *shutdown*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          exit 0
          ;;
        *)
          printf '{"id":%s,"error":{"code":"method_not_found","message":"unknown"}}\\n' "$id"
          ;;
      esac
    done
    """)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

    let databaseQueue = try DatabaseQueue()
    try DatabaseSchemaFactory.initialize(databaseQueue)
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([
        DiscoveredAccount(
            accountKey: "work",
            emailAddress: "sender@example.com",
            displayName: "Sender",
            isDefault: true
        )
    ])

    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 2
    )
    let provider = LiveMailiaAppDataProvider(
        databaseQueue: databaseQueue,
        appServerClient: client,
        downloadsDirectory: FileManager.default.temporaryDirectory
    )

    do {
        try await provider.sendNewMessage(
            to: ["recipient@example.net"],
            subject: "Hello",
            content: MailiaComposerContent(plainText: "Hello"),
            accountKey: "work"
        )
        try await client.shutdown()
    } catch {
        try? await client.shutdown()
        throw error
    }
}

@MainActor
@Test
func liveProviderSetsMessageFlagThroughAppServer() async throws {
    let script = try makeAppServerScript(body: """
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      method=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p')
      case "$method" in
        *initialize*)
          printf '{"id":%s,"result":{"serverName":"mailia-mail","protocolVersion":1}}\\n' "$id"
          ;;
        *noop*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          ;;
        *message*modify*)
          printf '{"id":%s,"result":{"id":"inbox-1","folder":"INBOX"}}\\n' "$id"
          ;;
        *shutdown*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          exit 0
          ;;
        *)
          printf '{"id":%s,"error":{"code":"method_not_found","message":"unknown"}}\\n' "$id"
          ;;
      esac
    done
    """)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

    let databaseQueue = try DatabaseQueue()
    try DatabaseSchemaFactory.initialize(databaseQueue)
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([DiscoveredAccount(accountKey: "work")])
    try repository.upsertFolders([DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal)])
    let messageIDs = try repository.upsertEnvelopes([
        EnvelopeMessage(
            accountKey: "work",
            folderName: "INBOX",
            himalayaEnvelopeID: "inbox-1",
            subject: "Flag me",
            from: MailAddress(displayName: "Alice", emailAddress: "alice@example.net"),
            messageDate: "2026-05-01T10:00:00Z"
        )
    ])
    let item = mailiaTimelineItem(
        id: try #require(messageIDs.first),
        entityID: 1,
        accountLabel: "work",
        folderLabel: "INBOX",
        envelopeID: "inbox-1",
        isFlagged: false
    )

    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 2
    )
    let provider = LiveMailiaAppDataProvider(
        databaseQueue: databaseQueue,
        appServerClient: client,
        downloadsDirectory: FileManager.default.temporaryDirectory
    )

    do {
        try await provider.setMessageFlag(item: item, isFlagged: true)
        let locations = try repository.messageLocations(messageID: item.id)
        #expect(locations.count == 1)
        let messages = try repository.messages(entityID: item.entityID, workspace: .flagged)
        #expect(messages.map(\.himalayaEnvelopeID) == ["inbox-1"])
        try await client.shutdown()
    } catch {
        try? await client.shutdown()
        throw error
    }
}

@MainActor
@Test
func liveProviderMarksEntityReadOnlyAfterAppServerSuccess() async throws {
    let script = try makeAppServerScript(body: """
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      method=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p')
      case "$method" in
        *initialize*)
          printf '{"id":%s,"result":{"serverName":"mailia-mail","protocolVersion":1}}\\n' "$id"
          ;;
        *noop*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          ;;
        *message*modify*)
          printf '{"id":%s,"result":{"id":"inbox-1","folder":"INBOX"}}\\n' "$id"
          ;;
        *shutdown*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          exit 0
          ;;
        *)
          printf '{"id":%s,"error":{"code":"method_not_found","message":"unknown"}}\\n' "$id"
          ;;
      esac
    done
    """)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

    let databaseQueue = try DatabaseQueue()
    try DatabaseSchemaFactory.initialize(databaseQueue)
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([DiscoveredAccount(accountKey: "work")])
    try repository.upsertFolders([DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal)])
    _ = try repository.upsertEnvelopes([
        EnvelopeMessage(
            accountKey: "work",
            folderName: "INBOX",
            himalayaEnvelopeID: "inbox-1",
            subject: "Unread",
            from: MailAddress(displayName: "Alice", emailAddress: "alice@example.net"),
            messageDate: "2026-05-01T10:00:00Z"
        )
    ])
    let entity = try #require(try repository.entityList(workspace: .main).first)

    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 2
    )
    let provider = LiveMailiaAppDataProvider(
        databaseQueue: databaseQueue,
        appServerClient: client,
        downloadsDirectory: FileManager.default.temporaryDirectory
    )

    do {
        try await provider.markEntityRead(entityID: entity.id, workspace: .main)
        let unreadLocations = try repository.messageLocations(
            entityID: entity.id,
            workspace: .main,
            onlyUnread: true
        )
        #expect(unreadLocations.isEmpty)
        try await client.shutdown()
    } catch {
        try? await client.shutdown()
        throw error
    }
}

@MainActor
@Test
func liveProviderMarksSingleMessageReadWithoutMarkingWholeEntity() async throws {
    let script = try makeAppServerScript(body: """
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      method=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p')
      case "$method" in
        *initialize*)
          printf '{"id":%s,"result":{"serverName":"mailia-mail","protocolVersion":1}}\\n' "$id"
          ;;
        *noop*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          ;;
        *message*modify*)
          printf '{"id":%s,"result":{"id":"inbox-1","folder":"INBOX"}}\\n' "$id"
          ;;
        *shutdown*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          exit 0
          ;;
        *)
          printf '{"id":%s,"error":{"code":"method_not_found","message":"unknown"}}\\n' "$id"
          ;;
      esac
    done
    """)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

    let databaseQueue = try DatabaseQueue()
    try DatabaseSchemaFactory.initialize(databaseQueue)
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([DiscoveredAccount(accountKey: "work")])
    try repository.upsertFolders([DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal)])
    _ = try repository.upsertEnvelopes([
        EnvelopeMessage(
            accountKey: "work",
            folderName: "INBOX",
            himalayaEnvelopeID: "inbox-1",
            subject: "Unread 1",
            from: MailAddress(displayName: "Alice", emailAddress: "alice@example.net"),
            messageDate: "2026-05-01T10:00:00Z"
        ),
        EnvelopeMessage(
            accountKey: "work",
            folderName: "INBOX",
            himalayaEnvelopeID: "inbox-2",
            subject: "Unread 2",
            from: MailAddress(displayName: "Alice", emailAddress: "alice@example.net"),
            messageDate: "2026-05-02T10:00:00Z"
        )
    ])
    let entity = try #require(try repository.entityList(workspace: .main).first)
    let message = try #require(
        try repository.messages(entityID: entity.id, workspace: .main)
            .first { $0.subject == "Unread 1" }
    )

    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 2
    )
    let provider = LiveMailiaAppDataProvider(
        databaseQueue: databaseQueue,
        appServerClient: client,
        downloadsDirectory: FileManager.default.temporaryDirectory
    )

    do {
        try await provider.markMessageRead(
            item: mailiaTimelineItem(id: message.messageID, entityID: entity.id),
            workspace: .main
        )
        let unreadLocations = try repository.messageLocations(
            entityID: entity.id,
            workspace: .main,
            onlyUnread: true
        )
        #expect(unreadLocations.count == 1)
        #expect(unreadLocations.first?.himalayaEnvelopeID == "inbox-2")
        try await client.shutdown()
    } catch {
        try? await client.shutdown()
        throw error
    }
}

@MainActor
@Test
func liveProviderBatchMarkReadSkipsAlreadySeenMessages() async throws {
    let requestLog = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailia-mark-read-batch-\(UUID().uuidString).jsonl")
    let script = try makeAppServerScript(body: """
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> '\(requestLog.path)'
      id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      method=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p')
      case "$method" in
        *initialize*)
          printf '{"id":%s,"result":{"serverName":"mailia-mail","protocolVersion":1}}\\n' "$id"
          ;;
        *noop*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          ;;
        *message*modify*)
          printf '{"id":%s,"result":{"id":"older","folder":"INBOX"}}\\n' "$id"
          ;;
        *shutdown*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          exit 0
          ;;
        *)
          printf '{"id":%s,"error":{"code":"method_not_found","message":"unknown"}}\\n' "$id"
          ;;
      esac
    done
    """)
    defer {
        try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: requestLog)
    }

    let databaseQueue = try DatabaseQueue()
    try DatabaseSchemaFactory.initialize(databaseQueue)
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([DiscoveredAccount(accountKey: "work")])
    try repository.upsertFolders([DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal)])
    _ = try repository.upsertEnvelopes([
        EnvelopeMessage(
            accountKey: "work",
            folderName: "INBOX",
            himalayaEnvelopeID: "older",
            subject: "Older unread",
            from: MailAddress(displayName: "Alice", emailAddress: "alice@example.net"),
            messageDate: "2026-05-01T10:00:00Z"
        ),
        EnvelopeMessage(
            accountKey: "work",
            folderName: "INBOX",
            himalayaEnvelopeID: "latest",
            subject: "Latest seen",
            from: MailAddress(displayName: "Alice", emailAddress: "alice@example.net"),
            messageDate: "2026-05-02T10:00:00Z",
            flags: ["Seen"]
        )
    ])
    let entity = try #require(try repository.entityList(workspace: .main).first)
    let messages = try repository.messages(entityID: entity.id, workspace: .main)
    let older = try #require(messages.first { $0.subject == "Older unread" })
    let latest = try #require(messages.first { $0.subject == "Latest seen" })

    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 2
    )
    let provider = LiveMailiaAppDataProvider(
        databaseQueue: databaseQueue,
        appServerClient: client,
        downloadsDirectory: FileManager.default.temporaryDirectory
    )

    do {
        let changedCount = try await provider.markMessagesRead(
            items: [
                mailiaTimelineItem(id: latest.messageID, entityID: entity.id),
                mailiaTimelineItem(id: older.messageID, entityID: entity.id)
            ],
            workspace: .main
        )
        #expect(changedCount == 1)
        let unreadLocations = try repository.messageLocations(
            entityID: entity.id,
            workspace: .main,
            onlyUnread: true
        )
        #expect(unreadLocations.isEmpty)

        let log = (try? String(contentsOf: requestLog, encoding: .utf8)) ?? ""
        let modifyRequestCount = log.split(separator: "\n").filter {
            $0.contains(#""method""#) && $0.contains("message") && $0.contains("modify")
        }.count
        #expect(modifyRequestCount == 1)
        try await client.shutdown()
    } catch {
        try? await client.shutdown()
        throw error
    }
}

@MainActor
@Test
func liveProviderMarksEntityReadConcurrently() async throws {
    let requestLog = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailia-mark-read-concurrent-\(UUID().uuidString).jsonl")
    let script = try makeAppServerScript(body: """
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> '\(requestLog.path)'
      id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      method=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p')
      case "$method" in
        *initialize*)
          printf '{"id":%s,"result":{"serverName":"mailia-mail","protocolVersion":1}}\\n' "$id"
          ;;
        *noop*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          ;;
        *message*modify*)
          (
            /bin/sleep 0.35
            printf '{"id":%s,"result":{"id":"seen","folder":"INBOX"}}\\n' "$id"
          ) &
          ;;
        *shutdown*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          exit 0
          ;;
        *)
          printf '{"id":%s,"error":{"code":"method_not_found","message":"unknown"}}\\n' "$id"
          ;;
      esac
    done
    """)
    defer {
        try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: requestLog)
    }

    let databaseQueue = try DatabaseQueue()
    try DatabaseSchemaFactory.initialize(databaseQueue)
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([DiscoveredAccount(accountKey: "work")])
    try repository.upsertFolders([DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal)])
    _ = try repository.upsertEnvelopes([
        EnvelopeMessage(
            accountKey: "work",
            folderName: "INBOX",
            himalayaEnvelopeID: "inbox-1",
            subject: "Unread 1",
            from: MailAddress(displayName: "Alice", emailAddress: "alice@example.net"),
            messageDate: "2026-05-01T10:00:00Z"
        ),
        EnvelopeMessage(
            accountKey: "work",
            folderName: "INBOX",
            himalayaEnvelopeID: "inbox-2",
            subject: "Unread 2",
            from: MailAddress(displayName: "Alice", emailAddress: "alice@example.net"),
            messageDate: "2026-05-02T10:00:00Z"
        ),
        EnvelopeMessage(
            accountKey: "work",
            folderName: "INBOX",
            himalayaEnvelopeID: "inbox-3",
            subject: "Unread 3",
            from: MailAddress(displayName: "Alice", emailAddress: "alice@example.net"),
            messageDate: "2026-05-03T10:00:00Z"
        )
    ])
    let entity = try #require(try repository.entityList(workspace: .main).first)

    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 3
    )
    let provider = LiveMailiaAppDataProvider(
        databaseQueue: databaseQueue,
        appServerClient: client,
        downloadsDirectory: FileManager.default.temporaryDirectory,
        appServerRequestLimiter: MailAppServerRequestLimiter(maxConcurrentRequests: 4)
    )

    do {
        let start = Date()
        try await provider.markEntityRead(entityID: entity.id, workspace: .main)
        let elapsed = Date().timeIntervalSince(start)
        let unreadLocations = try repository.messageLocations(
            entityID: entity.id,
            workspace: .main,
            onlyUnread: true
        )
        #expect(unreadLocations.isEmpty)
        #expect(elapsed < 0.9)

        let log = (try? String(contentsOf: requestLog, encoding: .utf8)) ?? ""
        let modifyRequestCount = log.split(separator: "\n").filter {
            $0.contains(#""method""#) && $0.contains("message") && $0.contains("modify")
        }.count
        #expect(modifyRequestCount == 3)
        try await client.shutdown()
    } catch {
        try? await client.shutdown()
        throw error
    }
}

@MainActor
@Test
func liveProviderMarksReadThroughPreferredLocationAndUpdatesAllLocalLocations() async throws {
    let requestLog = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailia-mark-read-preferred-\(UUID().uuidString).jsonl")
    let script = try makeAppServerScript(body: """
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> '\(requestLog.path)'
      id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      method=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p')
      folder=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"folder":"\\([^"]*\\)".*/\\1/p')
      case "$method" in
        *initialize*)
          printf '{"id":%s,"result":{"serverName":"mailia-mail","protocolVersion":1}}\\n' "$id"
          ;;
        *noop*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          ;;
        *message*modify*)
          if [ "$folder" = "INBOX" ]; then
            printf '{"id":%s,"result":{"id":"inbox-1","folder":"INBOX"}}\\n' "$id"
          else
            printf '{"id":%s,"error":{"code":"internal","message":"non-writable folder"}}\\n' "$id"
          fi
          ;;
        *shutdown*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          exit 0
          ;;
        *)
          printf '{"id":%s,"error":{"code":"method_not_found","message":"unknown"}}\\n' "$id"
          ;;
      esac
    done
    """)
    defer {
        try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: requestLog)
    }

    let databaseQueue = try DatabaseQueue()
    try DatabaseSchemaFactory.initialize(databaseQueue)
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([DiscoveredAccount(accountKey: "work")])
    try repository.upsertFolders([
        DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal),
        DiscoveredFolder(accountKey: "work", providerName: "[Gmail]/All Mail", role: .normal),
        DiscoveredFolder(accountKey: "work", providerName: "[Gmail]/Important", role: .normal)
    ])
    _ = try repository.upsertEnvelopes([
        EnvelopeMessage(
            accountKey: "work",
            folderName: "[Gmail]/All Mail",
            himalayaEnvelopeID: "all-1",
            rfcMessageID: "<preferred-location@example.net>",
            subject: "Unread",
            from: MailAddress(displayName: "Alice", emailAddress: "alice@example.net"),
            messageDate: "2026-05-01T10:00:00Z"
        ),
        EnvelopeMessage(
            accountKey: "work",
            folderName: "[Gmail]/Important",
            himalayaEnvelopeID: "important-1",
            rfcMessageID: "<preferred-location@example.net>",
            subject: "Unread",
            from: MailAddress(displayName: "Alice", emailAddress: "alice@example.net"),
            messageDate: "2026-05-01T10:00:00Z"
        ),
        EnvelopeMessage(
            accountKey: "work",
            folderName: "INBOX",
            himalayaEnvelopeID: "inbox-1",
            rfcMessageID: "<preferred-location@example.net>",
            subject: "Unread",
            from: MailAddress(displayName: "Alice", emailAddress: "alice@example.net"),
            messageDate: "2026-05-01T10:00:00Z"
        )
    ])
    let entity = try #require(try repository.entityList(workspace: .main).first)

    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 2
    )
    let provider = LiveMailiaAppDataProvider(
        databaseQueue: databaseQueue,
        appServerClient: client,
        downloadsDirectory: FileManager.default.temporaryDirectory
    )

    do {
        try await provider.markEntityRead(entityID: entity.id, workspace: .main)
        let unreadLocations = try repository.messageLocations(
            entityID: entity.id,
            workspace: .main,
            onlyUnread: true
        )
        #expect(unreadLocations.isEmpty)

        let log = (try? String(contentsOf: requestLog, encoding: .utf8)) ?? ""
        let modifyRequests = log.split(separator: "\n").filter {
            $0.contains(#""method""#) && $0.contains("message") && $0.contains("modify")
        }
        #expect(modifyRequests.count == 1)
        #expect(modifyRequests.first?.contains(#""folder":"INBOX""#) == true)
        try await client.shutdown()
    } catch {
        try? await client.shutdown()
        throw error
    }
}

@MainActor
@Test
func liveProviderDoesNotMarkEntityReadLocallyWhenAppServerFails() async throws {
    let script = try makeAppServerScript(body: """
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      method=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p')
      case "$method" in
        *initialize*)
          printf '{"id":%s,"result":{"serverName":"mailia-mail","protocolVersion":1}}\\n' "$id"
          ;;
        *noop*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          ;;
        *message*modify*)
          printf '{"id":%s,"error":{"code":"imap","message":"store failed"}}\\n' "$id"
          ;;
        *shutdown*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          exit 0
          ;;
        *)
          printf '{"id":%s,"error":{"code":"method_not_found","message":"unknown"}}\\n' "$id"
          ;;
      esac
    done
    """)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

    let databaseQueue = try DatabaseQueue()
    try DatabaseSchemaFactory.initialize(databaseQueue)
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([DiscoveredAccount(accountKey: "work")])
    try repository.upsertFolders([DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal)])
    _ = try repository.upsertEnvelopes([
        EnvelopeMessage(
            accountKey: "work",
            folderName: "INBOX",
            himalayaEnvelopeID: "inbox-1",
            subject: "Unread",
            from: MailAddress(displayName: "Alice", emailAddress: "alice@example.net"),
            messageDate: "2026-05-01T10:00:00Z"
        )
    ])
    let entity = try #require(try repository.entityList(workspace: .main).first)

    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 2
    )
    let provider = LiveMailiaAppDataProvider(
        databaseQueue: databaseQueue,
        appServerClient: client,
        downloadsDirectory: FileManager.default.temporaryDirectory
    )

    do {
        try await provider.markEntityRead(entityID: entity.id, workspace: .main)
        Issue.record("Expected markEntityRead to throw when app-server message/modify fails.")
    } catch {
        let unreadLocations = try repository.messageLocations(
            entityID: entity.id,
            workspace: .main,
            onlyUnread: true
        )
        #expect(unreadLocations.count == 1)
    }

    try? await client.shutdown()
}

@MainActor
@Test
func liveProviderMovesEntityThroughAppServer() async throws {
    let script = try makeAppServerScript(body: """
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      method=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p')
      case "$method" in
        *initialize*)
          printf '{"id":%s,"result":{"serverName":"mailia-mail","protocolVersion":1}}\\n' "$id"
          ;;
        *noop*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          ;;
        *account*list*)
          printf '{"id":%s,"result":{"accounts":[{"name":"work","backend":"imap","default":true,"emailAddress":"sender@example.com","displayName":"Sender"}]}}\\n' "$id"
          ;;
        *folder*list*)
          printf '{"id":%s,"result":{"folders":[{"name":"INBOX","desc":"\\\\\\\\Inbox"},{"name":"Trash","desc":"\\\\\\\\Trash"}]}}\\n' "$id"
          ;;
        *message*modify*)
          printf '{"id":%s,"result":{"id":"inbox-1","folder":"Trash"}}\\n' "$id"
          ;;
        *shutdown*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          exit 0
          ;;
        *)
          printf '{"id":%s,"error":{"code":"method_not_found","message":"unknown"}}\\n' "$id"
          ;;
      esac
    done
    """)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

    let databaseQueue = try DatabaseQueue()
    try DatabaseSchemaFactory.initialize(databaseQueue)
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([DiscoveredAccount(accountKey: "work")])
    try repository.upsertFolders([
        DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal),
        DiscoveredFolder(accountKey: "work", providerName: "Trash", role: .trash)
    ])
    _ = try repository.upsertEnvelopes([
        EnvelopeMessage(
            accountKey: "work",
            folderName: "INBOX",
            himalayaEnvelopeID: "inbox-1",
            subject: "Move me",
            from: MailAddress(displayName: "Alice", emailAddress: "alice@example.net"),
            messageDate: "2026-05-01T10:00:00Z"
        )
    ])
    let entity = try #require(try repository.entityList(workspace: .main).first)

    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 2
    )
    let provider = LiveMailiaAppDataProvider(
        databaseQueue: databaseQueue,
        appServerClient: client,
        downloadsDirectory: FileManager.default.temporaryDirectory
    )

    do {
        try await provider.performEntityAction(.moveToTrash, entityID: entity.id, workspace: .main) { _ in }
        let remainingLocations = try repository.messageLocations(
            entityID: entity.id,
            workspace: .main,
            sourceRoles: [.normal]
        )
        #expect(remainingLocations.isEmpty)
        try await client.shutdown()
    } catch {
        try? await client.shutdown()
        throw error
    }
}

@MainActor
@Test
func liveProviderLoadsBodyThroughAppServer() async throws {
    let script = try makeAppServerScript(body: """
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      method=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p')
      case "$method" in
        *initialize*)
          printf '{"id":%s,"result":{"serverName":"mailia-mail","protocolVersion":1}}\\n' "$id"
          ;;
        *noop*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          ;;
        *message*get*)
          printf '{"id":%s,"result":{"id":"inbox-1","html":"<p>Hello from app-server</p>","text":"Hello from app-server","has_attachment":false}}\\n' "$id"
          ;;
        *shutdown*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          exit 0
          ;;
        *)
          printf '{"id":%s,"error":{"code":"method_not_found","message":"unknown"}}\\n' "$id"
          ;;
      esac
    done
    """)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

    let databaseQueue = try DatabaseQueue()
    try DatabaseSchemaFactory.initialize(databaseQueue)
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([DiscoveredAccount(accountKey: "work")])
    try repository.upsertFolders([DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal)])
    let messageIDs = try repository.upsertEnvelopes([
        EnvelopeMessage(
            accountKey: "work",
            folderName: "INBOX",
            himalayaEnvelopeID: "inbox-1",
            subject: "Body",
            from: MailAddress(displayName: "Alice", emailAddress: "alice@example.net"),
            messageDate: "2026-05-01T10:00:00Z"
        )
    ])
    let item = mailiaTimelineItem(
        id: try #require(messageIDs.first),
        entityID: 1,
        accountLabel: "work",
        folderLabel: "INBOX",
        envelopeID: "inbox-1"
    )

    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 2
    )
    let provider = LiveMailiaAppDataProvider(
        databaseQueue: databaseQueue,
        appServerClient: client,
        downloadsDirectory: FileManager.default.temporaryDirectory
    )

    do {
        let body = try await provider.loadBody(for: item)
        #expect(body.html?.contains("Hello from app-server") == true)
        let cachedBody = try #require(try repository.messageBody(messageID: item.id))
        #expect(cachedBody.sanitizedHTML?.contains("Hello from app-server") == true)
        try await client.shutdown()
    } catch {
        try? await client.shutdown()
        throw error
    }
}

@MainActor
@Test
func liveProviderMarksMissingBodyLocationAndFallsThroughToNextLocation() async throws {
    let script = try makeAppServerScript(body: """
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      method=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p')
      case "$method" in
        *initialize*)
          printf '{"id":%s,"result":{"serverName":"mailia-mail","protocolVersion":1}}\\n' "$id"
          ;;
        *noop*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          ;;
        *message*get*)
          case "$line" in
            *stale-1*)
              printf '{"id":%s,"error":{"code":"invalid_request","message":"Message `stale-1` was not found in folder `INBOX` for account `work`"}}\\n' "$id"
              ;;
            *)
              printf '{"id":%s,"result":{"id":"live-1","html":"<p>Hello from archive</p>","text":"Hello from archive","has_attachment":false}}\\n' "$id"
              ;;
          esac
          ;;
        *shutdown*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          exit 0
          ;;
        *)
          printf '{"id":%s,"error":{"code":"method_not_found","message":"unknown"}}\\n' "$id"
          ;;
      esac
    done
    """)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

    let databaseQueue = try DatabaseQueue()
    try DatabaseSchemaFactory.initialize(databaseQueue)
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([DiscoveredAccount(accountKey: "work")])
    try repository.upsertFolders([
        DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal),
        DiscoveredFolder(accountKey: "work", providerName: "Archive", role: .normal)
    ])
    let messageIDs = try repository.upsertEnvelopes([
        EnvelopeMessage(
            accountKey: "work",
            folderName: "INBOX",
            himalayaEnvelopeID: "stale-1",
            rfcMessageID: "<body-location@example.com>",
            subject: "Body",
            from: MailAddress(displayName: "Alice", emailAddress: "alice@example.net"),
            messageDate: "2026-05-01T10:00:00Z"
        ),
        EnvelopeMessage(
            accountKey: "work",
            folderName: "Archive",
            himalayaEnvelopeID: "live-1",
            rfcMessageID: "<body-location@example.com>",
            subject: "Body",
            from: MailAddress(displayName: "Alice", emailAddress: "alice@example.net"),
            messageDate: "2026-05-01T10:00:00Z"
        )
    ])
    let messageID = try #require(messageIDs.first)
    let item = mailiaTimelineItem(
        id: messageID,
        entityID: 1,
        accountLabel: "work",
        folderLabel: "INBOX",
        envelopeID: "stale-1"
    )

    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 2
    )
    let provider = LiveMailiaAppDataProvider(
        databaseQueue: databaseQueue,
        appServerClient: client,
        downloadsDirectory: FileManager.default.temporaryDirectory
    )

    do {
        let body = try await provider.loadBody(for: item)
        #expect(body.html?.contains("Hello from archive") == true)
        let remainingLocations = try repository.messageLocations(messageID: messageID)
        #expect(remainingLocations.map(\.himalayaEnvelopeID) == ["live-1"])
        try await client.shutdown()
    } catch {
        try? await client.shutdown()
        throw error
    }
}

@MainActor
@Test
func liveProviderDownloadsAttachmentsThroughAppServer() async throws {
    let downloadsDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailia-download-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: downloadsDirectory) }

    let script = try makeAppServerScript(body: """
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      method=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p')
      case "$method" in
        *initialize*)
          printf '{"id":%s,"result":{"serverName":"mailia-mail","protocolVersion":1}}\\n' "$id"
          ;;
        *noop*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          ;;
        *attachment*download*)
          downloads_dir='\(downloadsDirectory.path)'
          /bin/mkdir -p "$downloads_dir"
          /bin/printf 'file' > "$downloads_dir/report.txt"
          printf '{"id":%s,"result":{"attachments":[{"id":"1","filename":"report.txt","path":"%s/report.txt","size":4}]}}\\n' "$id" "$downloads_dir"
          ;;
        *shutdown*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          exit 0
          ;;
        *)
          printf '{"id":%s,"error":{"code":"method_not_found","message":"unknown"}}\\n' "$id"
          ;;
      esac
    done
    """)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 2
    )
    var revealedFiles: [URL] = []
    var revealedDirectory: URL?
    let provider = LiveMailiaAppDataProvider(
        databaseQueue: try DatabaseQueue(),
        appServerClient: client,
        downloadsDirectory: downloadsDirectory,
        revealDownloadedFiles: { files, directory in
            revealedFiles = files
            revealedDirectory = directory
        }
    )
    let item = mailiaTimelineItem(
        id: 1,
        entityID: 1,
        accountLabel: "work",
        folderLabel: "INBOX",
        envelopeID: "inbox-1",
        hasAttachments: true
    )

    do {
        let result = try await provider.downloadAttachments(for: item)
        #expect(result.directoryPath == downloadsDirectory.path)
        #expect(result.fileNames == ["report.txt"])
        #expect(revealedFiles.map(\.lastPathComponent) == ["report.txt"])
        #expect(revealedDirectory == downloadsDirectory)
        try await client.shutdown()
    } catch {
        try? await client.shutdown()
        throw error
    }
}

@MainActor
@Test
func liveProviderSendsReplyAsRawMimeWithoutTemplateReply() async throws {
    let requestLog = temporaryAppServerRequestLog()
    let script = try makeSuccessfulSendAppServerScript(requestLog: requestLog)
    defer {
        try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: requestLog)
    }

    let databaseQueue = try DatabaseQueue()
    try DatabaseSchemaFactory.initialize(databaseQueue)
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([
        DiscoveredAccount(
            accountKey: "work",
            emailAddress: "sender@example.com",
            displayName: "Sender",
            isDefault: true
        )
    ])

    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 2
    )
    let provider = LiveMailiaAppDataProvider(
        databaseQueue: databaseQueue,
        appServerClient: client,
        downloadsDirectory: FileManager.default.temporaryDirectory
    )
    let item = MailiaTimelineItem(
        id: 1,
        entityID: 2,
        direction: .incoming,
        rfcMessageID: "<original@example.net>",
        subject: "Project update",
        preview: "Hello",
        html: nil,
        htmlVariants: nil,
        date: nil,
        accountLabel: "work",
        accountEmoji: nil,
        accountAvatarImageDataURL: nil,
        folderLabel: "Inbox",
        envelopeID: "42",
        isFlagged: false,
        from: MailAddress(displayName: "Alice", emailAddress: "alice@example.net"),
        to: [MailAddress(displayName: "Sender", emailAddress: "sender@example.com")],
        cc: [MailAddress(displayName: "Bob", emailAddress: "bob@example.net")],
        fromLabel: "Alice <alice@example.net>",
        toLabel: "Sender <sender@example.com>",
        hasAttachments: false
    )

    do {
        try await provider.sendReply(
            to: item,
            content: MailiaComposerContent(plainText: "Thanks"),
            replyAll: true,
            accountKey: nil
        )
        try await client.shutdown()
    } catch {
        try? await client.shutdown()
        throw error
    }

    let raw = try #require(try sentRawMessages(from: requestLog).first)
    #expect(raw.contains("From: Sender <sender@example.com>"))
    #expect(raw.contains("To: Alice <alice@example.net>"))
    #expect(raw.contains("Cc: Bob <bob@example.net>"))
    #expect(!raw.contains("Cc: Sender <sender@example.com>"))
    #expect(raw.contains("Subject: Re: Project update"))
    #expect(raw.contains("In-Reply-To: <original@example.net>"))
    #expect(raw.contains("References: <original@example.net>"))
    #expect(raw.contains("VGhhbmtz"))
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

@MainActor
@Test
func sidebarPreviewDoesNotFallbackToReplySubjectWhenBodyPreviewIsMissing() {
    let entity = mailiaEntitySummary(
        id: 1,
        displayName: "Alice",
        primaryEmailAddress: "alice@example.com",
        latestSubject: "Re: Roadmap",
        latestBodyPreview: nil
    )

    #expect(entity.sidebarPreview(hideReplySubjects: true, hideQuotedReplyText: true) == "")
}

private func mailiaEntitySummary(
    id: Int64,
    displayName: String,
    primaryEmailAddress: String? = nil,
    emailAddresses: [String]? = nil,
    unreadCount: Int = 0,
    latestSubject: String = "(No subject)",
    latestBodyPreview: String? = nil,
    latestMessageID: Int64? = nil,
    accountKeys: [String] = [],
    avatarImageDataURL: String? = nil
) -> MailiaEntitySummary {
    MailiaEntitySummary(
        id: id,
        displayName: displayName,
        primaryEmailAddress: primaryEmailAddress,
        emailAddresses: emailAddresses ?? (primaryEmailAddress.map { [$0] } ?? []),
        kind: .unknown,
        unreadCount: unreadCount,
        latestSubject: latestSubject,
        latestBodyPreview: latestBodyPreview,
        latestMessageID: latestMessageID,
        latestDate: nil,
        accountKeys: accountKeys,
        accountLabel: "",
        workspace: .main,
        avatarImageDataURL: avatarImageDataURL
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
        sortOrder: nil,
        syncStatus: nil,
        syncErrorMessage: nil,
        syncCheckedAt: nil,
        avatarImageDataURL: nil
    )
}

private func mailiaTimelineItem(
    id: Int64,
    entityID: Int64,
    accountLabel: String = "gmail",
    folderLabel: String = "Inbox",
    envelopeID: String? = nil,
    isFlagged: Bool = false,
    hasAttachments: Bool = false
) -> MailiaTimelineItem {
    MailiaTimelineItem(
        id: id,
        entityID: entityID,
        direction: .incoming,
        rfcMessageID: "<message-\(id)@example.com>",
        subject: "Hello",
        preview: "Hello",
        html: nil,
        htmlVariants: nil,
        date: nil,
        accountLabel: accountLabel,
        accountEmoji: nil,
        accountAvatarImageDataURL: nil,
        folderLabel: folderLabel,
        envelopeID: envelopeID ?? "envelope-\(id)",
        isFlagged: isFlagged,
        from: MailAddress(displayName: "Alice", emailAddress: "alice@example.com"),
        to: [MailAddress(displayName: "Ryan", emailAddress: "ryan@example.com")],
        cc: [],
        fromLabel: "Alice <alice@example.com>",
        toLabel: "Ryan <ryan@example.com>",
        hasAttachments: hasAttachments
    )
}

private func makeAppServerScript(body: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailia-app-server-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("server.sh")
    try body.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

private func makeSuccessfulSendAppServerScript(requestLog: URL) throws -> URL {
    try makeAppServerScript(body: """
    #!/bin/sh
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> '\(requestLog.path)'
      id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      method=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p')
      case "$method" in
        initialize)
          printf '{"id":%s,"result":{"serverName":"mailia-mail","protocolVersion":1}}\\n' "$id"
          ;;
        *noop*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          ;;
        *message*send*)
          printf '{"id":%s,"result":{"sent":true}}\\n' "$id"
          ;;
        shutdown)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          exit 0
          ;;
        *)
          printf '{"id":%s,"error":{"code":"method_not_found","message":"unknown"}}\\n' "$id"
          ;;
      esac
    done
    """)
}

private func makeFolderRefreshAppServerScript(requestLog: URL) throws -> URL {
    try makeAppServerScript(body: """
    #!/bin/sh
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> '\(requestLog.path)'
      id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      method=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p')
      case "$method" in
        initialize)
          printf '{"id":%s,"result":{"serverName":"mailia-mail","protocolVersion":1}}\\n' "$id"
          ;;
        *noop*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          ;;
        *account*list*)
          printf '{"id":%s,"result":{"accounts":[{"name":"work","backend":"imap","default":true,"emailAddress":"sender@example.com","displayName":"Sender"}]}}\\n' "$id"
          ;;
        *folder*list*)
          printf '{"id":%s,"result":{"folders":[{"name":"INBOX","desc":"\\\\\\\\Inbox"},{"name":"Spam","desc":"\\\\\\\\Junk"}]}}\\n' "$id"
          ;;
        *message*list*)
          printf '{"id":%s,"result":{"envelopes":[]}}\\n' "$id"
          ;;
        shutdown)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          exit 0
          ;;
        *)
          printf '{"id":%s,"error":{"code":"method_not_found","message":"unknown"}}\\n' "$id"
          ;;
      esac
    done
    """)
}

private func temporaryAppServerRequestLog() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("mailia-app-server-requests-\(UUID().uuidString).jsonl")
}

private func loggedAppServerMethods(from requestLog: URL) throws -> [String] {
    guard FileManager.default.fileExists(atPath: requestLog.path) else {
        return []
    }
    let data = try Data(contentsOf: requestLog)
    return try data.split(separator: UInt8(ascii: "\n")).compactMap { line in
        guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
            return nil
        }
        return object["method"] as? String
    }
}

private func sentRawMessages(from requestLog: URL) throws -> [String] {
    guard FileManager.default.fileExists(atPath: requestLog.path) else {
        return []
    }
    let data = try Data(contentsOf: requestLog)
    return try data.split(separator: UInt8(ascii: "\n")).compactMap { line in
        guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              object["method"] as? String == "message/send",
              let params = object["params"] as? [String: Any]
        else {
            return nil
        }
        return params["raw"] as? String
    }
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
    private let bodyDelayNanoseconds: UInt64
    private let markEntityReadDelayNanoseconds: UInt64
    private let refreshError: Error?
    private let markMessagesReadResult: Result<Int, Error>
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
    private(set) var markEntityReadEntityIDs: [Int64] = []
    private(set) var markMessageReadItems: [MailiaTimelineItem] = []
    private(set) var markMessagesReadBatches: [[MailiaTimelineItem]] = []

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
        bodyDelayNanoseconds: UInt64 = 0,
        markEntityReadDelayNanoseconds: UInt64 = 0,
        refreshError: Error? = nil,
        markMessagesReadResult: Result<Int, Error> = .success(0)
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
        self.bodyDelayNanoseconds = bodyDelayNanoseconds
        self.markEntityReadDelayNanoseconds = markEntityReadDelayNanoseconds
        self.refreshError = refreshError
        self.markMessagesReadResult = markMessagesReadResult
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

    func loadLatestTimelineItems(entityIDs: [Int64], workspace: MailiaWorkspace) async throws -> [MailiaTimelineItem] {
        []
    }

    func loadBody(for item: MailiaTimelineItem) async throws -> MailiaTimelineBody {
        loadBodyCallCount += 1
        if bodyDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: bodyDelayNanoseconds)
        }
        guard !bodyResults.isEmpty else {
            throw FakeMailiaAppDataProviderError.noBodyResult
        }
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
        markEntityReadEntityIDs.append(entityID)
        if markEntityReadDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: markEntityReadDelayNanoseconds)
        }
    }

    func markMessageRead(item: MailiaTimelineItem, workspace: MailiaWorkspace) async throws {
        markMessageReadItems.append(item)
    }

    func markMessagesRead(items: [MailiaTimelineItem], workspace: MailiaWorkspace) async throws -> Int {
        markMessagesReadBatches.append(items)
        return try markMessagesReadResult.get()
    }

    func setMessageFlag(item: MailiaTimelineItem, isFlagged: Bool) async throws {
        fatalError("setMessageFlag is not used in these tests")
    }

    func downloadAttachments(for item: MailiaTimelineItem) async throws -> MailiaAttachmentDownloadResult {
        fatalError("downloadAttachments is not used in these tests")
    }

    func sendReply(
        to item: MailiaTimelineItem,
        content: MailiaComposerContent,
        replyAll: Bool,
        accountKey: String?
    ) async throws {
        fatalError("sendReply is not used in these tests")
    }

    func sendNewMessage(
        to recipients: [String],
        subject: String?,
        content: MailiaComposerContent,
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
    case noBodyResult

    var errorDescription: String? {
        switch self {
        case .refreshFailed:
            "refresh failed"
        case .noBodyResult:
            "no body result"
        }
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
