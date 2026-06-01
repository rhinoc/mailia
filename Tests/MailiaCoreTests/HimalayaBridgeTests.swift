import Foundation
import Testing
@testable import MailiaCore

@Test
func buildsAccountAndFolderCommands() {
    #expect(HimalayaCommand.accountList().arguments == [
        "--output", "json", "--quiet",
        "account", "list"
    ])

    #expect(HimalayaCommand.folderList(account: "work").arguments == [
        "--output", "json", "--quiet",
        "folder", "list", "--account", "work"
    ])
}

@Test
func buildsEnvelopeListCommand() {
    let command = HimalayaCommand.envelopeList(
        folder: "Archive",
        account: "work",
        query: "subject invoice order by date desc",
        page: 2,
        pageSize: 50
    )

    #expect(command.arguments == [
        "--output", "json", "--quiet",
        "envelope", "list",
        "--folder", "Archive",
        "--page", "2",
        "--page-size", "50",
        "--account", "work",
        "subject", "invoice", "order", "by", "date", "desc"
    ])
}

@Test
func buildsMessageMutationAndAttachmentCommands() {
    #expect(HimalayaCommand.flagSeen(id: "42", folder: "INBOX", account: "work").arguments == [
        "--output", "json", "--quiet",
        "flag", "add", "--folder", "INBOX", "--account", "work", "42", "seen"
    ])

    #expect(HimalayaCommand.flagAdd(id: "42", flag: "flagged", folder: "INBOX", account: "work").arguments == [
        "--output", "json", "--quiet",
        "flag", "add", "--folder", "INBOX", "--account", "work", "42", "flagged"
    ])

    #expect(HimalayaCommand.flagRemove(id: "42", flag: "flagged", folder: "INBOX", account: "work").arguments == [
        "--output", "json", "--quiet",
        "flag", "remove", "--folder", "INBOX", "--account", "work", "42", "flagged"
    ])

    #expect(HimalayaCommand.messageMove(id: "42", from: "INBOX", to: "Archive").arguments == [
        "--output", "json", "--quiet",
        "message", "move", "--folder", "INBOX", "Archive", "42"
    ])

    #expect(HimalayaCommand.messageExport(
        id: "42",
        folder: "INBOX",
        account: "work",
        destination: URL(fileURLWithPath: "/tmp/mailia-export")
    ).arguments == [
        "--output", "json", "--quiet",
        "message", "export",
        "--folder", "INBOX",
        "--destination", "/tmp/mailia-export",
        "--account", "work",
        "42"
    ])

    #expect(HimalayaCommand.attachmentDownload(
        messageID: "42",
        folder: "INBOX",
        account: "work",
        downloadsDirectory: URL(fileURLWithPath: "/tmp/mailia-downloads")
    ).arguments == [
        "--output", "json", "--quiet",
        "attachment", "download",
        "--folder", "INBOX",
        "--account", "work",
        "--downloads-dir", "/tmp/mailia-downloads",
        "42"
    ])

    #expect(HimalayaCommand.templateReply(
        id: "42",
        body: "Thanks, received.",
        folder: "INBOX",
        account: "work",
        replyAll: true
    ).arguments == [
        "--output", "json", "--quiet",
        "template", "reply",
        "--folder", "INBOX",
        "--all",
        "--account", "work",
        "42",
        "Thanks, received."
    ])

    #expect(HimalayaCommand.templateWrite(
        body: "Hello there",
        headers: ["To:friend@example.com", "Subject:Hello"],
        account: "work"
    ).arguments == [
        "--output", "json", "--quiet",
        "template", "write",
        "--header", "To:friend@example.com",
        "--header", "Subject:Hello",
        "--account", "work",
        "Hello there"
    ])

    let sendTemplateCommand = HimalayaCommand.templateSend(
        template: "From: me@example.com\n\nHello",
        account: "work"
    )
    #expect(sendTemplateCommand.arguments == [
        "--output", "json", "--quiet",
        "template", "send",
        "--account", "work"
    ])
    #expect(sendTemplateCommand.standardInput == Data("From: me@example.com\n\nHello".utf8))

    let sendMessageCommand = HimalayaCommand.messageSend(
        message: "From: me@example.com\r\n\r\nHello",
        account: "work"
    )
    #expect(sendMessageCommand.arguments == [
        "--output", "json", "--quiet",
        "message", "send",
        "--account", "work"
    ])
    #expect(sendMessageCommand.standardInput == Data("From: me@example.com\r\n\r\nHello".utf8))
}

