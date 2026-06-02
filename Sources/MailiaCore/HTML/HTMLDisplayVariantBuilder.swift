import Foundation
import SwiftSoup

public struct EmailHTMLDisplayVariants: Equatable, Sendable {
    public let remoteContentBlockedHTML: String?
    public let quotedReplyHiddenHTML: String?
    public let quotedReplyHiddenRemoteContentBlockedHTML: String?

    public init(
        remoteContentBlockedHTML: String?,
        quotedReplyHiddenHTML: String?,
        quotedReplyHiddenRemoteContentBlockedHTML: String?
    ) {
        self.remoteContentBlockedHTML = remoteContentBlockedHTML
        self.quotedReplyHiddenHTML = quotedReplyHiddenHTML
        self.quotedReplyHiddenRemoteContentBlockedHTML = quotedReplyHiddenRemoteContentBlockedHTML
    }
}

public struct HTMLDisplayVariantBuilder: Sendable {
    private static let blockedImageLabel = "Remote image blocked"
    private static let remoteImagePlaceholderClass = "mailia-remote-image-placeholder"

    public init() {}

    public func variants(for html: String) -> EmailHTMLDisplayVariants {
        EmailHTMLDisplayVariants(
            remoteContentBlockedHTML: nilIfBlank(render(html, loadRemoteContent: false, hideQuotedReplyText: false)),
            quotedReplyHiddenHTML: nilIfBlank(render(html, loadRemoteContent: true, hideQuotedReplyText: true)),
            quotedReplyHiddenRemoteContentBlockedHTML: nilIfBlank(render(html, loadRemoteContent: false, hideQuotedReplyText: true))
        )
    }

    public func render(
        _ html: String,
        loadRemoteContent: Bool,
        hideQuotedReplyText: Bool
    ) -> String {
        do {
            let document = try SwiftSoup.parseBodyFragment(html)
            guard let body = document.body() else {
                return html
            }

            if hideQuotedReplyText {
                try stripQuotedReplyHTML(from: body)
            }
            try normalizeRemoteImages(in: body, loadRemoteContent: loadRemoteContent)
            return try body.html()
        } catch {
            return html
        }
    }

    private func stripQuotedReplyHTML(from root: Element) throws {
        try removeOutlookQuotedReplyHTML(from: root)
        try removeKnownQuotedReplyContainers(from: root)
    }

    private func removeOutlookQuotedReplyHTML(from root: Element) throws {
        for header in try root.select("[id$=divRplyFwdMsg]").array() {
            guard try isOutlookReplyHeader(header) else { continue }
            try removeNodeAndFollowingSiblings(outlookReplyStartNode(header))
        }
    }

    private func isOutlookReplyHeader(_ element: Element) throws -> Bool {
        let text = compactEmailText(try element.text()).lowercased()
        let labels = [
            "from:",
            "sent:",
            "to:",
            "subject:",
            "发件人:",
            "发送时间:",
            "收件人:",
            "主题:"
        ]
        return labels.filter { text.contains($0.lowercased()) }.count >= 3
    }

    private func outlookReplyStartNode(_ header: Element) throws -> Node {
        let previous = previousElementSiblingSkippingBlankText(header)
        if previous?.tagNameNormal() == "hr" {
            let beforeRule = previous.flatMap(previousElementSiblingSkippingBlankText)
            if hasIDSuffix(beforeRule, suffix: "appendonsend") {
                return beforeRule ?? previous ?? header
            }
            return previous ?? header
        }

        if hasIDSuffix(previous, suffix: "appendonsend") {
            return previous ?? header
        }
        return header
    }

