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
        "icloud.com",
        "me.com",
        "mac.com",
        "yahoo.com",
        "proton.me",
        "protonmail.com"
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

        if isServiceLocalPart(localPart), !consumerDomains.contains(domain) {
            return EntityGroupingResult(
                canonicalKey: "domain:\(domain)",
                displayName: displayName(forDomain: domain),
                source: "service-domain-rule"
            )
        }

        return EntityGroupingResult(
            canonicalKey: "sender:\(localPart)@\(domain)",
            displayName: sender.displayName?.nilIfBlank ?? "\(localPart)@\(domain)",
            source: "sender-rule"
        )
    }

    private func stripPlusAddress(_ localPart: String) -> String {
        localPart.split(separator: "+", maxSplits: 1).first.map(String.init) ?? localPart
    }

    private func isServiceLocalPart(_ localPart: String) -> Bool {
        [
            "noreply",
            "no-reply",
            "notifications",
            "notification",
            "support",
            "security",
            "billing",
            "hello",
            "newsletter",
            "updates",
            "team"
        ].contains(localPart)
    }

    private func displayName(forDomain domain: String) -> String {
        domain
            .split(separator: ".")
            .first
            .map { String($0).capitalized }
            ?? domain
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
