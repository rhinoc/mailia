import Foundation
import SwiftSoup

public struct SanitizedHTML: Equatable {
    public let content: String
    public let remoteContentBlocked: Bool
    public let containsRemoteImages: Bool

    public init(content: String, remoteContentBlocked: Bool, containsRemoteImages: Bool = false) {
        self.content = content
        self.remoteContentBlocked = remoteContentBlocked
        self.containsRemoteImages = containsRemoteImages
    }
}

public struct HTMLSanitizer: Sendable {
    private static let blockedTags = "script, iframe, video, audio, object, embed"
    private static let blockedImageLabel = "Remote image blocked"
    private static let sanitizerBaseURI = "https://mailia.invalid/"

    public init() {}

    public func sanitize(_ html: String) throws -> SanitizedHTML {
        let document = try SwiftSoup.parseBodyFragment(html)

        try document.select(Self.blockedTags).remove()
        let remoteContentBlocked = try removeRemoteStylesheets(from: document)
        let cleanedHTML = try SwiftSoup.clean(
            try document.body()?.html() ?? "",
            Self.sanitizerBaseURI,
            Self.emailWhitelist()
        ) ?? ""
        let cleanedDocument = try SwiftSoup.parseBodyFragment(cleanedHTML)

        if let body = cleanedDocument.body() {
            var containsRemoteImages = false
            for element in try body.getAllElements() {
                try removeEventHandlerAttributes(from: element)
                try sanitizeInlineStyle(on: element)

                if try isHiddenEmailSpacer(element) {
                    try element.remove()
                    continue
                }

                if element.tagNameNormal() == "img" {
                    try sanitizeImage(element)
                    let src = try element.attr("src")
                    let srcset = try element.attr("srcset")
                    containsRemoteImages = containsRemoteImages
                        || isRemoteImageURL(src)
                        || srcsetContainsRemoteURL(srcset)
                } else {
                    try sanitizeURLAttributes(on: element)
                }
            }

            return SanitizedHTML(
                content: try body.html(),
                remoteContentBlocked: remoteContentBlocked,
                containsRemoteImages: containsRemoteImages
            )
        }

        return SanitizedHTML(content: "", remoteContentBlocked: remoteContentBlocked)
    }

    public func inlineLocalImageSources(
        in html: String,
        baseDirectory: URL,
        maxImageBytes: Int = 8 * 1024 * 1024
    ) throws -> String {
        let document = try SwiftSoup.parseBodyFragment(html)
        let baseURL = baseDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let basePath = baseURL.path

        guard let body = document.body() else {
            return html
        }

        for image in try body.select("img").array() {
            let src = try image.attr("src")
            guard let fileURL = localImageFileURL(from: src, baseURL: baseURL) else {
                continue
            }

            if isDescendant(fileURL, ofDirectoryPath: basePath),
               let dataURL = imageDataURL(for: fileURL, maxImageBytes: maxImageBytes) {
                try image.attr("src", dataURL)
            } else {
                try image.removeAttr("src")
            }
            try image.removeAttr("srcset")
        }

        return try body.html()
    }

