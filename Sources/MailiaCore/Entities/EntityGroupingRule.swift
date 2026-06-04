import Foundation

public struct SenderIdentity: Sendable, Equatable {
    public var displayName: String?
    public var email: String

    public init(displayName: String? = nil, email: String) {
        self.displayName = displayName
        self.email = email
    }
}

public struct EntityGroupingResult: Sendable, Equatable {
    public var canonicalKey: String
    public var displayName: String
    public var source: String

    public init(canonicalKey: String, displayName: String, source: String) {
        self.canonicalKey = canonicalKey
        self.displayName = displayName
        self.source = source
    }
}

public struct EntityGroupingRules: Sendable {
    private let consumerDomains: Set<String> = [
        "gmail.com",
        "googlemail.com",
        "outlook.com",
        "hotmail.com",
        "live.com",
        "icloud.com",
        "me.com",
        "mac.com",
        "mail.com",
        "yahoo.com",
        "aol.com",
        "fastmail.com",
        "proton.me",
        "protonmail.com",
        "example.com",
        "example.net",
        "example.org",
        "qq.com",
        "foxmail.com",
        "163.com",
        "126.com",
        "yeah.net",
        "sina.com",
        "sohu.com"
    ]

    private let compoundPublicSuffixes: Set<String> = [
        "com.cn",
        "net.cn",
        "org.cn",
        "edu.cn",
        "gov.cn",
        "co.uk",
        "com.au",
        "net.au",
        "co.jp",
        "ne.jp",
        "co.kr",
        "com.br",
        "com.sg",
        "com.hk",
        "com.tw"
    ]

    public init() {}

    public func group(sender: SenderIdentity) -> EntityGroupingResult {
        let normalizedEmail = sender.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = normalizedEmail.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return EntityGroupingResult(
                canonicalKey: "sender:\(normalizedEmail)",
                displayName: sender.displayName?.nilIfBlank ?? normalizedEmail,
                source: "invalid-email-fallback"
            )
        }

        let localPart = stripPlusAddress(parts[0])
        let domain = parts[1]
        let rootDomain = registrableDomain(domain)

        if !consumerDomains.contains(rootDomain) {
            return EntityGroupingResult(
                canonicalKey: "domain:\(rootDomain)",
                displayName: displayName(forDomain: rootDomain, candidateDisplayNames: [sender.displayName]),
                source: "organization-domain-rule"
            )
        }

        return EntityGroupingResult(
            canonicalKey: "sender:\(localPart)@\(domain)",
            displayName: sender.displayName?.nilIfBlank ?? "\(localPart)@\(domain)",
            source: "consumer-sender-rule"
        )
    }

    private func stripPlusAddress(_ localPart: String) -> String {
        localPart.split(separator: "+", maxSplits: 1).first.map(String.init) ?? localPart
    }

    public func displayName(forDomain domain: String, candidateDisplayNames: [String?]) -> String {
        let label = domainLabel(for: domain)

        for candidate in candidateDisplayNames {
            if let displayName = matchedDisplayNameFragment(in: candidate, domainLabel: label) {
                return displayName
            }
        }

        return fallbackDisplayName(forDomainLabel: label)
    }

    private func domainLabel(for domain: String) -> String {
        domain
            .split(separator: ".")
            .first
            .map(String.init) ?? domain
    }

    private func fallbackDisplayName(forDomainLabel label: String) -> String {
        label
            .split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private func matchedDisplayNameFragment(in displayName: String?, domainLabel: String) -> String? {
        guard let displayName = displayName?.nilIfBlank else {
            return nil
        }

        let labelKey = displayNameComparisonKey(domainLabel)
        guard !labelKey.isEmpty else {
            return nil
        }

        var candidateKey: [Character] = []
        var sourceIndices: [String.Index] = []
        var index = displayName.startIndex
        while index < displayName.endIndex {
            let character = displayName[index]
            if character.isLetter || character.isNumber {
                for lowercasedCharacter in character.lowercased() {
                    candidateKey.append(lowercasedCharacter)
                    sourceIndices.append(index)
                }
            }
            index = displayName.index(after: index)
        }

        let labelCharacters = Array(labelKey)
        guard !labelCharacters.isEmpty, labelCharacters.count <= candidateKey.count else {
            return nil
        }

        for startIndex in 0...(candidateKey.count - labelCharacters.count) {
            let endIndex = startIndex + labelCharacters.count
            if Array(candidateKey[startIndex..<endIndex]) == labelCharacters {
                let sourceStart = sourceIndices[startIndex]
                let sourceEnd = displayName.index(after: sourceIndices[endIndex - 1])
                return String(displayName[sourceStart..<sourceEnd]).nilIfBlank
            }
        }

        return nil
    }

    private func displayNameComparisonKey(_ value: String) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func registrableDomain(_ domain: String) -> String {
        let labels = domain.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return domain }
        let suffix = labels.suffix(2).joined(separator: ".")
        if compoundPublicSuffixes.contains(suffix), labels.count >= 3 {
            return labels.suffix(3).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }
        return value
    }
}
