import Foundation

public struct SanitizedEmailDocument: Equatable, Sendable {
    public let html: String?
    public let htmlVariants: EmailHTMLDisplayVariants?
    public let textFallback: String?
    public let hasRemoteImages: Bool
    public let hasAttachments: Bool
    public let sanitizerVersion: Int

    public init(
        html: String?,
        htmlVariants: EmailHTMLDisplayVariants? = nil,
        textFallback: String?,
        hasRemoteImages: Bool,
        hasAttachments: Bool,
        sanitizerVersion: Int = EmailHTMLDisplayPipeline.sanitizerVersion
    ) {
        self.html = html
        self.htmlVariants = htmlVariants
        self.textFallback = textFallback
        self.hasRemoteImages = hasRemoteImages
        self.hasAttachments = hasAttachments
        self.sanitizerVersion = sanitizerVersion
    }
}

public struct EmailHTMLDisplayPipeline: Sendable {
    public static let sanitizerVersion = 5

    private let sanitizer = HTMLSanitizer()
    private let htmlDisplayNormalizer = HTMLDisplayNormalizer()
    private let htmlDisplayVariantBuilder = HTMLDisplayVariantBuilder()
    private let htmlTextExtractor = HTMLTextExtractor()
    private let messageTextNormalizer = MessageTextNormalizer()

    public init() {}

    public func document(
        exportedHTML html: String?,
        exportedText rawText: String?,
        exportDirectory: URL
    ) throws -> SanitizedEmailDocument {
        let normalizedText = rawText.map(messageTextNormalizer.normalize).flatMap(\.nilIfBlank)
        let hasAttachments = Self.exportedAttachmentFilesExist(in: exportDirectory)
            || rawText.map(Self.containsHimalayaAttachmentPartMarker) == true

        let displayHTML: String?
        let hasRemoteImages: Bool
        if let html = html?.nilIfBlank {
            let inlinedHTML = try sanitizer.inlineLocalImageSources(in: html, baseDirectory: exportDirectory)
            let sanitized = try sanitizer.sanitize(inlinedHTML)
            displayHTML = htmlDisplayNormalizer.normalize(sanitized.content).nilIfBlank
            hasRemoteImages = sanitized.containsRemoteImages
        } else if let normalizedText {
            displayHTML = Self.plainTextHTML(normalizedText)
            hasRemoteImages = false
        } else {
            displayHTML = nil
            hasRemoteImages = false
        }

        guard let displayHTML else {
            return SanitizedEmailDocument(
                html: nil,
                textFallback: nil,
                hasRemoteImages: false,
                hasAttachments: hasAttachments
            )
        }

        return SanitizedEmailDocument(
            html: displayHTML,
            htmlVariants: htmlDisplayVariantBuilder.variants(for: displayHTML),
            textFallback: htmlTextExtractor.previewText(from: displayHTML),
            hasRemoteImages: hasRemoteImages,
            hasAttachments: hasAttachments
        )
    }

    public func textOnlyDocument(_ rawText: String) -> SanitizedEmailDocument {
        let normalizedText = messageTextNormalizer.normalize(rawText)
        let displayHTML = normalizedText.nilIfBlank.map(Self.plainTextHTML)
        return SanitizedEmailDocument(
            html: displayHTML,
            htmlVariants: displayHTML.map { htmlDisplayVariantBuilder.variants(for: $0) },
            textFallback: displayHTML.flatMap { htmlTextExtractor.previewText(from: $0) },
            hasRemoteImages: false,
            hasAttachments: Self.containsHimalayaAttachmentPartMarker(rawText)
        )
    }

    private static func plainTextHTML(_ text: String) -> String {
        "<pre>\(escapeHTML(text))</pre>"
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func exportedAttachmentFilesExist(in directory: URL) -> Bool {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        return children.contains { url in
            let name = url.lastPathComponent.lowercased()
            guard name != "index.html", name != "plain.txt" else { return false }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
        }
    }

    private static func containsHimalayaAttachmentPartMarker(_ text: String) -> Bool {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.hasPrefix("<#part ") &&
                    trimmed.hasSuffix("<#/part>") &&
                    trimmed.contains(" type=") &&
                    trimmed.contains(" filename=")
            }
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