    private static func emailWhitelist() throws -> Whitelist {
        let whitelist = try Whitelist.relaxed()
            .removeProtocols("a", "href", "ftp")
            .addProtocols("a", "href", "#")
            .addProtocols("img", "src", "data")
            .preserveRelativeLinks(true)
            .urlWhitespace(.trim)

        try whitelist
            .addTags(
                "address", "article", "aside", "center", "del", "font", "hr", "ins",
                "main", "mark", "section", "time"
            )
            .addAttributes(
                ":all",
                "aria-hidden", "aria-label", "class", "dir", "id", "lang", "role", "style", "title"
            )
            .addAttributes("a", "href", "name", "rel", "target", "title")
            .addAttributes("font", "color", "face", "size")
            .addAttributes(
                "img",
                "align", "alt", "border", "height", "hspace", "loading", "src", "srcset",
                "title", "vspace", "width"
            )
            .addAttributes(
                "table",
                "align", "bgcolor", "border", "cellpadding", "cellspacing", "height",
                "role", "summary", "width"
            )
            .addAttributes("tbody", "align", "valign")
            .addAttributes("thead", "align", "valign")
            .addAttributes("tfoot", "align", "valign")
            .addAttributes("tr", "align", "bgcolor", "height", "valign")
            .addAttributes(
                "td",
                "abbr", "align", "axis", "bgcolor", "colspan", "height", "rowspan", "valign", "width"
            )
            .addAttributes(
                "th",
                "abbr", "align", "axis", "bgcolor", "colspan", "height", "rowspan", "scope", "valign", "width"
            )
            .addCSSProperties(
                ":all",
                "background", "background-color", "border", "border-bottom", "border-collapse",
                "border-color", "border-left", "border-radius", "border-right", "border-spacing",
                "border-style", "border-top", "border-width", "box-sizing", "clear", "color",
                "direction", "display", "font", "font-family", "font-size", "font-style",
                "font-variant", "font-weight", "height", "letter-spacing", "line-height",
                "margin", "margin-bottom", "margin-left", "margin-right", "margin-top",
                "max-height", "max-width", "min-height", "min-width", "opacity", "overflow",
                "padding", "padding-bottom", "padding-left", "padding-right", "padding-top",
                "text-align", "text-decoration", "text-indent", "text-transform", "vertical-align",
                "white-space", "width", "word-break", "word-spacing", "word-wrap"
            )

        return whitelist
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
            case .mailto:
                if element.tagNameNormal() != "a" || attribute != "href" {
                    try element.removeAttr(attribute)
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
        var src = try image.attr("src")
        var srcset = try image.attr("srcset")
        let trimmedSrc = src.trimmingCharacters(in: .whitespacesAndNewlines)

        if let upgradedSrc = httpsUpgradedImageURL(trimmedSrc) {
            src = upgradedSrc
            try image.attr("src", upgradedSrc)
        }
        if let upgradedSrcset = httpsUpgradedImageSrcset(srcset) {
            srcset = upgradedSrcset
            try image.attr("srcset", upgradedSrcset)
        }

        if isLocalAbsolutePath(trimmedSrc) {
            try image.removeAttr("src")
            try image.removeAttr("srcset")
        } else {
            switch classifyURL(src, allowsImageData: true) {
            case .httpOrHTTPS, .relativeOrFragment:
                break
            case .mailto, .blocked:
                try image.removeAttr("src")
            }
        }

        if image.hasAttr("srcset"), srcsetContainsUnsafeURL(srcset) {
            try image.removeAttr("srcset")
        }

        try preserveImageBox(on: image)
        try markRemoteImage(image)
    }

    private func preserveImageBox(on image: Element) throws {
        let width = sanitizedDimension(try image.attr("width"))
        let height = sanitizedDimension(try image.attr("height"))

        var declarations = styleDeclarations(from: try image.attr("style"))
        let hasExplicitSize = width != nil
            || height != nil
            || declarations["width"] != nil
            || declarations["height"] != nil
        if let width, declarations["width"] == nil {
            declarations["width"] = width
        }
        if let height, declarations["height"] == nil {
            declarations["height"] = height
        }

        if !declarations.isEmpty {
            let style = declarations
                .map { "\($0.key): \($0.value)" }
                .sorted()
                .joined(separator: "; ")
            try image.attr("style", style)
        }
        if hasExplicitSize {
            try image.attr("data-mailia-has-explicit-size", "true")
        } else {
            try image.removeAttr("data-mailia-has-explicit-size")
        }
    }

    private func markRemoteImage(_ image: Element) throws {
        let src = try image.attr("src")
        let srcset = try image.attr("srcset")
        if isRemoteImageURL(src) || srcsetContainsRemoteURL(srcset) {
            try image.attr("data-mailia-remote-image", "true")
        } else {
            try image.removeAttr("data-mailia-remote-image")
        }
    }

    private func styleDeclarations(from style: String) -> [String: String] {
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
            guard isSafeCSSValue(value) else {
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

    private func localImageFileURL(from value: String, baseURL: URL) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("#"),
              !trimmed.hasPrefix("//") else {
            return nil
        }

        if let schemeRange = trimmed.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) {
            let scheme = trimmed[..<schemeRange.upperBound].dropLast().lowercased()
            guard scheme == "file",
                  let url = URL(string: trimmed),
                  url.isFileURL else {
                return nil
            }
            return url.standardizedFileURL.resolvingSymlinksInPath()
        }

        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL.resolvingSymlinksInPath()
        }

        return baseURL.appendingPathComponent(trimmed).standardizedFileURL.resolvingSymlinksInPath()
    }

