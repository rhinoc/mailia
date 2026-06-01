import AppKit
import Foundation
import UniformTypeIdentifiers

enum MailiaOutgoingAttachmentDisposition: Equatable {
    case attachment
    case inlineImage(contentID: String)
}

struct MailiaOutgoingAttachment: Identifiable, Equatable {
    let id: UUID
    let fileURL: URL
    let displayName: String
    let byteSize: Int64
    let contentType: String
    let disposition: MailiaOutgoingAttachmentDisposition

    var isInlineImage: Bool {
        if case .inlineImage = disposition { return true }
        return false
    }

    var contentID: String? {
        if case .inlineImage(let contentID) = disposition { return contentID }
        return nil
    }

    static func attachment(fileURL: URL) throws -> MailiaOutgoingAttachment {
        try make(fileURL: fileURL, disposition: .attachment)
    }

    static func inlineImage(fileURL: URL) throws -> MailiaOutgoingAttachment {
        try make(
            fileURL: fileURL,
            disposition: .inlineImage(contentID: "mailia-\(UUID().uuidString.lowercased())")
        )
    }

    private static func make(
        fileURL: URL,
        disposition: MailiaOutgoingAttachmentDisposition
    ) throws -> MailiaOutgoingAttachment {
        let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard resourceValues.isRegularFile == true else {
            throw MailiaOutgoingAttachmentError.notAFile(fileURL.lastPathComponent)
        }

        let displayName = fileURL.lastPathComponent.mailiaNilIfBlank ?? "attachment"
        let byteSize = Int64(resourceValues.fileSize ?? 0)
        let contentType = Self.contentType(for: fileURL)

        if case .inlineImage = disposition, !contentType.lowercased().hasPrefix("image/") {
            throw MailiaOutgoingAttachmentError.notAnImage(displayName)
        }

        return MailiaOutgoingAttachment(
            id: UUID(),
            fileURL: fileURL,
            displayName: displayName,
            byteSize: byteSize,
            contentType: contentType,
            disposition: disposition
        )
    }

    private static func contentType(for fileURL: URL) -> String {
        if let type = try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType,
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        if let type = UTType(filenameExtension: fileURL.pathExtension),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        return "application/octet-stream"
    }
}

enum MailiaOutgoingAttachmentError: LocalizedError, Equatable {
    case notAFile(String)
    case notAnImage(String)
    case unreadable(String)
    case tooLarge(totalBytes: Int64, limitBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .notAFile(let name):
            "\(name) is not a file."
        case .notAnImage(let name):
            "\(name) is not an image."
        case .unreadable(let name):
            "\(name) cannot be read."
        case .tooLarge(let totalBytes, let limitBytes):
            "Attachments are \(Self.sizeLabel(totalBytes)); the limit is \(Self.sizeLabel(limitBytes))."
        }
    }

    private static func sizeLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct MailiaComposerContent {
    var attributedBody: NSAttributedString
    var attachments: [MailiaOutgoingAttachment]

    init(attributedBody: NSAttributedString, attachments: [MailiaOutgoingAttachment]) {
        self.attributedBody = attributedBody
        self.attachments = attachments
    }

    init(plainText: String) {
        self.init(
            attributedBody: NSAttributedString(
                string: plainText,
                attributes: ComposerTextDefaults.bodyAttributes
            ),
            attachments: []
        )
    }

    var plainText: String {
        ComposerMessageSerializer.serialize(attributedBody).plainText
    }

    var hasRenderableContent: Bool {
        plainText.trimmingCharacters(in: .whitespacesAndNewlines).mailiaNilIfBlank != nil
            || !attachments.isEmpty
            || ComposerMessageSerializer.containsInlineImage(attributedBody)
    }

    var requiresRawMIME: Bool {
        !attachments.isEmpty || ComposerMessageSerializer.hasRichContent(attributedBody)
    }
}

enum ComposerTextDefaults {
    static let fontSize: CGFloat = 15

    static var bodyFont: NSFont {
        NSFont.systemFont(ofSize: fontSize)
    }

    static var bodyAttributes: [NSAttributedString.Key: Any] {
        [
            .font: bodyFont,
            .foregroundColor: NSColor.labelColor
        ]
    }
}

final class ComposerInlineImageTextAttachment: NSTextAttachment {
    let outgoingAttachment: MailiaOutgoingAttachment

