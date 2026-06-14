import Foundation
import Testing
@testable import MailiaCore

@Test
func syncPolicyDefaultsAllowTwoFoldersPerAccount() {
    #expect(SyncPolicy().maxConcurrentFoldersPerAccount == 2)
}

@Test
func syncServiceDiscoversAndSyncsBoundedEnvelopesWithAppServer() async throws {
    let logFile = temporaryLogFile()
    let script = try makeSyncFakeAppServerScript(logFile: logFile)
    defer {
        try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: logFile)
    }

    let databaseQueue = try DatabaseSchemaInspector.makeInMemoryDatabase()
    let now = try #require(HimalayaDateParser.parse("2026-05-30T00:00:00Z"))
    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 2
    )
    let service = SyncService(
        appServerClient: client,
        databaseQueue: databaseQueue,
        policy: SyncPolicy(initialPerFolderLimit: 3, incrementalPerFolderLimit: 2),
        now: { now }
    )

    do {
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
        #expect(try readLoggedMethods(from: logFile).contains("message/list"))
        try await client.shutdown()
    } catch {
        try? await client.shutdown()
        throw error
    }
}

@Test
func refreshFolderDiscoveryAlwaysRefreshesKnownFolders() async throws {
    let logFile = temporaryLogFile()
    let script = try makeSyncFakeAppServerScript(logFile: logFile)
    defer {
        try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: logFile)
    }

    let databaseQueue = try DatabaseSchemaInspector.makeInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([DiscoveredAccount(accountKey: "work")])
    try repository.replaceDiscoveredFolders(accountKey: "work", folders: [
        DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal)
    ])

    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 2
    )
    let service = SyncService(
        appServerClient: client,
        databaseQueue: databaseQueue,
        now: Date.init
    )

    let folders = try await service.discoverFoldersForRefresh()
    #expect(folders.map(\.providerName) == ["INBOX", "Spam"])
    let methods = try readLoggedMethods(from: logFile)
    #expect(methods.contains("account/list"))
    #expect(methods.contains("folder/list"))
    try await client.shutdown()
}

@Test
func refreshFolderDiscoveryRunsWhenKnownFoldersAreEmpty() async throws {
    let logFile = temporaryLogFile()
    let script = try makeSyncFakeAppServerScript(logFile: logFile)
    defer {
        try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: logFile)
    }

    let databaseQueue = try DatabaseSchemaInspector.makeInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([DiscoveredAccount(accountKey: "work")])

    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 2
    )
    let service = SyncService(
        appServerClient: client,
        databaseQueue: databaseQueue,
        now: Date.init
    )

    do {
        let folders = try await service.discoverFoldersForRefresh()
        #expect(folders.map(\.providerName) == ["INBOX", "Spam"])
        let methods = try readLoggedMethods(from: logFile)
        #expect(methods.contains("account/list"))
        #expect(methods.contains("folder/list"))
        try await client.shutdown()
    } catch {
        try? await client.shutdown()
        throw error
    }
}

@Test
func syncWorkspaceDiscoversFoldersWhenCacheIsEmpty() async throws {
    let logFile = temporaryLogFile()
    let script = try makeSyncFakeAppServerScript(logFile: logFile)
    defer {
        try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: logFile)
    }

    let databaseQueue = try DatabaseSchemaInspector.makeInMemoryDatabase()
    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 2
    )
    let service = SyncService(
        appServerClient: client,
        databaseQueue: databaseQueue,
        now: Date.init
    )

    do {
        let result = try await service.syncWorkspaceResult(.main)
        #expect(result.syncedCount == 1)
        #expect(result.attemptedFolderCount == 1)
        #expect(!result.hadFailure)

        let repository = MailRepository(databaseQueue: databaseQueue)
        #expect(try repository.folders().map(\.providerName) == ["INBOX", "Spam"])
        let methods = try readLoggedMethods(from: logFile)
        #expect(methods.contains("account/list"))
        #expect(methods.contains("folder/list"))
        #expect(methods.contains("message/list"))
        try await client.shutdown()
    } catch {
        try? await client.shutdown()
        throw error
    }
}

