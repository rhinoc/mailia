import Foundation
import Testing
@testable import MailiaCore

@Test
func appServerClientInitializesNoopsAndShutsDownFakeServer() async throws {
    let script = try makeFakeAppServerScript(body: """
    while IFS= read -r line; do
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
          printf '{"id":%s,"result":{"accounts":[{"name":"work","backend":"IMAP, SMTP","default":true,"emailAddress":"work@example.com","displayName":"Work"}]}}\\n' "$id"
          ;;
        *account*health*)
          printf '{"id":%s,"result":{"account":{"name":"work","backend":"IMAP, SMTP","default":true,"emailAddress":"work@example.com","displayName":"Work"},"status":"ok","issues":[]}}\\n' "$id"
          ;;
        *folder*list*)
          printf '{"id":%s,"result":{"folders":[{"name":"INBOX","desc":"Inbox"},{"name":"Archive"}]}}\\n' "$id"
          ;;
        *message*list*)
          printf '{"id":%s,"result":{"envelopes":[{"id":"body:2,S","flags":["seen"],"subject":"Body","from":{"name":"Sender","addr":"sender@example.com"},"to":{"name":"Recipient","addr":"recipient@example.net"},"date":"2026-05-30 06:10+00:00","has_attachment":true}]}}\\n' "$id"
          ;;
        *message*get*)
          printf '{"id":%s,"result":{"id":"body:2,S","text":"Plain body","html":"<p>HTML body</p>","has_attachment":false}}\\n' "$id"
          ;;
        *message*modify*)
          printf '{"id":%s,"result":{"id":"body","folder":"Archive"}}\\n' "$id"
          ;;
        *attachment*download*)
          printf '{"id":%s,"result":{"attachments":[{"id":"1","filename":"report.txt","path":"/tmp/report.txt","size":11}]}}\\n' "$id"
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
    defer { try? FileManager.default.removeItem(at: script) }

    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 2
    )

    let initialize = try await client.start()
    #expect(initialize == MailAppServerInitializeResult(serverName: "mailia-mail", protocolVersion: 1))

    try await client.noop()
    #expect(try await client.accountList() == [
        MailAppServerAccount(
            name: "work",
            backend: "IMAP, SMTP",
            isDefault: true,
            emailAddress: "work@example.com",
            displayName: "Work"
        )
    ])
    #expect(try await client.accountHealth(account: "work") == MailAppServerAccountHealthResult(
        account: MailAppServerAccount(
            name: "work",
            backend: "IMAP, SMTP",
            isDefault: true,
            emailAddress: "work@example.com",
            displayName: "Work"
        ),
        status: .ok,
        issues: []
    ))
    #expect(try await client.folderList(account: "work") == [
        MailAppServerFolder(name: "INBOX", desc: "Inbox"),
        MailAppServerFolder(name: "Archive", desc: nil)
    ])
    #expect(try await client.messageList(
        folder: "INBOX",
        account: "work",
        query: "after 2026-05-30 order by date desc",
        page: 1,
        pageSize: 1
    ) == [
        MailAppServerMessageEnvelope(
            id: "body:2,S",
            flags: ["seen"],
            subject: "Body",
            from: MailAppServerMessageAddress(name: "Sender", addr: "sender@example.com"),
            to: MailAppServerMessageAddress(name: "Recipient", addr: "recipient@example.net"),
            date: "2026-05-30 06:10+00:00",
            hasAttachment: true
        )
    ])
    #expect(try await client.messageGet(
        id: "body:2,S",
        folder: "INBOX",
        account: "work"
    ) == MailAppServerMessageGetResult(
        id: "body:2,S",
        text: "Plain body",
        html: "<p>HTML body</p>",
        hasAttachment: false
    ))
    #expect(try await client.messageModify(
        id: "body",
        folder: "INBOX",
        account: "work",
        addFlags: ["seen"],
        moveTo: "Archive"
    ) == MailAppServerMessageModifyResult(id: "body", folder: "Archive"))
    #expect(try await client.attachmentDownload(
        messageID: "body",
        folder: "INBOX",
        account: "work",
        downloadsDirectory: URL(fileURLWithPath: "/tmp")
    ) == [
        MailAppServerDownloadedAttachment(
            id: "1",
            filename: "report.txt",
            path: "/tmp/report.txt",
            size: 11
        )
    ])
    #expect(try await client.messageSend(
        raw: "From: sender@example.com\nTo: recipient@example.net\n\nHello",
        account: "work"
    ) == MailAppServerMessageSendResult(sent: true))
    try await client.shutdown()
}

@Test
func appServerClientSurfacesRpcErrors() async throws {
    let script = try makeFakeAppServerScript(body: """
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      method=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p')
      if [ "$method" = "initialize" ]; then
        printf '{"id":%s,"result":{"serverName":"mailia-mail","protocolVersion":1}}\\n' "$id"
      else
        printf '{"id":%s,"error":{"code":"not_initialized","message":"boom","retryable":true}}\\n' "$id"
      fi
    done
    """)
    defer { try? FileManager.default.removeItem(at: script) }

    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 2
    )
    _ = try await client.start()

    await #expect(throws: MailAppServerError.rpcError(
        code: "not_initialized",
        message: "boom",
        retryable: true
    )) {
        try await client.noop()
    }
}

@Test
func appServerClientRpcErrorDescriptionRedactsSensitiveMessage() {
    let error = MailAppServerError.rpcError(
        code: "internal",
        message: "Unable to resolve legacy keyring secret work-imap-oauth2-access-token for account `work` at /Users/example/Library/Application Support/himalaya/config.toml using sender@example.com",
        retryable: true
    )
    let description = error.localizedDescription

    #expect(description == "Mailia app-server returned internal: details redacted")
    #expect(!description.contains("work-imap-oauth2-access-token"))
    #expect(!description.contains("account `work`"))
    #expect(!description.contains("/Users/example"))
    #expect(!description.contains("config.toml"))
    #expect(!description.contains("sender@example.com"))
}

@Test
func appServerErrorClassifiesMessageLocationFailuresForTiming() {
    let missingMessage = MailAppServerError.rpcError(
        code: "invalid_request",
        message: "Message `123` was not found in folder `INBOX` for account `work`",
        retryable: nil
    )
    let invalidFolder = MailAppServerError.rpcError(
        code: "invalid_request",
        message: "Invalid folder `Old Inbox` for account `work`",
        retryable: nil
    )
    let retryable = MailAppServerError.rpcError(
        code: "internal",
        message: "backend unavailable",
        retryable: true
    )

    #expect(missingMessage.timingErrorKind == "message_not_found")
    #expect(missingMessage.marksMessageLocationMissing)
    #expect(invalidFolder.timingErrorKind == "invalid_folder")
    #expect(invalidFolder.marksMessageLocationMissing)
    #expect(retryable.timingErrorKind == "rpc_retryable")
    #expect(!retryable.marksMessageLocationMissing)
}

@Test
func appServerRequestMetricParsesRustStderrLine() {
    let metric = AppServerRequestMetric.parse(
        "mailia-mail: request method=message/get status=ok duration_ms=37 config_load_count=2 auth_refresh_count=1"
    )

    #expect(metric == AppServerRequestMetric(
        method: "message/get",
        status: "ok",
        durationMilliseconds: 37,
        configLoadCount: 2,
        authRefreshCount: 1
    ))
    #expect(AppServerRequestMetric.parse("mailia-mail: stopped") == nil)
}

@Test
func appServerRequestTimingFieldsIncludeBackendMetricsAndErrorCode() {
    let metric = AppServerRequestMetric(
        method: "message/get",
        status: "error",
        durationMilliseconds: 82,
        configLoadCount: 3,
        authRefreshCount: 1
    )
    let line = MailiaTiming.formatLine(
        operation: "app_server.request",
        durationMilliseconds: 94,
        status: "failure",
        fields: [
            .label("method", "message_get")
        ] + MailAppServerRequestTiming.fields(
            for: metric,
            outcome: "remote_not_found",
            errorCode: "invalid_request"
        )
    )

    #expect(line == "MailiaTiming operation=app_server.request duration_ms=94 status=failure method=message_get outcome=remote_not_found error_code=invalid_request backend_status=error backend_duration_ms=82 config_load_count=3 auth_refresh_count=1")
}

@Test
func appServerClientIgnoresUnmatchedStringIDResponses() async throws {
    let script = try makeFakeAppServerScript(body: """
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      method=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p')
      if [ "$method" = "initialize" ]; then
        printf '{"id":"parse_error","error":{"code":"parse_error","message":"bad frame"}}\\n'
        printf '{"id":%s,"result":{"serverName":"mailia-mail","protocolVersion":1}}\\n' "$id"
      elif [ "$method" = "shutdown" ]; then
        printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
        exit 0
      else
        printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
      fi
    done
    """)
    defer { try? FileManager.default.removeItem(at: script) }

    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 2
    )

    let initialize = try await client.start()
    #expect(initialize == MailAppServerInitializeResult(serverName: "mailia-mail", protocolVersion: 1))
    try await client.noop()
    try await client.shutdown()
}

@Test
func appServerClientRepeatedStartReturnsCachedInitializeWithoutNoop() async throws {
    let requestLog = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailia-app-server-client-requests-\(UUID().uuidString).jsonl")
    let script = try makeFakeAppServerScript(body: """
    log_file="$1"
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> "$log_file"
      id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      method=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p')
      case "$method" in
        initialize)
          printf '{"id":%s,"result":{"serverName":"mailia-mail","protocolVersion":1}}\\n' "$id"
          ;;
        *noop*)
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
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
    defer {
        try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: requestLog)
    }

    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path, requestLog.path],
        defaultTimeout: 2
    )

    let firstInitialize = try await client.start()
    let secondInitialize = try await client.start()
    try await client.shutdown()

    #expect(firstInitialize == MailAppServerInitializeResult(serverName: "mailia-mail", protocolVersion: 1))
    #expect(secondInitialize == firstInitialize)
    #expect(try readClientAppServerMethods(from: requestLog) == ["initialize", "shutdown"])
}