    init(outgoingAttachment: MailiaOutgoingAttachment, image: NSImage) {
        self.outgoingAttachment = outgoingAttachment
        super.init(data: nil, ofType: outgoingAttachment.contentType)
        self.image = image
        self.bounds = Self.displayBounds(for: image)
    }

    required init?(coder: NSCoder) {
        nil
    }

    private static func displayBounds(for image: NSImage) -> CGRect {
        let maxWidth: CGFloat = 360
        let maxHeight: CGFloat = 220
        let original = image.size
        guard original.width > 0, original.height > 0 else {
            return CGRect(x: 0, y: -4, width: 120, height: 80)
        }
        let scale = min(1, maxWidth / original.width, maxHeight / original.height)
        return CGRect(
            x: 0,
            y: -4,
            width: max(24, original.width * scale),
            height: max(24, original.height * scale)
        )
    }
}

struct ComposerSerializedBody {
    var plainText: String
    var html: String?
    var inlineImages: [MailiaOutgoingAttachment]
}

enum ComposerMessageSerializer {
    static func containsInlineImage(_ attributedBody: NSAttributedString) -> Bool {
        var containsImage = false
        attributedBody.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributedBody.length)
        ) { value, _, stop in
            if value is ComposerInlineImageTextAttachment {
                containsImage = true
                stop.pointee = true
            }
        }
        return containsImage
    }

    static func hasRichContent(_ attributedBody: NSAttributedString) -> Bool {
        if containsInlineImage(attributedBody) { return true }

        var hasRichContent = false
        attributedBody.enumerateAttributes(
            in: NSRange(location: 0, length: attributedBody.length)
        ) { attributes, _, stop in
            if isBold(attributes[.font] as? NSFont)
                || isItalic(attributes[.font] as? NSFont)
                || underlineStyle(attributes) != nil
                || attributes[.link] != nil {
                hasRichContent = true
                stop.pointee = true
            }
        }
        return hasRichContent
    }

    static func serialize(_ attributedBody: NSAttributedString) -> ComposerSerializedBody {
        var plainText = ""
        var html = ""
        var inlineImages: [MailiaOutgoingAttachment] = []
        var emittedHTML = false

        attributedBody.enumerateAttributes(
            in: NSRange(location: 0, length: attributedBody.length)
        ) { attributes, range, _ in
            if let attachment = attributes[.attachment] as? ComposerInlineImageTextAttachment,
               let contentID = attachment.outgoingAttachment.contentID {
                let label = attachment.outgoingAttachment.displayName
                plainText += "[Image: \(label)]"
                html += #"<img src="cid:\#(escapeHTMLAttribute(contentID))" alt="\#(escapeHTMLAttribute(label))">"#
                inlineImages.append(attachment.outgoingAttachment)
                emittedHTML = true
                return
            }

            let substring = attributedBody.attributedSubstring(from: range).string
            plainText += substring
            var fragment = escapeHTMLText(substring)
                .replacingOccurrences(of: "\n", with: "<br>\r\n")
            guard !fragment.isEmpty else { return }

            if let link = linkURL(attributes[.link]) {
                fragment = #"<a href="\#(escapeHTMLAttribute(link.absoluteString))">\#(fragment)</a>"#
                emittedHTML = true
            }
            if underlineStyle(attributes) != nil {
                fragment = "<u>\(fragment)</u>"
                emittedHTML = true
            }
            if isItalic(attributes[.font] as? NSFont) {
                fragment = "<em>\(fragment)</em>"
                emittedHTML = true
            }
            if isBold(attributes[.font] as? NSFont) {
                fragment = "<strong>\(fragment)</strong>"
                emittedHTML = true
            }
            html += fragment
        }

        return ComposerSerializedBody(
            plainText: plainText,
            html: emittedHTML ? "<div>\(html)</div>" : nil,
            inlineImages: inlineImages
        )
    }

    private static func isBold(_ font: NSFont?) -> Bool {
        guard let font else { return false }
        return NSFontManager.shared.traits(of: font).contains(.boldFontMask)
    }

    private static func isItalic(_ font: NSFont?) -> Bool {
        guard let font else { return false }
        return NSFontManager.shared.traits(of: font).contains(.italicFontMask)
    }

    private static func underlineStyle(_ attributes: [NSAttributedString.Key: Any]) -> Int? {
        guard let rawValue = attributes[.underlineStyle] as? Int, rawValue != 0 else {
            return nil
        }
        return rawValue
    }

    private static func linkURL(_ value: Any?) -> URL? {
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    private static func escapeHTMLText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeHTMLAttribute(_ value: String) -> String {
        escapeHTMLText(value)
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

struct MailiaEmailHeader: Equatable {
    var name: String
    var value: String
}

struct MailiaEmailTemplate {
    var headers: [MailiaEmailHeader]
    var body: String

    static func parse(_ template: String) -> MailiaEmailTemplate {
        let normalized = template.replacingOccurrences(of: "\r\n", with: "\n")
        let parts = normalized.components(separatedBy: "\n\n")
        let headerText = parts.first ?? ""
        let body = parts.dropFirst().joined(separator: "\n\n")
        var headers: [MailiaEmailHeader] = []

        for line in headerText.components(separatedBy: "\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                guard !headers.isEmpty else { continue }
                headers[headers.count - 1].value += " " + line.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }

            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            headers.append(MailiaEmailHeader(name: name, value: value))
        }

        return MailiaEmailTemplate(headers: headers, body: body)
    }
}

enum OutgoingMessageMIMEBuilder {
    static let defaultSizeLimitBytes: Int64 = 25 * 1_024 * 1_024

    static func rawMessage(
        headers: [MailiaEmailHeader],
        content: MailiaComposerContent,
        sizeLimitBytes: Int64 = defaultSizeLimitBytes
    ) throws -> String {
        try validateFiles(content: content, sizeLimitBytes: sizeLimitBytes)
        let serialized = ComposerMessageSerializer.serialize(content.attributedBody)
        let bodyPart = try messageBodyPart(serialized: serialized)
        let regularAttachments = content.attachments.filter { !$0.isInlineImage }

        var messageHeaders = normalizedTopLevelHeaders(headers)
        if !messageHeaders.contains(where: { $0.name.caseInsensitiveCompare("Date") == .orderedSame }) {
            messageHeaders.append(MailiaEmailHeader(name: "Date", value: rfc5322Date()))
        }
        if !messageHeaders.contains(where: { $0.name.caseInsensitiveCompare("Message-ID") == .orderedSame }) {
            messageHeaders.append(MailiaEmailHeader(name: "Message-ID", value: messageID(headers: headers)))
        }
        if !messageHeaders.contains(where: { $0.name.caseInsensitiveCompare("MIME-Version") == .orderedSame }) {
            messageHeaders.append(MailiaEmailHeader(name: "MIME-Version", value: "1.0"))
        }

        let body: String
        if regularAttachments.isEmpty {
            messageHeaders.append(MailiaEmailHeader(name: "Content-Type", value: bodyPart.contentType))
            body = bodyPart.body
        } else {
            let boundary = boundary("mixed")
            messageHeaders.append(MailiaEmailHeader(
                name: "Content-Type",
                value: #"multipart/mixed; boundary="\#(boundary)""#
            ))
            var parts = [
                "--\(boundary)\r\n\(bodyPart.rawPart)"
            ]
            for attachment in regularAttachments {
                parts.append("--\(boundary)\r\n\(try attachmentPart(attachment))")
            }
            parts.append("--\(boundary)--")
            body = parts.joined(separator: "\r\n")
        }

        return messageHeaders
            .map { "\($0.name): \($0.value)" }
            .joined(separator: "\r\n")
            + "\r\n\r\n"
            + body
            + "\r\n"
    }

    private struct MIMEPart {
        var contentType: String
        var rawPart: String
        var body: String
    }

    private static func messageBodyPart(serialized: ComposerSerializedBody) throws -> MIMEPart {
        let inlineImages = serialized.inlineImages
        let plainPart = textPart(contentType: "text/plain; charset=utf-8", body: serialized.plainText)

        if let html = serialized.html {
            let alternativeBoundary = boundary("alt")
            let htmlPart = textPart(contentType: "text/html; charset=utf-8", body: html)
            let alternativeBody = [
                "--\(alternativeBoundary)\r\n\(plainPart)",
                "--\(alternativeBoundary)\r\n\(htmlPart)",
                "--\(alternativeBoundary)--"
            ].joined(separator: "\r\n")
            let alternativePart = """
            Content-Type: multipart/alternative; boundary="\(alternativeBoundary)"

            \(alternativeBody)
            """

            if inlineImages.isEmpty {
                return MIMEPart(
                    contentType: #"multipart/alternative; boundary="\#(alternativeBoundary)""#,
                    rawPart: alternativePart,
                    body: alternativeBody
                )
            }

            let relatedBoundary = boundary("related")
            var relatedParts = [
                "--\(relatedBoundary)\r\n\(alternativePart)"
            ]
            for image in inlineImages {
                relatedParts.append("--\(relatedBoundary)\r\n\(try attachmentPart(image))")
            }
            relatedParts.append("--\(relatedBoundary)--")
            let relatedBody = relatedParts.joined(separator: "\r\n")
            return MIMEPart(
                contentType: #"multipart/related; boundary="\#(relatedBoundary)"; type="multipart/alternative""#,
                rawPart: """
                Content-Type: multipart/related; boundary="\(relatedBoundary)"; type="multipart/alternative"

                \(relatedBody)
                """,
                body: relatedBody
            )
        }

        return MIMEPart(
            contentType: "text/plain; charset=utf-8",
            rawPart: plainPart,
            body: encodedTextBody(serialized.plainText)
        )
    }

    private static func textPart(contentType: String, body: String) -> String {
        """
        Content-Type: \(contentType)
        Content-Transfer-Encoding: base64

        \(encodedTextBody(body))
        """
    }

    private static func encodedTextBody(_ body: String) -> String {
        wrapBase64(Data(body.utf8).base64EncodedString())
    }

    private static func attachmentPart(_ attachment: MailiaOutgoingAttachment) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: attachment.fileURL)
        } catch {
            throw MailiaOutgoingAttachmentError.unreadable(attachment.displayName)
        }

        let disposition: String
        if case .inlineImage = attachment.disposition {
            disposition = "inline"
        } else {
            disposition = "attachment"
        }

        var headers = [
            #"Content-Type: \#(attachment.contentType); name="\#(quotedParameter(attachment.displayName))""#,
            "Content-Transfer-Encoding: base64",
            #"Content-Disposition: \#(disposition); filename="\#(quotedParameter(attachment.displayName))""#
        ]
        if let contentID = attachment.contentID {
            headers.append("Content-ID: <\(contentID)>")
        }

        return headers.joined(separator: "\r\n")
            + "\r\n\r\n"
            + wrapBase64(data.base64EncodedString())
    }

    private static func normalizedTopLevelHeaders(_ headers: [MailiaEmailHeader]) -> [MailiaEmailHeader] {
        let blocked = Set(["content-type", "content-transfer-encoding", "content-disposition", "mime-version"])
        return headers.filter { !blocked.contains($0.name.lowercased()) }
    }

    private static func validateFiles(content: MailiaComposerContent, sizeLimitBytes: Int64) throws {
        let allAttachments = ComposerMessageSerializer.serialize(content.attributedBody).inlineImages
            + content.attachments
        var totalBytes: Int64 = 0
        for attachment in allAttachments {
            guard FileManager.default.isReadableFile(atPath: attachment.fileURL.path) else {
                throw MailiaOutgoingAttachmentError.unreadable(attachment.displayName)
            }
            totalBytes += attachment.byteSize
        }
        guard totalBytes <= sizeLimitBytes else {
            throw MailiaOutgoingAttachmentError.tooLarge(totalBytes: totalBytes, limitBytes: sizeLimitBytes)
        }
    }

    private static func boundary(_ prefix: String) -> String {
        "mailia-\(prefix)-\(UUID().uuidString.lowercased())"
    }

    private static func quotedParameter(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func wrapBase64(_ encoded: String) -> String {
        stride(from: 0, to: encoded.count, by: 76).map { offset in
            let start = encoded.index(encoded.startIndex, offsetBy: offset)
            let end = encoded.index(start, offsetBy: min(76, encoded.distance(from: start, to: encoded.endIndex)))
            return String(encoded[start..<end])
        }.joined(separator: "\r\n")
    }

    private static func rfc5322Date(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: now)
    }

    private static func messageID(headers: [MailiaEmailHeader]) -> String {
        let domain = headers
            .first { $0.name.caseInsensitiveCompare("From") == .orderedSame }
            .flatMap { fromDomain($0.value) }
            ?? "mailia.local"
        return "<\(UUID().uuidString.lowercased())@\(domain)>"
    }

    private static func fromDomain(_ from: String) -> String? {
        guard let atIndex = from.lastIndex(of: "@") else { return nil }
        let suffix = from[from.index(after: atIndex)...]
        let domain = suffix
            .trimmingCharacters(in: CharacterSet(charactersIn: "<> \"\t\r\n"))
            .mailiaNilIfBlank
        return domain
    }
}

private extension String {
    var mailiaNilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
