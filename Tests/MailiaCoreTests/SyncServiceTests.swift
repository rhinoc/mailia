import Foundation
import Testing
@testable import MailiaCore

@Test
func syncPolicyDefaultsAllowTwoFoldersPerAccount() {
    #expect(SyncPolicy().maxConcurrentFoldersPerAccount == 2)
}

@Test
func syncServiceDiscoversAndSyncsBoundedEnvelopesWithFakeBridge() async throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let now = try #require(HimalayaDateParser.parse("2026-05-30T00:00:00Z"))
    let fakeBridge = FakeHimalayaBridge(responses: [
        FakeHimalayaBridge.key(for: .accountList()): """
        [{"name":"work","backend":"imap","default":true}]
        """,
        FakeHimalayaBridge.key(for: .folderList(account: "work")): """
        [
          {"name":"INBOX","desc":"\\\\Inbox"},
          {"name":"Spam","desc":"\\\\Junk"}
        ]
        """,
        FakeHimalayaBridge.key(for: .envelopeList(
            folder: "INBOX",
            account: "work",
            query: "after 2026-03-01 order by date desc",
            page: 1,
            pageSize: 3
        )): """
        [
          {
            "id":"42",
            "flags":["Seen"],
            "subject":"Welcome",
            "from":{"name":"GitHub","addr":"noreply@github.com"},
            "to":{"name":"Ryan","addr":"ryan@example.com"},
            "date":"2026-05-01T10:00:00Z",
            "has_attachment":false
          }
        ]
        """,
        FakeHimalayaBridge.key(for: .envelopeList(
            folder: "INBOX",
            account: "work",
            query: "after 2026-03-01 order by date desc",
            page: 2,
            pageSize: 1
        )): "[]"
    ])
    let service = SyncService(
        bridge: fakeBridge,
        databaseQueue: databaseQueue,
        policy: SyncPolicy(initialPerFolderLimit: 3, incrementalPerFolderLimit: 2),
        now: { now }
    )

    let accounts = try await service.discoverAccounts()
    #expect(accounts.map(\.accountKey) == ["work"])
    #expect(accounts.map(\.isDefault) == [true])

    let folders = try await service.discoverFolders(accountKey: "work")
    #expect(folders.map(\.role) == [.normal, .junk])

    let count = try await service.syncWorkspace(.main)
    #expect(count == 1)

    let repository = MailRepository(databaseQueue: databaseQueue)
    let entities = try repository.entityList(workspace: .main)
    #expect(entities.map(\.displayName) == ["GitHub"])

    let commands = await fakeBridge.commands()
    #expect(commands.map(\.arguments).contains(
        HimalayaCommand.envelopeList(
            folder: "INBOX",
            account: "work",
            query: "after 2026-03-01 order by date desc",
            page: 1,
            pageSize: 3
        ).arguments
    ))
}

@Test
func discoverFoldersForDiscoveredAccountsAppliesConcurrencyLimits() async throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let fakeBridge = FakeHimalayaBridge(responses: [
        FakeHimalayaBridge.key(for: .accountList()): """
        [
          {"name":"a","backend":"imap","default":true},
          {"name":"b","backend":"imap","default":false},
          {"name":"c","backend":"imap","default":false}
        ]
        """,
        FakeHimalayaBridge.key(for: .folderList(account: "a")): """
        [{"name":"INBOX","desc":"\\\\Inbox"}]
        """,
        FakeHimalayaBridge.key(for: .folderList(account: "b")): """
        [{"name":"INBOX","desc":"\\\\Inbox"}]
        """,
        FakeHimalayaBridge.key(for: .folderList(account: "c")): """
        [{"name":"INBOX","desc":"\\\\Inbox"}]
        """
    ], delay: .milliseconds(25))
    let service = SyncService(
        bridge: fakeBridge,
        databaseQueue: databaseQueue,
        policy: SyncPolicy(
            maxConcurrentAccounts: 2,
            maxConcurrentHimalayaProcesses: 2
        )
    )

    let folders = try await service.discoverFoldersForDiscoveredAccounts()
    let stats = await fakeBridge.stats()

    #expect(folders.count == 3)
    #expect(stats.maxActiveProcesses == 2)
    #expect(stats.maxActiveAccounts == 2)
}

