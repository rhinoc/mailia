import Foundation
import TOMLKit

public enum HimalayaConfigStoreError: LocalizedError, Equatable, Sendable {
    case configNotFound
    case unreadableConfig(String)
    case invalidConfig(path: String, message: String)
    case accountNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .configNotFound:
            "Unable to find the Himalaya configuration file."
        case .unreadableConfig(let path):
            "Unable to read the Himalaya configuration file at \(path)."
        case .invalidConfig(let path, let message):
            "The Himalaya configuration file at \(path) is not valid TOML: \(message)"
        case .accountNotFound(let accountKey):
            "Unable to find account \(accountKey) in the Himalaya configuration file."
        }
    }
}

public struct HimalayaConfigStore {
    private let fileManager: FileManager
    private let configuredURLs: [URL]?

    public init(fileManager: FileManager = .default, configURLs: [URL]? = nil) {
        self.fileManager = fileManager
        self.configuredURLs = configURLs
    }

    public func setDefaultAccount(accountKey: String) throws {
        let accountKey = accountKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountKey.isEmpty else {
            throw HimalayaConfigStoreError.accountNotFound(accountKey)
        }

        let urls = try configURLs()
        var documents: [(url: URL, content: String, sections: [AccountSection])] = []
        var knownAccounts = Set<String>()

        for url in urls {
            let content: String
            do {
                content = try String(contentsOf: url, encoding: .utf8)
            } catch {
                throw HimalayaConfigStoreError.unreadableConfig(url.path)
            }

            try validateTOML(content, path: url.path)
            let sections = Self.accountSections(in: content)
            knownAccounts.formUnion(sections.map(\.accountKey))
            documents.append((url: url, content: content, sections: sections))
        }

        guard knownAccounts.contains(accountKey) else {
            throw HimalayaConfigStoreError.accountNotFound(accountKey)
        }

        for document in documents {
            let updated = Self.settingDefaultAccount(
                accountKey,
                in: document.content,
                sections: document.sections
            )
            guard updated != document.content else { continue }
            try validateTOML(updated, path: document.url.path)
            try updated.write(to: document.url, atomically: true, encoding: .utf8)
        }
    }

    public func accountMetadata() throws -> [String: HimalayaConfigAccountMetadata] {
        let urls = try configURLs()
        var metadata: [String: HimalayaConfigAccountMetadata] = [:]

        for url in urls {
            let content: String
            do {
                content = try String(contentsOf: url, encoding: .utf8)
            } catch {
                throw HimalayaConfigStoreError.unreadableConfig(url.path)
            }

            let table: TOMLTable
            do {
                table = try TOMLTable(string: content)
            } catch {
                throw HimalayaConfigStoreError.invalidConfig(path: url.path, message: error.localizedDescription)
            }

            guard let accounts = table["accounts"]?.table else { continue }
            for key in accounts.keys {
                guard let accountTable = accounts[key]?.table else { continue }
                metadata[key] = HimalayaConfigAccountMetadata(
                    emailAddress: accountTable["email"]?.string?.nilIfBlank,
                    displayName: accountTable["display-name"]?.string?.nilIfBlank,
                    isDefault: accountTable["default"]?.bool
                )
            }
        }

        return metadata
    }

    public func setAccountDisplayName(accountKey: String, displayName: String?) throws {
        let accountKey = accountKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountKey.isEmpty else {
            throw HimalayaConfigStoreError.accountNotFound(accountKey)
        }

        let urls = try configURLs()
        var foundAccount = false

        for url in urls {
            let content: String
            do {
                content = try String(contentsOf: url, encoding: .utf8)
            } catch {
                throw HimalayaConfigStoreError.unreadableConfig(url.path)
            }

            try validateTOML(content, path: url.path)
            let sections = Self.accountSections(in: content)
            guard sections.contains(where: { $0.accountKey == accountKey }) else { continue }

            foundAccount = true
            let updated = Self.settingAccountDisplayName(
                displayName?.nilIfBlank,
                accountKey: accountKey,
                in: content,
                sections: sections
            )
            guard updated != content else { continue }
            try validateTOML(updated, path: url.path)
            try updated.write(to: url, atomically: true, encoding: .utf8)
        }

        guard foundAccount else {
            throw HimalayaConfigStoreError.accountNotFound(accountKey)
        }
    }

