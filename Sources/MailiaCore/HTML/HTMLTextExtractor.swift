import Foundation
import SwiftSoup

public struct HTMLTextExtractor: Sendable {
    private static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "br", "center", "dd", "div", "dl", "dt",
        "figcaption", "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header",
        "hr", "li", "main", "ol", "p", "pre", "section", "table", "tbody", "td", "tfoot",
        "th", "thead", "tr", "ul"
    ]
    private static let ignoredTags: Set<String> = [
        "base", "head", "link", "meta", "noscript", "script", "style", "template", "title"
    ]

    public init() {}

    public func previewText(from html: String) -> String? {
        extractText(from: html).compactedPreviewText.nilIfBlank
    }

    public func extractText(from html: String) -> String {
        do {
            let document = try SwiftSoup.parseBodyFragment(html)
            guard let body = document.body() else { return "" }
            var output = ""
            appendText(from: body, into: &output)
            return output.normalizedExtractedText
        } catch {
            return ""
        }
    }

    private func appendText(from node: Node, into output: inout String) {
        if let textNode = node as? TextNode {
            output.append(textNode.getWholeText())
            return
        }

        guard let element = node as? Element else {
            for child in node.getChildNodes() {
                appendText(from: child, into: &output)
            }
            return
        }

        let tag = element.tagNameNormal()
        guard !Self.ignoredTags.contains(tag), !isHidden(element) else {
            return
        }

        if tag == "br" {
            appendLineBreak(to: &output)
            return
        }

        let isBlock = Self.blockTags.contains(tag)
        if isBlock {
            appendLineBreak(to: &output)
        }
        for child in element.getChildNodes() {
            appendText(from: child, into: &output)
        }
        if isBlock {
            appendLineBreak(to: &output)
        }
    }

    private func isHidden(_ element: Element) -> Bool {
        let hiddenAttribute = (try? element.attr("hidden")) ?? ""
        if !hiddenAttribute.isEmpty {
            return true
        }

        let ariaHidden = ((try? element.attr("aria-hidden")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if ariaHidden.caseInsensitiveCompare("true") == .orderedSame {
            return true
        }

        let style = ((try? element.attr("style")) ?? "").lowercased()
        return style
            .split(separator: ";")
            .compactMap { declaration -> (String, String)? in
                let parts = declaration.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard parts.count == 2 else { return nil }
                return (parts[0], parts[1])
            }
            .contains { property, value in
                switch property {
                case "display":
                    value == "none"
                case "visibility":
                    value == "hidden" || value == "collapse"
                case "opacity", "font-size", "max-height", "max-width":
                    value.hasPrefix("0")
                default:
                    false
                }
            }
    }

    private func appendLineBreak(to output: inout String) {
        guard !output.isEmpty, output.last != "\n" else { return }
        output.append("\n")
    }
}

private extension String {
    var normalizedExtractedText: String {
        replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { line in
                line
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var compactedPreviewText: String {
        replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