@Test
func syncServiceUsesCheckpointForIncrementalWindowAndCap() async throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([DiscoveredAccount(accountKey: "work")])
    try repository.upsertFolders([DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal)])
    let folder = try #require(try repository.folders(for: .main).first)
    let now = try #require(HimalayaDateParser.parse("2026-05-30T00:00:00Z"))
    let previousCheckpoint = try #require(HimalayaDateParser.parse("2026-05-20T12:00:00Z"))
    try repository.markAccountSyncSucceeded(accountKey: "work", workspace: .main, at: previousCheckpoint)

    let fakeBridge = FakeHimalayaBridge(responses: [
        FakeHimalayaBridge.key(for: .envelopeList(
            folder: "INBOX",
            account: "work",
            query: "after 2026-05-19 order by date desc",
            page: 1,
            pageSize: 2
        )): "[]"
    ])
    let service = SyncService(
        bridge: fakeBridge,
        databaseQueue: databaseQueue,
        policy: SyncPolicy(initialPerFolderLimit: 3, incrementalPerFolderLimit: 2),
        now: { now }
    )

    let count = try await service.syncWorkspace(.main)

    #expect(count == 0)
    let commands = await fakeBridge.commands()
    #expect(commands.map(\.arguments) == [
        HimalayaCommand.envelopeList(
            folder: "INBOX",
            account: "work",
            query: "after 2026-05-19 order by date desc",
            page: 1,
            pageSize: 2
        ).arguments
    ])
    #expect(try repository.lastSuccessfulSyncAt(
        accountKey: "work",
        folderID: folder.id,
        workspace: .main
    ) == now)
}

@Test
func syncFolderRecordsRunStartAsCheckpointAndRunFinishSeparately() async throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([DiscoveredAccount(accountKey: "work")])
    try repository.upsertFolders([DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal)])
    let folder = try #require(try repository.folders(for: .main).first)
    let startedAt = try #require(HimalayaDateParser.parse("2026-05-30T00:00:00Z"))
    let finishedAt = try #require(HimalayaDateParser.parse("2026-05-30T00:00:05Z"))
    let expectedQueryStart = try #require(HimalayaDateParser.parse("2026-03-01T00:00:00Z"))
    let fakeBridge = FakeHimalayaBridge(responses: [
        FakeHimalayaBridge.key(for: .envelopeList(
            folder: "INBOX",
            account: "work",
            query: "after 2026-03-01 order by date desc",
            page: 1,
            pageSize: 1
        )): "[]"
    ])
    let clock = SequenceClock([startedAt, finishedAt])
    let service = SyncService(
        bridge: fakeBridge,
        databaseQueue: databaseQueue,
        policy: SyncPolicy(initialPerFolderLimit: 1),
        now: { clock.next() }
    )

    _ = try await service.syncFolder(folder, workspace: .main)

    let checkpoint = try #require(try repository.syncCheckpoint(
        accountKey: "work",
        folderID: folder.id,
        workspace: .main
    ))
    #expect(checkpoint.lastSuccessfulSyncAt == startedAt)
    #expect(checkpoint.lastSuccessfulSyncStartedAt == startedAt)
    #expect(checkpoint.lastSuccessfulSyncFinishedAt == finishedAt)
    #expect(checkpoint.lastSuccessfulQueryStartAt == expectedQueryStart)
}