    private func previousElementSiblingSkippingBlankText(_ element: Element) -> Element? {
        var node = element.previousSibling()
        while let current = node {
            if let element = current as? Element {
                return element
            }
            if let textNode = current as? TextNode,
               textNode.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                node = current.previousSibling()
                continue
            }
            return nil
        }
        return nil
    }

    private func hasIDSuffix(_ element: Element?, suffix: String) -> Bool {
        guard let id = element?.id().lowercased() else {
            return false
        }
        return id.hasSuffix(suffix.lowercased())
    }

    private func removeNodeAndFollowingSiblings(_ startNode: Node) throws {
        var node: Node? = startNode
        while let current = node {
            let next = current.nextSibling()
            try current.remove()
            node = next
        }
    }

    private func removeKnownQuotedReplyContainers(from root: Element) throws {
        for element in try root.select(".gmail_quote,.gmail_extra,blockquote[type='cite']").array() {
            try element.remove()
        }
    }

    private func normalizeRemoteImages(in root: Element, loadRemoteContent: Bool) throws {
        for image in try root.select("img").array() {
            try upgradeInsecureImageAttributes(image)
            let src = try image.attr("src")
            let srcset = try image.attr("srcset")
            guard shouldBlockRemoteImage(src: src, srcset: srcset, loadRemoteContent: loadRemoteContent) else {
                continue
            }

            let placeholderHTML = try remoteImagePlaceholderHTML(for: image)
            if let imageOnlyLink = try imageOnlyLinkParent(image) {
                try imageOnlyLink.before(placeholderHTML)
                try imageOnlyLink.remove()
            } else {
                try image.before(placeholderHTML)
                try image.remove()
            }
        }
    }

    private func shouldBlockRemoteImage(src: String, srcset: String, loadRemoteContent: Bool) -> Bool {
        if isInsecureRemoteURL(src) || srcsetContainsInsecureRemoteURL(srcset) {
            return true
        }
        if loadRemoteContent {
            return false
        }
        return isRemoteURL(src) || srcsetContainsRemoteURL(srcset)
    }

    private func imageOnlyLinkParent(_ image: Element) throws -> Element? {
        guard let parent = image.parent(),
              parent.tagNameNormal() == "a",
              parent.parent() != nil else {
            return nil
        }

        for child in parent.getChildNodes() {
            if child === image {
                continue
            }
            if let textNode = child as? TextNode,
               textNode.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            if child is Comment {
                continue
            }
            return nil
        }

        return parent
    }

    private func remoteImagePlaceholderHTML(for image: Element) throws -> String {
        let style = try preservedImageBoxStyle(image)
        return #"<span class="\#(Self.remoteImagePlaceholderClass)" role="img" aria-label="\#(Self.blockedImageLabel)" style="\#(escapeHTMLAttribute(style))"> </span>"#
    }

    private func preservedImageBoxStyle(_ image: Element) throws -> String {
        var declarations: [(String, String)] = []
        var seenProperties = Set<String>()

        for declaration in try image.attr("style").split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2 else { continue }
            let property = parts[0].lowercased()
            let value = parts[1]
            guard isSafeBoxDeclaration(property: property, value: value) else { continue }

            appendOrReplaceDeclaration(&declarations, seenProperties: &seenProperties, property: property, value: value)
        }

        if let width = sanitizedDimension(try image.attr("width")),
           !seenProperties.contains("width") {
            appendOrReplaceDeclaration(&declarations, seenProperties: &seenProperties, property: "width", value: width)
        }
        if let height = sanitizedDimension(try image.attr("height")),
           !seenProperties.contains("height") {
            appendOrReplaceDeclaration(&declarations, seenProperties: &seenProperties, property: "height", value: height)
        }

        appendOrReplaceDeclaration(&declarations, seenProperties: &seenProperties, property: "display", value: "inline-flex")
        if !seenProperties.contains("vertical-align") {
            appendOrReplaceDeclaration(&declarations, seenProperties: &seenProperties, property: "vertical-align", value: "middle")
        }
        if !seenProperties.contains("width") {
            appendOrReplaceDeclaration(
                &declarations,
                seenProperties: &seenProperties,
                property: "min-width",
                value: declarations.first { $0.0 == "min-width" }?.1 ?? "120px"
            )
        }
        if !seenProperties.contains("height") {
            appendOrReplaceDeclaration(
                &declarations,
                seenProperties: &seenProperties,
                property: "min-height",
                value: declarations.first { $0.0 == "min-height" }?.1 ?? "32px"
            )
        }

        return declarations.map { "\($0.0): \($0.1)" }.joined(separator: "; ")
    }

    private func appendOrReplaceDeclaration(
        _ declarations: inout [(String, String)],
        seenProperties: inout Set<String>,
        property: String,
        value: String
    ) {
        if let index = declarations.firstIndex(where: { $0.0 == property }) {
            declarations[index] = (property, value)
        } else {
            declarations.append((property, value))
        }
        seenProperties.insert(property)
    }

    private func isSafeBoxDeclaration(property: String, value: String) -> Bool {
        [
            "width",
            "height",
            "min-width",
            "min-height",
            "max-width",
            "max-height",
            "display",
            "vertical-align"
        ].contains(property) && isSafeCSSValue(value)
    }

    private func sanitizedDimension(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.range(of: #"^\d{1,5}(\.\d{1,2})?$"#, options: .regularExpression) != nil else {
            return nil
        }
        return "\(trimmed)px"
    }

    private func isSafeCSSValue(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return !lowercased.contains("url(")
            && !lowercased.contains("@import")
            && !lowercased.contains("expression(")
            && !lowercased.contains("behavior:")
            && !lowercased.contains("!important")
    }

    private func upgradeInsecureImageAttributes(_ image: Element) throws {
        let src = try image.attr("src")
        if let upgradedSrc = httpsUpgradedImageURL(src) {
            try image.attr("src", upgradedSrc)
        }

        let srcset = try image.attr("srcset")
        if let upgradedSrcset = httpsUpgradedImageSrcset(srcset) {
            try image.attr("srcset", upgradedSrcset)
        }
    }

    private func httpsUpgradedImageURL(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "http" else {
            return nil
        }

        components.scheme = "https"
        return components.string
    }

    private func httpsUpgradedImageSrcset(_ value: String) -> String? {
        var changed = false
        let candidates = value.split(separator: ",", omittingEmptySubsequences: false).map { candidate in
            let rawCandidate = String(candidate)
            let trimmed = rawCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return rawCandidate }

            var parts = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let upgradedURL = httpsUpgradedImageURL(parts[0]) else {
                return rawCandidate
            }

            changed = true
            parts[0] = upgradedURL
            return parts.joined(separator: " ")
        }

        return changed ? candidates.joined(separator: ", ") : nil
    }

    private func srcsetContainsRemoteURL(_ value: String) -> Bool {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? "" }
            .contains(where: isRemoteURL)
    }

    private func srcsetContainsInsecureRemoteURL(_ value: String) -> Bool {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? "" }
            .contains(where: isInsecureRemoteURL)
    }

    private func isRemoteURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil
            || trimmed.hasPrefix("//")
    }

    private func isInsecureRemoteURL(_ value: String) -> Bool {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^http://"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func compactEmailText(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"[\u{200B}-\u{200D}\u{FEFF}]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func escapeHTMLAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func nilIfBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }
}
