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
}
