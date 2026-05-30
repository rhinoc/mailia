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
    #expect(HimalayaCommand.messageReadPreview(id: "42", folder: "INBOX").arguments == [
        "--output", "json", "--quiet",
        "message", "read", "--preview", "--folder", "INBOX", "42"
    ])

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