@Test
func incrementalSyncPagesUntilShortPageBeforeAdvancingCheckpoint() async throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([DiscoveredAccount(accountKey: "work")])
    try repository.upsertFolders([DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal)])
    let folder = try #require(try repository.folders(for: .main).first)
    let previousCheckpoint = try #require(HimalayaDateParser.parse("2026-05-20T12:00:00Z"))
    let startedAt = try #require(HimalayaDateParser.parse("2026-05-30T00:00:00Z"))
    let finishedAt = try #require(HimalayaDateParser.parse("2026-05-30T00:00:05Z"))
    let expectedOldestSyncedMessageDate = try #require(HimalayaDateParser.parse("2026-05-28T10:00:00Z"))
    try repository.markFolderSyncSucceeded(
        accountKey: "work",
        folderID: folder.id,
        workspace: .main,
        at: previousCheckpoint
    )

    let query = "after 2026-05-19 order by date desc"
    let fakeBridge = FakeHimalayaBridge(responses: [
        FakeHimalayaBridge.key(for: .envelopeList(
            folder: "INBOX",
            account: "work",
            query: query,
            page: 1,
            pageSize: 1
        )): """
        [
          {
            "id":"42",
            "flags":[],
            "subject":"First",
            "from":{"name":"GitHub","addr":"noreply@github.com"},
            "to":{"name":"Ryan","addr":"ryan@example.com"},
            "date":"2026-05-29T10:00:00Z",
            "has_attachment":false
          }
        ]
        """,
        FakeHimalayaBridge.key(for: .envelopeList(
            folder: "INBOX",
            account: "work",
            query: query,
            page: 2,
            pageSize: 1
        )): """
        [
          {
            "id":"43",
            "flags":[],
            "subject":"Second",
            "from":{"name":"GitHub","addr":"noreply@github.com"},
            "to":{"name":"Ryan","addr":"ryan@example.com"},
            "date":"2026-05-28T10:00:00Z",
            "has_attachment":false
          }
        ]
        """,
        FakeHimalayaBridge.key(for: .envelopeList(
            folder: "INBOX",
            account: "work",
            query: query,
            page: 3,
            pageSize: 1
        )): "[]"
    ])
    let clock = SequenceClock([startedAt, finishedAt])
    let service = SyncService(
        bridge: fakeBridge,
        databaseQueue: databaseQueue,
        policy: SyncPolicy(incrementalPerFolderLimit: 1),
        now: { clock.next() }
    )

    let count = try await service.syncFolder(folder, workspace: .main)

    #expect(count == 2)
    #expect(await fakeBridge.commands().map(\.arguments) == [
        HimalayaCommand.envelopeList(folder: "INBOX", account: "work", query: query, page: 1, pageSize: 1).arguments,
        HimalayaCommand.envelopeList(folder: "INBOX", account: "work", query: query, page: 2, pageSize: 1).arguments,
        HimalayaCommand.envelopeList(folder: "INBOX", account: "work", query: query, page: 3, pageSize: 1).arguments
    ])
    let checkpoint = try #require(try repository.syncCheckpoint(
        accountKey: "work",
        folderID: folder.id,
        workspace: .main
    ))
    #expect(checkpoint.lastSuccessfulSyncAt == startedAt)
    #expect(checkpoint.oldestSyncedMessageDate == expectedOldestSyncedMessageDate)
}

@Test
func fullHistorySyncPagesFromBeginningOfMailbox() async throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([DiscoveredAccount(accountKey: "work")])
    try repository.upsertFolders([DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal)])
    let now = try #require(HimalayaDateParser.parse("2026-05-30T00:00:00Z"))
    let fakeBridge = FakeHimalayaBridge(responses: [
        FakeHimalayaBridge.key(for: .envelopeList(
            folder: "INBOX",
            account: "work",
            query: "after 1970-01-01 order by date desc",
            page: 1,
            pageSize: 1
        )): """
        [
          {
            "id":"42",
            "flags":[],
            "subject":"Recent",
            "from":{"name":"GitHub","addr":"noreply@github.com"},
            "to":{"name":"Ryan","addr":"ryan@example.com"},
            "date":"2026-05-01T10:00:00Z",
            "has_attachment":false
          }
        ]
        """,
        FakeHimalayaBridge.key(for: .envelopeList(
            folder: "INBOX",
            account: "work",
            query: "after 1970-01-01 order by date desc",
            page: 2,
            pageSize: 1
        )): "[]"
    ])
    let service = SyncService(
        bridge: fakeBridge,
        databaseQueue: databaseQueue,
        policy: SyncPolicy(fullHistoryPerFolderPageSize: 1),
        now: { now }
    )

    let count = try await service.syncWorkspace(.main, fullHistory: true)

    #expect(count == 1)
    let commands = await fakeBridge.commands()
    #expect(commands.map(\.arguments) == [
        HimalayaCommand.envelopeList(
            folder: "INBOX",
            account: "work",
            query: "after 1970-01-01 order by date desc",
            page: 1,
            pageSize: 1
        ).arguments,
        HimalayaCommand.envelopeList(
            folder: "INBOX",
            account: "work",
            query: "after 1970-01-01 order by date desc",
            page: 2,
            pageSize: 1
        ).arguments
    ])
}