    private func configURLs() throws -> [URL] {
        if let configuredURLs {
            let urls = configuredURLs.filter { fileManager.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else { throw HimalayaConfigStoreError.configNotFound }
            return urls
        }

        if let config = ProcessInfo.processInfo.environment["HIMALAYA_CONFIG"]?.nilIfBlank {
            let urls = config
                .split(separator: ":", omittingEmptySubsequences: true)
                .map { URL(fileURLWithPath: String($0).expandingTildeInPath) }
                .filter { fileManager.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else { throw HimalayaConfigStoreError.configNotFound }
            return urls
        }

        for url in defaultConfigURLs() where fileManager.fileExists(atPath: url.path) {
            return [url]
        }

        throw HimalayaConfigStoreError.configNotFound
    }

    private func defaultConfigURLs() -> [URL] {
        var urls: [URL] = []
        let environment = ProcessInfo.processInfo.environment

        if let applicationSupportURL = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            urls.append(applicationSupportURL.appendingPathComponent("himalaya/config.toml"))
        }

        if let xdgConfigHome = environment["XDG_CONFIG_HOME"]?.nilIfBlank {
            urls.append(URL(fileURLWithPath: xdgConfigHome.expandingTildeInPath)
                .appendingPathComponent("himalaya/config.toml"))
        }

        if let home = environment["HOME"]?.nilIfBlank {
            let homeURL = URL(fileURLWithPath: home.expandingTildeInPath)
            urls.append(homeURL.appendingPathComponent(".config/himalaya/config.toml"))
            urls.append(homeURL.appendingPathComponent(".himalayarc"))
        }

        return urls
    }

    private func validateTOML(_ content: String, path: String) throws {
        do {
            _ = try TOMLTable(string: content)
        } catch {
            throw HimalayaConfigStoreError.invalidConfig(path: path, message: error.localizedDescription)
        }
    }

    private static func settingDefaultAccount(
        _ defaultAccountKey: String,
        in content: String,
        sections: [AccountSection]
    ) -> String {
        guard !sections.isEmpty else { return content }

        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let hadTrailingNewline = content.hasSuffix("\n")

        for section in sections.reversed() {
            let isDefault = section.accountKey == defaultAccountKey
            if let defaultLineIndex = section.defaultLineIndex {
                lines[defaultLineIndex] = "\(Self.leadingWhitespace(in: lines[defaultLineIndex]))default = \(isDefault ? "true" : "false")"
            } else {
                lines.insert("default = \(isDefault ? "true" : "false")", at: section.headerLineIndex + 1)
            }
        }

        var updated = lines.joined(separator: "\n")
        if hadTrailingNewline {
            updated.append("\n")
        }
        return updated
    }

    private static func settingAccountDisplayName(
        _ displayName: String?,
        accountKey: String,
        in content: String,
        sections: [AccountSection]
    ) -> String {
        guard let section = sections.first(where: { $0.accountKey == accountKey }) else {
            return content
        }

        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let hadTrailingNewline = content.hasSuffix("\n")

        if let displayName {
            let line = "display-name = \(tomlStringLiteral(displayName))"
            if let displayNameLineIndex = section.displayNameLineIndex {
                lines[displayNameLineIndex] = "\(leadingWhitespace(in: lines[displayNameLineIndex]))\(line)"
            } else {
                lines.insert(line, at: section.headerLineIndex + 1)
            }
        } else if let displayNameLineIndex = section.displayNameLineIndex {
            lines.remove(at: displayNameLineIndex)
        }

        var updated = lines.joined(separator: "\n")
        if hadTrailingNewline {
            updated.append("\n")
        }
        return updated
    }

    private static func accountSections(in content: String) -> [AccountSection] {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var sections: [AccountSection] = []
        var activeIndex: Int?

        for (index, line) in lines.enumerated() {
            if let header = tableHeader(in: line) {
                activeIndex = nil
                if header.count == 2, header[0] == "accounts" {
                    sections.append(AccountSection(
                        accountKey: header[1],
                        headerLineIndex: index,
                        defaultLineIndex: nil,
                        displayNameLineIndex: nil
                    ))
                    activeIndex = sections.indices.last
                }
                continue
            }

            guard let activeIndex else { continue }
            if assignmentKey(in: line) == "default" {
                sections[activeIndex].defaultLineIndex = index
            }
            if assignmentKey(in: line) == "display-name" {
                sections[activeIndex].displayNameLineIndex = index
            }
        }

        return sections
    }

    private static func tableHeader(in line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["),
              !trimmed.hasPrefix("[["),
              let closeIndex = matchingHeaderCloseIndex(in: trimmed)
        else {
            return nil
        }

        let afterClose = trimmed[trimmed.index(after: closeIndex)...]
        guard afterClose.trimmingCharacters(in: .whitespaces).isEmpty
                || afterClose.trimmingCharacters(in: .whitespaces).hasPrefix("#") else {
            return nil
        }

        let start = trimmed.index(after: trimmed.startIndex)
        let rawHeader = String(trimmed[start..<closeIndex])
        return splitDottedTOMLKey(rawHeader)
    }

    private static func matchingHeaderCloseIndex(in line: String) -> String.Index? {
        var quote: Character?
        var escaped = false

        for index in line.indices.dropFirst() {
            let character = line[index]
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" && activeQuote == "\"" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "]" {
                return index
            }
        }

        return nil
    }

    private static func splitDottedTOMLKey(_ key: String) -> [String]? {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var quotedPart = false

        func appendPart() -> Bool {
            let value = quotedPart ? current : current.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return false }
            parts.append(value)
            current = ""
            quotedPart = false
            return true
        }

        for character in key {
            if let activeQuote = quote {
                if escaped {
                    current.append(character)
                    escaped = false
                } else if character == "\\" && activeQuote == "\"" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
                quotedPart = true
            } else if character == "." {
                guard appendPart() else { return nil }
            } else {
                current.append(character)
            }
        }

        guard quote == nil, appendPart() else { return nil }
        return parts
    }

    private static func assignmentKey(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        var quote: Character?
        var escaped = false
        for index in trimmed.indices {
            let character = trimmed[index]
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" && activeQuote == "\"" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "=" {
                let rawKey = String(trimmed[..<index])
                guard let parts = splitDottedTOMLKey(rawKey), parts.count == 1 else {
                    return nil
                }
                return parts[0]
            }
        }

        return nil
    }

    private static func leadingWhitespace(in line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    private static func tomlStringLiteral(_ value: String) -> String {
        let escaped = value.unicodeScalars.reduce(into: "") { result, scalar in
            switch scalar {
            case "\"":
                result += "\\\""
            case "\\":
                result += "\\\\"
            case "\n":
                result += "\\n"
            case "\r":
                result += "\\r"
            case "\t":
                result += "\\t"
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }
}

public struct HimalayaConfigAccountMetadata: Equatable, Sendable {
    public var emailAddress: String?
    public var displayName: String?
    public var isDefault: Bool?

    public init(emailAddress: String? = nil, displayName: String? = nil, isDefault: Bool? = nil) {
        self.emailAddress = emailAddress
        self.displayName = displayName
        self.isDefault = isDefault
    }
}

private struct AccountSection {
    let accountKey: String
    let headerLineIndex: Int
    var defaultLineIndex: Int?
    var displayNameLineIndex: Int?
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var expandingTildeInPath: String {
        (self as NSString).expandingTildeInPath
    }
}