    private func isDescendant(_ fileURL: URL, ofDirectoryPath directoryPath: String) -> Bool {
        let filePath = fileURL.path
        return filePath == directoryPath || filePath.hasPrefix(directoryPath + "/")
    }

    private func imageDataURL(for fileURL: URL, maxImageBytes: Int) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue <= maxImageBytes,
              let data = try? Data(contentsOf: fileURL) else {
            return nil
        }

        if fileURL.pathExtension.lowercased() == "svg" {
            guard let svg = String(data: data, encoding: .utf8),
                  isSafeSVGImage(svg) else {
                return nil
            }
            return "data:image/svg+xml;base64,\(data.base64EncodedString())"
        }

        guard let mediaType = safeRasterImageMediaType(for: fileURL) else {
            return nil
        }

        return "data:\(mediaType);base64,\(data.base64EncodedString())"
    }

    private func safeRasterImageMediaType(for fileURL: URL) -> String? {
        switch fileURL.pathExtension.lowercased() {
        case "gif":
            return "image/gif"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "webp":
            return "image/webp"
        default:
            return nil
        }
    }

    private func isSafeSVGImage(_ svg: String) -> Bool {
        let lowercased = svg.lowercased()
        guard lowercased.contains("<svg"),
              !lowercased.contains("<!doctype"),
              !lowercased.contains("<!entity"),
              !lowercased.contains("<?xml-stylesheet"),
              !lowercased.contains("<script"),
              !lowercased.contains("<foreignobject"),
              !lowercased.contains("<iframe"),
              !lowercased.contains("<object"),
              !lowercased.contains("<embed"),
              !lowercased.contains("<image"),
              !lowercased.contains("javascript:"),
              !lowercased.contains("data:text/html"),
              !lowercased.contains("url("),
              !lowercased.contains("xlink:href"),
              !lowercased.contains(" href="),
              !lowercased.contains(" src=") else {
            return false
        }

        return svg.range(
            of: #"\son[a-zA-Z]+\s*="#,
            options: .regularExpression
        ) == nil
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
        case "mailto":
            return .mailto
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
        case .mailto, .relativeOrFragment, .blocked:
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
                if isLocalAbsolutePath(value) {
                    return true
                }
                let classification = classifyURL(value, allowsImageData: true)
                return !value.hasPrefix("//")
                    && classification != .httpOrHTTPS
                    && classification != .relativeOrFragment
            }
    }

    private func httpsUpgradedImageSrcset(_ value: String) -> String? {
        let candidates = value.split(separator: ",", omittingEmptySubsequences: false)
        guard !candidates.isEmpty else { return nil }

        var changed = false
        let upgradedCandidates = candidates.map { candidate -> String in
            let parts = candidate.trimmingCharacters(in: .whitespacesAndNewlines).split(
                separator: " ",
                omittingEmptySubsequences: false
            )
            guard let first = parts.first,
                  let upgradedURL = httpsUpgradedImageURL(String(first)) else {
                return String(candidate)
            }

            changed = true
            return ([upgradedURL] + parts.dropFirst().map(String.init)).joined(separator: " ")
        }

        return changed ? upgradedCandidates.joined(separator: ", ") : nil
    }

    private func httpsUpgradedImageURL(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "http" else {
            return nil
        }

        var upgraded = components
        upgraded.scheme = "https"
        return upgraded.string
    }

    private func isLocalAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.hasPrefix("//")
    }

    private func isSafeImageDataURL(_ value: String) -> Bool {
        if value.range(
            of: #"^data:image/(gif|png|jpeg|webp);base64,[A-Za-z0-9+/=]+$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }

        let svgPrefix = "data:image/svg+xml;base64,"
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(svgPrefix) else {
            return false
        }

        let encoded = String(trimmed.dropFirst(svgPrefix.count))
        guard encoded.range(
            of: #"^[A-Za-z0-9+/=]+$"#,
            options: .regularExpression
        ) != nil,
              let data = Data(base64Encoded: encoded),
              let svg = String(data: data, encoding: .utf8) else {
            return false
        }

        return isSafeSVGImage(svg)
    }

    private enum URLClassification {
        case httpOrHTTPS
        case mailto
        case relativeOrFragment
        case blocked
    }
}