@Test
func decodesJSONFromResultStdout() throws {
    struct Payload: Decodable, Equatable {
        var name: String
    }

    let result = HimalayaResult(
        command: .accountList(),
        exitCode: 0,
        stdoutData: #"{"name":"work"}"#.data(using: .utf8)!,
        stderrData: Data(),
        duration: 0.01
    )

    #expect(try result.decodeJSON(as: Payload.self) == Payload(name: "work"))
}

@Test
func nonZeroExitErrorDescriptionIncludesHimalayaOutput() {
    let result = HimalayaResult(
        command: .templateSend(template: "bad", account: "work"),
        exitCode: 1,
        stdoutData: Data(),
        stderrData: "Error: cannot parse template".data(using: .utf8)!,
        duration: 0.01
    )

    let error = HimalayaError.nonZeroExit(result)

    #expect(error.localizedDescription.contains("Himalaya exited with status 1"))
    #expect(error.localizedDescription.contains("cannot parse template"))
}

@Test
func processBridgeCapturesOutputAndDuration() async throws {
    let bridge = ProcessHimalayaBridge(executableURL: URL(fileURLWithPath: "/bin/sh"))
    let result = try await bridge.run(
        HimalayaCommand(arguments: ["-c", "printf stdout; printf stderr >&2"]),
        timeout: 2
    )

    #expect(result.succeeded)
    #expect(result.stdout == "stdout")
    #expect(result.stderr == "stderr")
    #expect(result.duration >= 0)
}

@Test
func processBridgeDrainsLargeStdoutAndStderrConcurrently() async throws {
    let bridge = ProcessHimalayaBridge(executableURL: URL(fileURLWithPath: "/bin/sh"))
    let chunk = String(repeating: "x", count: 1024)
    let repetitions = 256
    let script = """
    chunk='\(chunk)'; i=0; while [ $i -lt \(repetitions) ]; do printf "%s" "$chunk"; printf "%s" "$chunk" >&2; i=$((i + 1)); done
    """

    let result = try await bridge.run(
        HimalayaCommand(arguments: ["-c", script]),
        timeout: 5
    )

    #expect(result.succeeded)
    #expect(result.stdoutData.count == chunk.utf8.count * repetitions)
    #expect(result.stderrData.count == chunk.utf8.count * repetitions)
}

@Test
func processBridgeTerminatesCancellableReadCommandWhenTaskIsCancelled() async throws {
    let scriptURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailia-cancellable-read-\(UUID().uuidString).sh")
    try """
    #!/bin/sh
    sleep 5
    """.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: scriptURL.path
    )
    defer {
        try? FileManager.default.removeItem(at: scriptURL)
    }

    let bridge = ProcessHimalayaBridge(executableURL: scriptURL)
    let startedAt = Date()
    let task = Task {
        try await bridge.run(
            .messageExport(
                id: "42",
                destination: FileManager.default.temporaryDirectory
                    .appendingPathComponent("mailia-cancel-test", isDirectory: true)
            ),
            timeout: 10
        )
    }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()

    do {
        _ = try await task.value
    } catch is CancellationError {
    }

    #expect(Date().timeIntervalSince(startedAt) < 2)
}

@Test
func commandLimiterDoesNotLeakPermitWhenWaitingTaskIsCancelled() async throws {
    let limiter = HimalayaCommandLimiter(maxConcurrentCommands: 1)
    let bridge = DelayedHimalayaBridge(delay: .milliseconds(150))

    let first = Task {
        try await limiter.run(.accountList(), bridge: bridge, timeout: nil)
    }
    try await Task.sleep(for: .milliseconds(25))

    let waiting = Task {
        try await limiter.run(.folderList(account: "work"), bridge: bridge, timeout: nil)
    }
    try await Task.sleep(for: .milliseconds(25))
    waiting.cancel()

    do {
        _ = try await waiting.value
        Issue.record("Cancelled waiter completed successfully")
    } catch is CancellationError {
    } catch {
        throw error
    }

    _ = try await first.value
    let third = try await withTestTimeout(.seconds(1)) {
        try await limiter.run(
            .messageExport(
                id: "42",
                destination: FileManager.default.temporaryDirectory
                    .appendingPathComponent("mailia-limiter-test", isDirectory: true)
            ),
            bridge: bridge,
            timeout: nil
        )
    }

    #expect(third.succeeded)
}

