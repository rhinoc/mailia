import Foundation

public struct HimalayaAccountDTO: Decodable, Equatable, Sendable {
    public var name: String
    public var backend: String?
    public var isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case backend
        case isDefault = "default"
    }
}

public struct HimalayaFolderDTO: Decodable, Equatable, Sendable {
    public var name: String
    public var desc: String?
}

public struct HimalayaAddressDTO: Decodable, Equatable, Sendable {
    public var name: String?
    public var addr: String
}

public struct HimalayaEnvelopeDTO: Decodable, Equatable, Sendable {
    public var id: String
    public var flags: [String]
    public var subject: String?
    public var from: HimalayaAddressDTO?
    public var to: HimalayaAddressDTO?
    public var date: String?
    public var hasAttachment: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case flags
        case subject
        case from
        case to
        case date
        case hasAttachment = "has_attachment"
    }
}

public enum Workspace: String, Codable, CaseIterable, Sendable {
    case main
    case junk
    case flagged
}

public struct EntityListItem: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var displayName: String
    public var primaryEmailAddress: String?
    public var emailAddresses: [String]
    public var latestSubject: String?
    public var latestBodyPreview: String?
    public var latestDate: Date?
    public var unreadCount: Int
    public var accountKeys: [String]

    public init(
        id: Int64,
        displayName: String,
        primaryEmailAddress: String? = nil,
        emailAddresses: [String] = [],
        latestSubject: String? = nil,
        latestBodyPreview: String? = nil,
        latestDate: Date? = nil,
        unreadCount: Int = 0,
        accountKeys: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.primaryEmailAddress = primaryEmailAddress
        self.emailAddresses = emailAddresses
        self.latestSubject = latestSubject
        self.latestBodyPreview = latestBodyPreview
        self.latestDate = latestDate
        self.unreadCount = unreadCount
        self.accountKeys = accountKeys
    }
}

public struct TimelineMessageItem: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var subject: String?
    public var bodyHTML: String?
    public var bodyText: String?
    public var date: Date?
    public var direction: MessageDirection
    public var accountKey: String
    public var folderName: String
    public var envelopeID: String
    public var fromDisplay: String?
    public var toDisplay: String?
    public var hasAttachments: Bool
    public var isUnread: Bool

    public init(
        id: Int64,
        subject: String? = nil,
        bodyHTML: String? = nil,
        bodyText: String? = nil,
        date: Date? = nil,
        direction: MessageDirection,
        accountKey: String,
        folderName: String,
        envelopeID: String,
        fromDisplay: String? = nil,
        toDisplay: String? = nil,
        hasAttachments: Bool = false,
        isUnread: Bool = false
    ) {
        self.id = id
        self.subject = subject
        self.bodyHTML = bodyHTML
        self.bodyText = bodyText
        self.date = date
        self.direction = direction
        self.accountKey = accountKey
        self.folderName = folderName
        self.envelopeID = envelopeID
        self.fromDisplay = fromDisplay
        self.toDisplay = toDisplay
        self.hasAttachments = hasAttachments
        self.isUnread = isUnread
    }
}

public enum FolderClassifier {
    public static func role(for folder: HimalayaFolderDTO) -> FolderRole {
        let name = folder.name.lowercased()
        let desc = folder.desc?.lowercased() ?? ""

        if desc.contains("\\junk") || name.contains("junk") || name.contains("spam") || name.contains("垃圾") {
            return .junk
        }
        if desc.contains("\\trash") || name.contains("trash") || name.contains("deleted") || name.contains("已删除") {
            return .trash
        }
        if desc.contains("\\draft") || name.contains("draft") || name.contains("草稿") {
            return .drafts
        }
        if name.contains("outbox") {
            return .outbox
        }
        if desc.contains("\\sent") || name.contains("sent") || name.contains("已发") {
            return .sent
        }
        return .normal
    }

    public static func isDefaultSyncEnabled(role: FolderRole) -> Bool {
        switch role {
        case .normal, .sent, .junk:
            true
        case .trash, .drafts, .outbox, .unknown:
            false
        }
    }
}

public enum HimalayaDateParser {
    public static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else {
            return nil
        }

        for formatter in formatters {
            if let date = formatter.date(from: value) {
                return date
            }
        }

        return ISO8601DateFormatter().date(from: value)
    }

    private static let formatters: [DateFormatter] = {
        let formats = [
            "yyyy-MM-dd HH:mmXXXXX",
            "yyyy-MM-dd HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        ]

        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }
    }()
}
