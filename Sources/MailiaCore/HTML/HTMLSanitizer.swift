import Foundation
import SwiftSoup

public struct SanitizedHTML: Equatable {
    public let content: String
    public let remoteContentBlocked: Bool

    public init(content: String, remoteContentBlocked: Bool) {
        self.content = content
        self.remoteContentBlocked = remoteContentBlocked
    }
}

public struct HTMLSanitizer {
    private static let blockedTags = "script, iframe, video, audio, object, embed"
    private static let blockedImageLabel = "Remote image blocked"

    public init() {}

    public func sanitize(_ html: String) throws -> SanitizedHTML {
        let document = try SwiftSoup.parseBodyFragment(html)
        var remoteContentBlocked = false

        try document.select(Self.blockedTags).remove()
        remoteContentBlocked = try removeRemoteStylesheets(from: document)

        if let body = document.body() {
            for element in try body.getAllElements() {
                try removeEventHandlerAttributes(from: element)
                try sanitizeInlineStyle(on: element)

                if try isHiddenEmailSpacer(element) {
                    try element.remove()
                    continue
                }

                if element.tagNameNormal() == "img" {
                    try sanitizeImage(element)
                } else {
                    try sanitizeURLAttributes(on: element)
                }
            }

            return SanitizedHTML(
                content: try body.html(),
                remoteContentBlocked: remoteContentBlocked
            )
        }

        return SanitizedHTML(content: "", remoteContentBlocked: remoteContentBlocked)
    }

    public func blockRemoteImages(in html: String) throws -> SanitizedHTML {
        let document = try SwiftSoup.parseBodyFragment(html)
        var remoteContentBlocked = false

        if let body = document.body() {
            for image in try body.select("img").array() {
                let src = try image.attr("src")
                let srcset = try image.attr("srcset")
                guard isRemoteImageURL(src) || srcsetContainsRemoteURL(srcset) else {
                    continue
                }

                remoteContentBlocked = true
                try replaceRemoteImageWithPlaceholder(image, in: document)
            }

            return SanitizedHTML(
                content: try body.html(),
                remoteContentBlocked: remoteContentBlocked
            )
        }

        return SanitizedHTML(content: "", remoteContentBlocked: remoteContentBlocked)
    }

    private func isHiddenEmailSpacer(_ element: Element) throws -> Bool {
        guard element.hasAttr("style") else {
            return false
        }

        let style = try element.attr("style").lowercased()
        guard style.contains("display:none") || style.contains("display: none") else {
            return false
        }

        let text = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
        let html = try element.html()
            .replacingOccurrences(of: "&nbsp;", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || html.isEmpty
    }

    private func removeRemoteStylesheets(from document: Document) throws -> Bool {
        var removedRemoteResource = false

        for link in try document.select("link") {
            let rel = try link.attr("rel").lowercased()
            let asValue = try link.attr("as").lowercased()
            if rel.contains("stylesheet") || asValue == "font" {
                let href = try link.attr("href")
                removedRemoteResource = removedRemoteResource
                    || isRemoteURL(href)
                    || href.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("//")
                try link.remove()
            }
        }

        try document.select("style").remove()
        return removedRemoteResource
    }

    private func removeEventHandlerAttributes(from element: Element) throws {
        let eventAttributes = element.getAttributes()?.asList()
            .map { $0.getKey() }
            .filter { $0.lowercased().hasPrefix("on") } ?? []

        for attribute in eventAttributes {
            try element.removeAttr(attribute)
        }
    }

    private func sanitizeInlineStyle(on element: Element) throws {
        guard element.hasAttr("style") else {
            return
        }

        let style = try element.attr("style")
        let lowercasedStyle = style.lowercased()
        if lowercasedStyle.contains("url(")
            || lowercasedStyle.contains("@import")
            || lowercasedStyle.contains("expression(")
            || lowercasedStyle.contains("behavior:") {
            try element.removeAttr("style")
        }
    }

    private func sanitizeURLAttributes(on element: Element) throws {
        for attribute in ["href", "src", "poster", "action", "formaction", "background", "xlink:href"] {
            guard element.hasAttr(attribute) else {
                continue
            }

            let value = try element.attr(attribute)
            switch classifyURL(value, allowsImageData: false) {
            case .httpOrHTTPS:
                if element.tagNameNormal() == "a", attribute == "href" {
                    try makeExternalSafeLink(element)
                }
            case .relativeOrFragment:
                break
            case .blocked:
                try element.removeAttr(attribute)
            }
        }

        if element.hasAttr("srcset") {
            try element.removeAttr("srcset")
        }
    }

    private func sanitizeImage(_ image: Element) throws {
        let src = try image.attr("src")
        let srcset = try image.attr("srcset")

        switch classifyURL(src, allowsImageData: true) {
        case .httpOrHTTPS, .relativeOrFragment:
            break
        case .blocked:
            if !src.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("//") {
                try image.removeAttr("src")
            }
        }

        if image.hasAttr("srcset"), srcsetContainsUnsafeURL(srcset) {
            try image.removeAttr("srcset")
        }

        try image.removeAttr("data-mailia-remote-content-blocked")
    }

    private func preserveImageBox(on image: Element) throws {
        let width = sanitizedDimension(try image.attr("width"))
        let height = sanitizedDimension(try image.attr("height"))

        var declarations = safeSizingDeclarations(from: try image.attr("style"))
        if let width, declarations["width"] == nil {
            declarations["width"] = width
        }
        if let height, declarations["height"] == nil {
            declarations["height"] = height
        }
        if declarations["display"] == nil {
            declarations["display"] = "inline-block"
        }

        if !declarations.isEmpty {
            let style = declarations
                .map { "\($0.key): \($0.value)" }
                .sorted()
                .joined(separator: "; ")
            try image.attr("style", style)
        }
    }

    private func replaceRemoteImageWithPlaceholder(_ image: Element, in document: Document) throws {
        let placeholder = try document.createElement("span")
        try placeholder.addClass("mailia-remote-image-placeholder")
        try placeholder.attr("role", "img")
        try placeholder.attr("aria-label", Self.blockedImageLabel)
        try placeholder.text(" ")

        let style = try blockedImagePlaceholderStyle(for: image)
        if !style.isEmpty {
            try placeholder.attr("style", style)
        }

        if let imageOnlyLink = try imageOnlyLinkParent(for: image) {
            try imageOnlyLink.replaceWith(placeholder)
        } else {
            try image.replaceWith(placeholder)
        }
    }

    private func imageOnlyLinkParent(for image: Element) throws -> Element? {
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

            if child.nodeName() == "#comment" {
                continue
            }

            return nil
        }

        return parent
    }