@Test
func appServerClientFailsPendingRequestsWhenServerExits() async throws {
    let script = try makeFakeAppServerScript(body: """
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      method=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p')
      if [ "$method" = "initialize" ]; then
        printf '{"id":%s,"result":{"serverName":"mailia-mail","protocolVersion":1}}\\n' "$id"
      else
        printf 'fatal synthetic app-server exit\\n' >&2
        exit 42
      fi
    done
    """)
    defer { try? FileManager.default.removeItem(at: script) }

    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 2
    )
    _ = try await client.start()

    await #expect(throws: MailAppServerError.serverExited(
        status: 42,
        stderr: "fatal synthetic app-server exit\n"
    )) {
        try await client.noop()
    }
}

@Test
func appServerClientServerExitedDescriptionDoesNotExposeRawStderr() {
    let error = MailAppServerError.serverExited(
        status: 42,
        stderr: "fatal for account `work` at /Users/example/Library/Application Support/himalaya/config.toml using work-imap-oauth2-access-token\n"
    )
    let description = error.localizedDescription

    #expect(description.contains("status 42"))
    #expect(description.contains("Stderr output was captured."))
    #expect(!description.contains("account `work`"))
    #expect(!description.contains("/Users/example"))
    #expect(!description.contains("config.toml"))
    #expect(!description.contains("work-imap-oauth2-access-token"))
}

