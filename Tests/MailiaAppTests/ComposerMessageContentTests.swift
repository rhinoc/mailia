import AppKit
import Foundation
import Testing
@testable import MailiaApp

@Test
func composerSerializerPreservesBasicFormattingAsHTML() {
    let body = NSMutableAttributedString(
        string: "Bold link",
        attributes: ComposerTextDefaults.bodyAttributes
    )
    let boldFont = NSFontManager.shared.convert(
        ComposerTextDefaults.bodyFont,
        toHaveTrait: .boldFontMask
    )
    body.addAttribute(.font, value: boldFont, range: NSRange(location: 0, length: 4))
    body.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 5, length: 4))
    body.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 5, length: 4))

    let result = ComposerMessageSerializer.serialize(body)

    #expect(result.plainText == "Bold link")
    #expect(result.html?.contains("<strong>Bold</strong>") == true)
    #expect(result.html?.contains(#"href="https://example.com""#) == true)
    #expect(result.html?.contains("link") == true)
    #expect(result.html?.contains("<u>") == true)
}

@Test
func rawMIMEBuilderCreatesMixedMessageWithAttachment() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MailiaComposerMessageContentTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let attachmentURL = directory.appendingPathComponent("report.txt")
    try Data("attachment".utf8).write(to: attachmentURL)
    let attachment = try MailiaOutgoingAttachment.attachment(fileURL: attachmentURL)
    let content = MailiaComposerContent(
        attributedBody: NSAttributedString(string: "Hello", attributes: ComposerTextDefaults.bodyAttributes),
        attachments: [attachment]
    )

    let raw = try OutgoingMessageMIMEBuilder.rawMessage(
        headers: [
            MailiaEmailHeader(name: "From", value: "me@example.com"),
            MailiaEmailHeader(name: "To", value: "you@example.net"),
            MailiaEmailHeader(name: "Subject", value: "Report")
        ],
        content: content
    )

    #expect(raw.contains("Content-Type: multipart/mixed; boundary="))
    #expect(raw.contains("Content-Type: text/plain; charset=utf-8"))
    #expect(raw.contains(#"Content-Disposition: attachment; filename="report.txt""#))
    #expect(raw.contains("Content-Transfer-Encoding: base64"))
}
