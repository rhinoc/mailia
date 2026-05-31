enum AccountEmojiFallback {
    private static let fallbackEmojis = ["📬", "💼", "✉️", "📮", "🧭", "⭐️", "🔖", "🪪"]

    static func emoji(for accountID: String, in accounts: [MailiaSendAccount]) -> String {
        let assignments = assignments(for: accounts)
        return assignments[accountID] ?? emoji(seed: accountID)
    }

    static func emoji(seed: String) -> String {
        fallbackEmojis[preferredIndex(seed: seed)]
    }

    private static func assignments(for accounts: [MailiaSendAccount]) -> [String: String] {
        var usedIndexes = Set<Int>()
        var assignments: [String: String] = [:]

        for account in accounts {
            guard MailiaSendAccount.normalizedEmoji(account.emoji) == nil else { continue }

            let seed = account.id.isEmpty ? account.label : account.id
            let preferred = preferredIndex(seed: seed)
            let index = availableIndex(preferred: preferred, usedIndexes: usedIndexes)
            usedIndexes.insert(index)
            assignments[account.id] = fallbackEmojis[index]
        }

        return assignments
    }

    private static func availableIndex(preferred: Int, usedIndexes: Set<Int>) -> Int {
        guard usedIndexes.count < fallbackEmojis.count else { return preferred }

        for offset in 0..<fallbackEmojis.count {
            let index = (preferred + offset) % fallbackEmojis.count
            if !usedIndexes.contains(index) {
                return index
            }
        }

        return preferred
    }

    private static func preferredIndex(seed: String) -> Int {
        let hash = seed.unicodeScalars.reduce(UInt64(5381)) { partial, scalar in
            (partial &* 33) &+ UInt64(scalar.value)
        }
        return Int(hash % UInt64(fallbackEmojis.count))
    }
}