@Test
func entityHistorySyncFiltersBySenderAndRecipientWithoutAdvancingAccountCheckpoint() async throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([DiscoveredAccount(accountKey: "work")])
    try repository.upsertFolders([DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal)])
    let now = try #require(HimalayaDateParser.parse("2026-05-30T00:00:00Z"))
    let fromCommand = HimalayaCommand.envelopeList(
        folder: "INBOX",
        account: "work",
        query: "after 1970-01-01 and from alice@example.com order by date desc",
        page: 1,
        pageSize: 2
    )
    let toCommand = HimalayaCommand.envelopeList(
        folder: "INBOX",
        account: "work",
        query: "after 1970-01-01 and to alice@example.com order by date desc",
        page: 1,
        pageSize: 2
    )
    let fakeBridge = FakeHimalayaBridge(responses: [
        FakeHimalayaBridge.key(for: fromCommand): """
        [
          {
            "id":"42",
            "flags":[],
            "subject":"Hello",
            "from":{"name":"Alice","addr":"alice@example.com"},
            "to":{"name":"Ryan","addr":"ryan@example.com"},
            "date":"2026-05-01T10:00:00Z",
            "has_attachment":false
          }
        ]
        """,
        FakeHimalayaBridge.key(for: toCommand): "[]"
    ])
    let service = SyncService(
        bridge: fakeBridge,
        databaseQueue: databaseQueue,
        policy: SyncPolicy(fullHistoryPerFolderPageSize: 2),
        now: { now }
    )

    let count = try await service.syncEntityHistory(.main, emailAddresses: ["Alice@Example.com "])

    #expect(count == 1)
    #expect(try repository.entityList(workspace: .main).map(\.displayName) == ["Alice"])
    #expect(await fakeBridge.commands().map(\.arguments) == [
        fromCommand.arguments,
        toCommand.arguments
    ])
    #expect(try repository.lastSuccessfulSyncAt(accountKey: "work", folderID: 0, workspace: .main) == nil)
}

@Test
func syncWorkspaceCanTargetAccountsAndFolderRolesWithoutAdvancingAccountCheckpoint() async throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([
        DiscoveredAccount(accountKey: "a"),
        DiscoveredAccount(accountKey: "b")
    ])
    try repository.upsertFolders([
        DiscoveredFolder(accountKey: "a", providerName: "INBOX", role: .normal),
        DiscoveredFolder(accountKey: "a", providerName: "Sent", role: .sent),
        DiscoveredFolder(accountKey: "a", providerName: "Spam", role: .junk),
        DiscoveredFolder(accountKey: "b", providerName: "INBOX", role: .normal),
        DiscoveredFolder(accountKey: "b", providerName: "Sent", role: .sent)
    ])
    let now = try #require(HimalayaDateParser.parse("2026-05-30T00:00:00Z"))
    let fakeBridge = FakeHimalayaBridge(defaultResponse: "[]")
    let service = SyncService(
        bridge: fakeBridge,
        databaseQueue: databaseQueue,
        policy: SyncPolicy(
            initialPerFolderLimit: 1,
            incrementalPerFolderLimit: 1,
            maxConcurrentFoldersPerAccount: 1
        ),
        now: { now }
    )

    _ = try await service.syncWorkspace(
        .main,
        accountKeys: ["a"],
        folderRoles: [.normal, .sent]
    )

    let commands = await fakeBridge.commands()
    #expect(commands.map(\.arguments) == [
        HimalayaCommand.envelopeList(
            folder: "INBOX",
            account: "a",
            query: "after 2026-03-01 order by date desc",
            page: 1,
            pageSize: 1
        ).arguments,
        HimalayaCommand.envelopeList(
            folder: "Sent",
            account: "a",
            query: "after 2026-03-01 order by date desc",
            page: 1,
            pageSize: 1
        ).arguments
    ])
    #expect(try repository.lastSuccessfulSyncAt(
        accountKey: "a",
        folderID: 0,
        workspace: .main
    ) == nil)
}