@Test
func incrementalSyncPagesUntilShortPageBeforeAdvancingCheckpoint() async throws {
    let logFile = temporaryLogFile()
    let script = try makeSyncFakeAppServerScript(logFile: logFile, pageMode: .twoPagesThenEmpty)
    defer {
        try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: logFile)
    }

    let databaseQueue = try DatabaseSchemaInspector.makeInMemoryDatabase()
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

    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 2
    )
    let clock = SequenceClock([startedAt, finishedAt])
    let service = SyncService(
        appServerClient: client,
        databaseQueue: databaseQueue,
        policy: SyncPolicy(incrementalPerFolderLimit: 1),
        now: { clock.next() }
    )

    do {
        let count = try await service.syncFolder(folder, workspace: .main)
        #expect(count == 2)
        #expect(try readLoggedMethods(from: logFile).filter { $0 == "message/list" }.count == 3)

        let checkpoint = try #require(try repository.syncCheckpoint(
            accountKey: "work",
            folderID: folder.id,
            workspace: .main
        ))
        #expect(checkpoint.lastSuccessfulSyncAt == startedAt)
        #expect(checkpoint.lastSuccessfulSyncFinishedAt == finishedAt)
        #expect(checkpoint.oldestSyncedMessageDate == expectedOldestSyncedMessageDate)
        try await client.shutdown()
    } catch {
        try? await client.shutdown()
        throw error
    }
}

@Test
func syncWorkspaceContinuesWhenOneFolderAppServerRequestFails() async throws {
    let script = try makeSyncFakeAppServerScript(failArchiveList: true)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

    let databaseQueue = try DatabaseSchemaInspector.makeInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([DiscoveredAccount(accountKey: "work")])
    try repository.upsertFolders([
        DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal),
        DiscoveredFolder(accountKey: "work", providerName: "Archive", role: .normal)
    ])
    let now = try #require(HimalayaDateParser.parse("2026-05-30T00:00:00Z"))
    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 2
    )
    let service = SyncService(
        appServerClient: client,
        databaseQueue: databaseQueue,
        policy: SyncPolicy(
            initialPerFolderLimit: 1,
            incrementalPerFolderLimit: 1,
            maxConcurrentFoldersPerAccount: 1
        ),
        now: { now }
    )

    do {
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
        try await client.shutdown()
    } catch {
        try? await client.shutdown()
        throw error
    }
}

@Test
func appServerRequestLimiterRunsHigherPriorityWaiterFirst() async throws {
    let limiter = MailAppServerRequestLimiter(maxConcurrentRequests: 1)
    let recorder = RequestOrderRecorder()

    let backgroundStarted = AsyncStream<Void>.makeStream()
    let releaseBackground = AsyncStream<Void>.makeStream()
    let background = Task {
        try await limiter.run(priority: .backgroundSync) {
            backgroundStarted.continuation.yield()
            for await _ in releaseBackground.stream {
                break
            }
            await recorder.record("background")
        }
    }

    _ = await backgroundStarted.stream.first(where: { _ in true })
    let low = Task {
        try await limiter.run(priority: .backgroundSync) {
            await recorder.record("low")
        }
    }
    let high = Task {
        try await limiter.run(priority: .interactive) {
            await recorder.record("high")
        }
    }

    releaseBackground.continuation.yield()
    try await background.value
    try await low.value
    try await high.value

    #expect(await recorder.values == ["background", "high", "low"])
}