    private func blockedImagePlaceholderStyle(for image: Element) throws -> String {
        let width = sanitizedDimension(try image.attr("width"))
        let height = sanitizedDimension(try image.attr("height"))

        var declarations = safeSizingDeclarations(from: try image.attr("style"))
        if let width, declarations["width"] == nil {
            declarations["width"] = width
        }
        if let height, declarations["height"] == nil {
            declarations["height"] = height
        }

        declarations["display"] = "inline-flex"
        if declarations["vertical-align"] == nil {
            declarations["vertical-align"] = "middle"
        }
        if declarations["width"] == nil {
            declarations["min-width"] = declarations["min-width"] ?? "120px"
        }
        if declarations["height"] == nil {
            declarations["min-height"] = declarations["min-height"] ?? "32px"
        }

        return declarations
            .map { "\($0.key): \($0.value)" }
            .sorted()
            .joined(separator: "; ")
    }

    private func safeSizingDeclarations(from style: String) -> [String: String] {
        var declarations: [String: String] = [:]

        for declaration in style.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2 else {
                continue
            }

            let property = parts[0].lowercased()
            let value = parts[1]
            guard ["width", "height", "min-width", "min-height", "max-width", "max-height", "display", "vertical-align"].contains(property),
                  isSafeCSSValue(value) else {
                continue
            }

            declarations[property] = value
        }

        return declarations
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
        let lowercasedValue = value.lowercased()
        return !lowercasedValue.contains("url(")
            && !lowercasedValue.contains("@import")
            && !lowercasedValue.contains("expression(")
            && !lowercasedValue.contains("behavior:")
            && !lowercasedValue.contains("!important")
    }

    private func makeExternalSafeLink(_ link: Element) throws {
        try link.attr("target", "_blank")

        var relValues = Set(try link.attr("rel")
            .split(separator: " ")
            .map { $0.lowercased() })
        relValues.insert("noopener")
        relValues.insert("noreferrer")

        try link.attr("rel", relValues.sorted().joined(separator: " "))
    }

    private func classifyURL(_ value: String, allowsImageData: Bool) -> URLClassification {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .relativeOrFragment
        }

        if trimmed.hasPrefix("#") || trimmed.hasPrefix("/") && !trimmed.hasPrefix("//") {
            return .relativeOrFragment
        }

        guard let schemeRange = trimmed.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) else {
            return trimmed.hasPrefix("//") ? .blocked : .relativeOrFragment
        }

        let scheme = trimmed[..<schemeRange.upperBound].dropLast().lowercased()
        switch scheme {
        case "http", "https":
            return .httpOrHTTPS
        case "data":
            return allowsImageData && isSafeImageDataURL(trimmed) ? .relativeOrFragment : .blocked
        default:
            return .blocked
        }
    }

    private func isRemoteURL(_ value: String) -> Bool {
        switch classifyURL(value, allowsImageData: true) {
        case .httpOrHTTPS:
            return true
        case .relativeOrFragment, .blocked:
            return false
        }
    }

    private func isRemoteImageURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("//") || isRemoteURL(trimmed)
    }

    private func srcsetContainsRemoteURL(_ value: String) -> Bool {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { candidate in
                guard let url = candidate.split(separator: " ").first else {
                    return false
                }
                return isRemoteImageURL(String(url))
            }
    }

    private func srcsetContainsUnsafeURL(_ value: String) -> Bool {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { candidate in
                guard let url = candidate.split(separator: " ").first else {
                    return false
                }
                let value = String(url)
                return !value.hasPrefix("//") && classifyURL(value, allowsImageData: true) == .blocked
            }
    }

    private func isSafeImageDataURL(_ value: String) -> Bool {
        value.range(
            of: #"^data:image/(gif|png|jpeg|webp);base64,[A-Za-z0-9+/=]+$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private enum URLClassification {
        case httpOrHTTPS
        case relativeOrFragment
        case blocked
    }
}