@Test
func syncWorkspaceUsesAccountPriorityScoresAndMailboxPrecedence() async throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([
        DiscoveredAccount(accountKey: "a"),
        DiscoveredAccount(accountKey: "b"),
        DiscoveredAccount(accountKey: "c")
    ])
    try repository.upsertFolders([
        DiscoveredFolder(accountKey: "a", providerName: "Archive", role: .normal),
        DiscoveredFolder(accountKey: "a", providerName: "INBOX", role: .normal),
        DiscoveredFolder(accountKey: "b", providerName: "INBOX", role: .normal),
        DiscoveredFolder(accountKey: "c", providerName: "Sent", role: .sent)
    ])
    let now = try #require(HimalayaDateParser.parse("2026-05-30T00:00:00Z"))
    let fakeBridge = FakeHimalayaBridge(defaultResponse: "[]")
    let service = SyncService(
        bridge: fakeBridge,
        databaseQueue: databaseQueue,
        policy: SyncPolicy(
            initialPerFolderLimit: 1,
            incrementalPerFolderLimit: 1,
            maxConcurrentAccounts: 1,
            maxConcurrentFoldersPerAccount: 1
        ),
        now: { now }
    )

    _ = try await service.syncWorkspace(
        .main,
        accountPriorityScores: ["c": 10, "a": 5]
    )

    let commands = await fakeBridge.commands()
    #expect(commands.map(\.arguments) == [
        HimalayaCommand.envelopeList(
            folder: "Sent",
            account: "c",
            query: "after 2026-03-01 order by date desc",
            page: 1,
            pageSize: 1
        ).arguments,
        HimalayaCommand.envelopeList(
            folder: "INBOX",
            account: "a",
            query: "after 2026-03-01 order by date desc",
            page: 1,
            pageSize: 1
        ).arguments,
        HimalayaCommand.envelopeList(
            folder: "Archive",
            account: "a",
            query: "after 2026-03-01 order by date desc",
            page: 1,
            pageSize: 1
        ).arguments,
        HimalayaCommand.envelopeList(
            folder: "INBOX",
            account: "b",
            query: "after 2026-03-01 order by date desc",
            page: 1,
            pageSize: 1
        ).arguments
    ])
}

@Test
func syncWorkspaceRespectsAccountFolderAndProcessConcurrencyLimits() async throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([
        DiscoveredAccount(accountKey: "a"),
        DiscoveredAccount(accountKey: "b"),
        DiscoveredAccount(accountKey: "c")
    ])
    try repository.upsertFolders([
        DiscoveredFolder(accountKey: "a", providerName: "INBOX", role: .normal),
        DiscoveredFolder(accountKey: "a", providerName: "Sent", role: .sent),
        DiscoveredFolder(accountKey: "b", providerName: "INBOX", role: .normal),
        DiscoveredFolder(accountKey: "b", providerName: "Sent", role: .sent),
        DiscoveredFolder(accountKey: "c", providerName: "INBOX", role: .normal),
        DiscoveredFolder(accountKey: "c", providerName: "Sent", role: .sent)
    ])
    let now = try #require(HimalayaDateParser.parse("2026-05-30T00:00:00Z"))
    let fakeBridge = FakeHimalayaBridge(defaultResponse: "[]", delay: .milliseconds(25))
    let service = SyncService(
        bridge: fakeBridge,
        databaseQueue: databaseQueue,
        policy: SyncPolicy(
            initialPerFolderLimit: 1,
            incrementalPerFolderLimit: 1,
            maxConcurrentAccounts: 2,
            maxConcurrentFoldersPerAccount: 1,
            maxConcurrentHimalayaProcesses: 3
        ),
        now: { now }
    )

    _ = try await service.syncWorkspace(.main)
    let stats = await fakeBridge.stats()

    #expect(stats.maxActiveProcesses <= 3)
    #expect(stats.maxActiveAccounts <= 2)
    #expect(stats.maxActiveFoldersPerAccount.values.allSatisfy { $0 <= 1 })
}

