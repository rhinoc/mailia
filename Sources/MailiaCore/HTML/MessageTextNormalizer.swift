import Foundation

public struct MessageTextNormalizer: Sendable {
    public init() {}

    public func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !isHimalayaAttachmentPartMarker(String($0)) }
            .joined(separator: "\n")
    }

    public func removingTrailingQuotedReplyText(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        for index in lines.indices.reversed() {
            guard isReplyAttributionLine(lines[index]) else { continue }

            let followingLines = lines[(index + 1)...]
            let nonBlankFollowingLines = followingLines.filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard !nonBlankFollowingLines.isEmpty,
                  nonBlankFollowingLines.allSatisfy(isQuotedTextLine) else {
                continue
            }

            var keptLines = Array(lines[..<index])
            while keptLines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                keptLines.removeLast()
            }
            return keptLines.joined(separator: "\n")
        }

        return text
    }

    private func isHimalayaAttachmentPartMarker(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<#part "),
              trimmed.hasSuffix("<#/part>"),
              trimmed.contains(" type="),
              trimmed.contains(" filename=") else {
            return false
        }

        return true
    }

    private func isReplyAttributionLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).range(
            of: #"^On\s+.+\swrote:\s*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func isQuotedTextLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(">")
    }
}