@Test
func appServerRequestLimiterReservesPermitForVisibleBody() async throws {
    let limiter = MailAppServerRequestLimiter(maxConcurrentRequests: 3)
    let recorder = RequestOrderRecorder()
    let releaseBackground = AsyncStream<Void>.makeStream()
    let releaseVisible = AsyncStream<Void>.makeStream()

    let backgroundTasks = (1...3).map { index in
        Task {
            try await limiter.run(priority: .backgroundSync) {
                await recorder.record("background-\(index)-started")
                for await _ in releaseBackground.stream {
                    break
                }
                await recorder.record("background-\(index)-finished")
            }
        }
    }

    await waitUntil {
        let values = await recorder.values
        return values.contains("background-1-started")
            && values.contains("background-2-started")
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(await recorder.values.contains("background-3-started") == false)

    let visible = Task {
        try await limiter.run(priority: .visibleBody) {
            await recorder.record("visible-started")
            for await _ in releaseVisible.stream {
                break
            }
            await recorder.record("visible-finished")
        }
    }

    await waitUntil {
        let values = await recorder.values
        return values.contains("visible-started")
    }
    #expect(await recorder.values.contains("visible-started"))
    #expect(await recorder.values.contains("background-3-started") == false)

    releaseVisible.continuation.yield()
    try await visible.value
    #expect(await recorder.values.contains("background-3-started") == false)

    releaseBackground.continuation.yield()
    releaseBackground.continuation.yield()
    try await backgroundTasks[0].value
    try await backgroundTasks[1].value

    await waitUntil {
        let values = await recorder.values
        return values.contains("background-3-started")
    }
    releaseBackground.continuation.yield()
    try await backgroundTasks[2].value
}

private enum SyncFakePageMode {
    case onePage
    case twoPagesThenEmpty
}

private func makeSyncFakeAppServerScript(
    logFile: URL? = nil,
    pageMode: SyncFakePageMode = .onePage,
    failArchiveList: Bool = false
) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailia-sync-app-server-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("fake-server.sh")
    let logLine = logFile.map { "printf '%s\\n' \"$line\" >> '\($0.path)'" } ?? ":"
    let twoPageMode = pageMode == .twoPagesThenEmpty ? "1" : "0"
    let archiveFailure = failArchiveList ? "1" : "0"
    try """
    #!/bin/sh
    while IFS= read -r line; do
      \(logLine)
      id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      method=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p')
      page=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"page":\\([0-9][0-9]*\\).*/\\1/p')
      folder=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"folder":"\\([^"]*\\)".*/\\1/p')
      case "$method" in
        initialize)
          printf '{"id":%s,"result":{"serverName":"mailia-mail","protocolVersion":1}}\\n' "$id"
          ;;
        *noop*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          ;;
        *account*list*)
          printf '{"id":%s,"result":{"accounts":[{"name":"work","backend":"imap","default":true,"emailAddress":"ryan@example.com","displayName":"Ryan"}]}}\\n' "$id"
          ;;
        *folder*list*)
          printf '{"id":%s,"result":{"folders":[{"name":"INBOX","desc":"\\\\\\\\Inbox"},{"name":"Spam","desc":"\\\\\\\\Junk"}]}}\\n' "$id"
          ;;
        *message*list*)
          if [ "\(archiveFailure)" = "1" ] && [ "$folder" = "Archive" ]; then
            printf '{"id":%s,"error":{"code":"synthetic_failure","message":"archive unavailable","retryable":true}}\\n' "$id"
          elif [ "\(twoPageMode)" = "1" ]; then
            case "$page" in
              1)
                printf '{"id":%s,"result":{"envelopes":[{"id":"42","flags":[],"subject":"First","from":{"name":"GitHub","addr":"noreply@github.com"},"to":{"name":"Ryan","addr":"ryan@example.com"},"date":"2026-05-29T10:00:00Z","has_attachment":false}]}}\\n' "$id"
                ;;
              2)
                printf '{"id":%s,"result":{"envelopes":[{"id":"43","flags":[],"subject":"Second","from":{"name":"GitHub","addr":"noreply@github.com"},"to":{"name":"Ryan","addr":"ryan@example.com"},"date":"2026-05-28T10:00:00Z","has_attachment":false}]}}\\n' "$id"
                ;;
              *)
                printf '{"id":%s,"result":{"envelopes":[]}}\\n' "$id"
                ;;
            esac
          elif [ "$page" = "2" ]; then
            printf '{"id":%s,"result":{"envelopes":[]}}\\n' "$id"
          else
            printf '{"id":%s,"result":{"envelopes":[{"id":"42","flags":["Seen"],"subject":"Welcome","from":{"name":"GitHub","addr":"noreply@github.com"},"to":{"name":"Ryan","addr":"ryan@example.com"},"date":"2026-05-01T10:00:00Z","has_attachment":false}]}}\\n' "$id"
          fi
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
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

private func temporaryLogFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("mailia-sync-app-server-\(UUID().uuidString).jsonl")
}

private func readLoggedMethods(from url: URL) throws -> [String] {
    guard FileManager.default.fileExists(atPath: url.path) else {
        return []
    }
    let data = try Data(contentsOf: url)
    return try data.split(separator: UInt8(ascii: "\n")).compactMap { line in
        guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
            return nil
        }
        return object["method"] as? String
    }
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 500_000_000,
    predicate: @escaping () async -> Bool
) async {
    let startedAt = DispatchTime.now().uptimeNanoseconds
    while !(await predicate()),
          DispatchTime.now().uptimeNanoseconds - startedAt < timeoutNanoseconds {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
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

private actor RequestOrderRecorder {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}