@Test
func syncWorkspaceAppliesGlobalHimalayaProcessLimit() async throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([
        DiscoveredAccount(accountKey: "a"),
        DiscoveredAccount(accountKey: "b"),
        DiscoveredAccount(accountKey: "c")
    ])
    try repository.upsertFolders([
        DiscoveredFolder(accountKey: "a", providerName: "Archive", role: .normal),
        DiscoveredFolder(accountKey: "a", providerName: "INBOX", role: .normal),
        DiscoveredFolder(accountKey: "b", providerName: "Archive", role: .normal),
        DiscoveredFolder(accountKey: "b", providerName: "INBOX", role: .normal),
        DiscoveredFolder(accountKey: "c", providerName: "Archive", role: .normal),
        DiscoveredFolder(accountKey: "c", providerName: "INBOX", role: .normal)
    ])
    let now = try #require(HimalayaDateParser.parse("2026-05-30T00:00:00Z"))
    let fakeBridge = FakeHimalayaBridge(defaultResponse: "[]", delay: .milliseconds(25))
    let service = SyncService(
        bridge: fakeBridge,
        databaseQueue: databaseQueue,
        policy: SyncPolicy(
            initialPerFolderLimit: 1,
            incrementalPerFolderLimit: 1,
            maxConcurrentAccounts: 3,
            maxConcurrentFoldersPerAccount: 3,
            maxConcurrentHimalayaProcesses: 2
        ),
        now: { now }
    )

    _ = try await service.syncWorkspace(.main)
    let stats = await fakeBridge.stats()

    #expect(stats.maxActiveProcesses <= 2)
}

@Test
func syncWorkspaceContinuesWhenOneFolderHimalayaCommandFails() async throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([
        DiscoveredAccount(accountKey: "work")
    ])
    try repository.upsertFolders([
        DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal),
        DiscoveredFolder(accountKey: "work", providerName: "Archive", role: .normal)
    ])
    let now = try #require(HimalayaDateParser.parse("2026-05-30T00:00:00Z"))
    let fakeBridge = FakeHimalayaBridge(responses: [
        FakeHimalayaBridge.key(for: .envelopeList(
            folder: "INBOX",
            account: "work",
            query: "after 2026-03-01 order by date desc",
            page: 1,
            pageSize: 1
        )): """
        [
          {
            "id":"42",
            "flags":["Seen"],
            "subject":"Welcome",
            "from":{"name":"GitHub","addr":"noreply@github.com"},
            "to":{"name":"Ryan","addr":"ryan@example.com"},
            "date":"2026-05-01T10:00:00Z",
            "has_attachment":false
          }
        ]
        """,
        FakeHimalayaBridge.key(for: .envelopeList(
            folder: "INBOX",
            account: "work",
            query: "after 2026-03-01 order by date desc",
            page: 2,
            pageSize: 1
        )): "[]"
    ])
    let service = SyncService(
        bridge: fakeBridge,
        databaseQueue: databaseQueue,
        policy: SyncPolicy(
            initialPerFolderLimit: 1,
            incrementalPerFolderLimit: 1,
            maxConcurrentFoldersPerAccount: 1
        ),
        now: { now }
    )

    let result = try await service.syncWorkspaceResult(.main)

    #expect(result.syncedCount == 1)
    #expect(result.attemptedFolderCount == 2)
    #expect(result.hadFailure)
    let entities = try repository.entityList(workspace: .main)
    #expect(entities.map(\.displayName) == ["GitHub"])
    let folders = try repository.folders(for: .main)
    let inbox = try #require(folders.first { $0.providerName == "INBOX" })
    let archive = try #require(folders.first { $0.providerName == "Archive" })
    #expect(try repository.lastSuccessfulSyncAt(accountKey: "work", folderID: inbox.id, workspace: .main) != nil)
    #expect(try repository.lastSuccessfulSyncAt(accountKey: "work", folderID: archive.id, workspace: .main) == nil)
}

private final class SequenceClock: @unchecked Sendable {
    private let dates: [Date]
    private var index = 0

    init(_ dates: [Date]) {
        self.dates = dates
    }

