import Foundation
import SwiftSoup

public struct HTMLDisplayNormalizer: Sendable {
    public init() {}

    public func normalize(_ html: String) -> String {
        do {
            let document = try SwiftSoup.parseBodyFragment(html)
            guard let body = document.body() else {
                return html
            }

            try removeEmptySignatureBlocks(from: body)
            let elements = Array(try body.getAllElements()).reversed()
            for element in elements {
                try trimTrailingEmptyContent(in: element)
            }

            return try body.html()
        } catch {
            return html
        }
    }

    private func removeEmptySignatureBlocks(from root: Element) throws {
        for element in try root.select("[title=hw_signature]") {
            if try isVisuallyEmpty(element) {
                try element.remove()
            }
        }
    }

    private func trimTrailingEmptyContent(in element: Element) throws {
        while let lastChild = element.getChildNodes().last,
              try isTrailingEmpty(lastChild) {
            try lastChild.remove()
        }
    }

    private func isTrailingEmpty(_ node: Node) throws -> Bool {
        if let textNode = node as? TextNode {
            return textNode.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        guard let element = node as? Element else {
            return false
        }

        let tagName = element.tagNameNormal()
        if tagName == "br" {
            return true
        }

        return try isVisuallyEmpty(element)
    }

    private func isVisuallyEmpty(_ element: Element) throws -> Bool {
        let tagName = element.tagNameNormal()
        if ["img", "svg", "canvas", "table", "hr", "iframe", "object", "embed"].contains(tagName) {
            return false
        }

        let text = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty else {
            return false
        }

        for child in element.getChildNodes() {
            if try !isTrailingEmpty(child) {
                return false
            }
        }
        return true
    }
}