@Test
func appServerClientCanRestartAfterServerExits() async throws {
    let stateDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailia-app-server-restart-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    let script = try makeFakeAppServerScript(body: """
    state_dir="$1"
    crashed_marker="$state_dir/crashed"
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      method=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p')
      case "$method" in
        initialize)
          printf '{"id":%s,"result":{"serverName":"mailia-mail","protocolVersion":1}}\\n' "$id"
          ;;
        *noop*)
          if [ ! -f "$crashed_marker" ]; then
            printf 'fatal synthetic app-server exit\\n' >&2
            touch "$crashed_marker"
            exit 42
          fi
          printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
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
    defer {
        try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: stateDirectory)
    }

    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path, stateDirectory.path],
        defaultTimeout: 2
    )

    _ = try await client.start()
    await #expect(throws: MailAppServerError.serverExited(
        status: 42,
        stderr: "fatal synthetic app-server exit\n"
    )) {
        try await client.noop()
    }

    let restarted = try await client.start()
    #expect(restarted == MailAppServerInitializeResult(serverName: "mailia-mail", protocolVersion: 1))
    try await client.noop()
    try await client.shutdown()
}

@Test
func appServerClientCleansUpTimedOutRequestsAndKeepsConnectionUsable() async throws {
    let script = try makeFakeAppServerScript(body: """
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      method=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p')
      if [ "$method" = "initialize" ]; then
        printf '{"id":%s,"result":{"serverName":"mailia-mail","protocolVersion":1}}\\n' "$id"
      elif [ "$method" = "server/noop" ] || [ "$method" = "server\\/noop" ]; then
        # Intentionally keep the request pending while continuing to read later requests.
        :
      elif [ "$method" = "shutdown" ]; then
        printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
        exit 0
      else
        printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
      fi
    done
    """)
    defer { try? FileManager.default.removeItem(at: script) }

    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 2
    )
    _ = try await client.start()

    await #expect(throws: MailAppServerError.timedOut(method: "server/noop", timeout: 0.05)) {
        try await client.noop(timeout: 0.05)
    }
    try await client.shutdown(timeout: 2)
}

@Test
func appServerClientCleansUpCancelledRequestsAndKeepsConnectionUsable() async throws {
    let script = try makeFakeAppServerScript(body: """
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      method=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p')
      if [ "$method" = "initialize" ]; then
        printf '{"id":%s,"result":{"serverName":"mailia-mail","protocolVersion":1}}\\n' "$id"
      elif [ "$method" = "server/noop" ] || [ "$method" = "server\\/noop" ]; then
        # Intentionally keep the request pending while continuing to read later requests.
        :
      elif [ "$method" = "shutdown" ]; then
        printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
        exit 0
      else
        printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
      fi
    done
    """)
    defer { try? FileManager.default.removeItem(at: script) }

    let client = MailAppServerClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        defaultTimeout: 2
    )
    _ = try await client.start()

    let task = Task {
        try await client.noop(timeout: 2)
    }
    try await Task.sleep(for: .milliseconds(50))
    task.cancel()

    do {
        try await task.value
        Issue.record("Expected cancelled app-server request to throw CancellationError.")
    } catch is CancellationError {
    }

    try await client.shutdown(timeout: 2)
}

private func makeFakeAppServerScript(body: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailia-app-server-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("fake-server.sh")
    try """
    #!/bin/sh
    \(body)
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

private func readClientAppServerMethods(from url: URL) throws -> [String] {
    let lines = try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)

    return try lines.map { line in
        let data = Data(line.utf8)
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = object["method"] as? String
        else {
            throw NSError(
                domain: "ClientAppServerRequest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid recorded app-server request: \(line)"]
            )
        }
        return method
    }
}