    func next() -> Date {
        guard !dates.isEmpty else { return Date(timeIntervalSince1970: 0) }
        defer { index = min(index + 1, dates.count - 1) }
        return dates[index]
    }
}

private final class FakeHimalayaBridge: HimalayaBridge, @unchecked Sendable {
    private let state: FakeHimalayaBridgeState
    private let delay: Duration?

    init(
        responses: [String: String] = [:],
        defaultResponse: String? = nil,
        delay: Duration? = nil
    ) {
        self.state = FakeHimalayaBridgeState(responses: responses, defaultResponse: defaultResponse)
        self.delay = delay
    }

    func run(_ command: HimalayaCommand, timeout: TimeInterval?) async throws -> HimalayaResult {
        let stdout = await state.start(command)
        if let delay {
            try await Task.sleep(for: delay)
        }
        await state.finish(command)

        guard let stdout else {
            return HimalayaResult(
                command: command,
                exitCode: 1,
                stdoutData: Data(),
                stderrData: "missing fake response".data(using: .utf8)!,
                duration: 0
            )
        }

        return HimalayaResult(
            command: command,
            exitCode: 0,
            stdoutData: stdout.data(using: .utf8)!,
            stderrData: Data(),
            duration: 0
        )
    }

    func commands() async -> [HimalayaCommand] {
        await state.commands
    }

    func stats() async -> FakeHimalayaBridgeStats {
        await state.stats
    }

    static func key(for command: HimalayaCommand) -> String {
        command.arguments.joined(separator: "\u{1F}")
    }
}

private struct FakeHimalayaBridgeStats: Sendable {
    var maxActiveProcesses: Int
    var maxActiveAccounts: Int
    var maxActiveFoldersPerAccount: [String: Int]
}

private actor FakeHimalayaBridgeState {
    private let responses: [String: String]
    private let defaultResponse: String?
    private(set) var commands: [HimalayaCommand] = []
    private var activeProcesses = 0
    private var activeFoldersByAccount: [String: Int] = [:]
    private var maxActiveProcesses = 0
    private var maxActiveAccounts = 0
    private var maxActiveFoldersPerAccount: [String: Int] = [:]

    init(responses: [String: String], defaultResponse: String?) {
        self.responses = responses
        self.defaultResponse = defaultResponse
    }

    var stats: FakeHimalayaBridgeStats {
        FakeHimalayaBridgeStats(
            maxActiveProcesses: maxActiveProcesses,
            maxActiveAccounts: maxActiveAccounts,
            maxActiveFoldersPerAccount: maxActiveFoldersPerAccount
        )
    }

    func start(_ command: HimalayaCommand) -> String? {
        commands.append(command)
        activeProcesses += 1
        maxActiveProcesses = max(maxActiveProcesses, activeProcesses)

        if let accountKey = Self.trackedAccountKey(command) {
            activeFoldersByAccount[accountKey, default: 0] += 1
            maxActiveAccounts = max(maxActiveAccounts, activeFoldersByAccount.count)
            maxActiveFoldersPerAccount[accountKey] = max(
                maxActiveFoldersPerAccount[accountKey, default: 0],
                activeFoldersByAccount[accountKey, default: 0]
            )
        }

        return responses[FakeHimalayaBridge.key(for: command)] ?? defaultResponse
    }

    func finish(_ command: HimalayaCommand) {
        activeProcesses -= 1
        guard let accountKey = Self.trackedAccountKey(command) else {
            return
        }

        let activeCount = activeFoldersByAccount[accountKey, default: 0] - 1
        if activeCount > 0 {
            activeFoldersByAccount[accountKey] = activeCount
        } else {
            activeFoldersByAccount.removeValue(forKey: accountKey)
        }
    }

    private static func trackedAccountKey(_ command: HimalayaCommand) -> String? {
        guard (command.arguments.contains("envelope") || command.arguments.contains("folder")),
              command.arguments.contains("list"),
              let accountIndex = command.arguments.firstIndex(of: "--account"),
              command.arguments.indices.contains(accountIndex + 1)
        else {
            return nil
        }
        return command.arguments[accountIndex + 1]
    }
}