@Test
func commandLimiterRunsHigherPriorityWaiterBeforeEarlierBackgroundWaiter() async throws {
    let limiter = HimalayaCommandLimiter(maxConcurrentCommands: 1)
    let recorder = CommandStartRecorder()
    let bridge = RecordingDelayedHimalayaBridge(delay: .milliseconds(60), recorder: recorder)

    let first = Task {
        try await limiter.run(
            .accountList(),
            bridge: bridge,
            timeout: nil,
            priority: .backgroundSync
        )
    }
    try await Task.sleep(for: .milliseconds(15))

    let background = Task {
        try await limiter.run(
            .folderList(account: "background"),
            bridge: bridge,
            timeout: nil,
            priority: .backgroundSync
        )
    }
    try await Task.sleep(for: .milliseconds(15))

    let visible = Task {
        try await limiter.run(
            .messageExport(
                id: "visible",
                destination: FileManager.default.temporaryDirectory
                    .appendingPathComponent("mailia-priority-test", isDirectory: true)
            ),
            bridge: bridge,
            timeout: nil,
            priority: .visibleBody
        )
    }

    _ = try await first.value
    _ = try await visible.value
    _ = try await background.value

    let labels = await recorder.snapshot()
    #expect(labels == ["account", "message", "folder"])
}

@Test
func commandLimiterKeepsFIFOOrderWithinSamePriority() async throws {
    let limiter = HimalayaCommandLimiter(maxConcurrentCommands: 1)
    let recorder = CommandStartRecorder()
    let bridge = RecordingDelayedHimalayaBridge(delay: .milliseconds(60), recorder: recorder)

    let first = Task {
        try await limiter.run(
            .accountList(),
            bridge: bridge,
            timeout: nil,
            priority: .backgroundSync
        )
    }
    try await Task.sleep(for: .milliseconds(15))

    let firstBackground = Task {
        try await limiter.run(
            .folderList(account: "first"),
            bridge: bridge,
            timeout: nil,
            priority: .backgroundSync
        )
    }
    try await Task.sleep(for: .milliseconds(15))

    let secondBackground = Task {
        try await limiter.run(
            .envelopeList(folder: "second", account: "work"),
            bridge: bridge,
            timeout: nil,
            priority: .backgroundSync
        )
    }

    _ = try await first.value
    _ = try await firstBackground.value
    _ = try await secondBackground.value

    let labels = await recorder.snapshot()
    #expect(labels == ["account", "folder", "envelope"])
}

private final class DelayedHimalayaBridge: HimalayaBridge, @unchecked Sendable {
    private let delay: Duration

    init(delay: Duration) {
        self.delay = delay
    }

    func run(_ command: HimalayaCommand, timeout: TimeInterval?) async throws -> HimalayaResult {
        try await Task.sleep(for: delay)
        return HimalayaResult(
            command: command,
            exitCode: 0,
            stdoutData: Data(),
            stderrData: Data(),
            duration: 0
        )
    }
}

private actor CommandStartRecorder {
    private var labels: [String] = []

    func record(_ command: HimalayaCommand) {
        labels.append(commandLabel(command))
    }

    func snapshot() -> [String] {
        labels
    }

    private func commandLabel(_ command: HimalayaCommand) -> String {
        if command.arguments.contains("message") {
            return "message"
        }
        if command.arguments.contains("folder") {
            return "folder"
        }
        if command.arguments.contains("envelope") {
            return "envelope"
        }
        if command.arguments.contains("account") {
            return "account"
        }
        return command.arguments.joined(separator: " ")
    }
}

private final class RecordingDelayedHimalayaBridge: HimalayaBridge, @unchecked Sendable {
    private let delay: Duration
    private let recorder: CommandStartRecorder

    init(delay: Duration, recorder: CommandStartRecorder) {
        self.delay = delay
        self.recorder = recorder
    }

    func run(_ command: HimalayaCommand, timeout: TimeInterval?) async throws -> HimalayaResult {
        await recorder.record(command)
        try await Task.sleep(for: delay)
        return HimalayaResult(
            command: command,
            exitCode: 0,
            stdoutData: Data(),
            stderrData: Data(),
            duration: 0
        )
    }
}

private enum TestTimeoutError: Error {
    case timedOut
}

private func withTestTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TestTimeoutError.timedOut
        }

        guard let value = try await group.next() else {
            throw TestTimeoutError.timedOut
        }
        group.cancelAll()
        return value
    }
}
