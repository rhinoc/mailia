import Foundation

public struct DiscoveredAccount: Equatable, Sendable {
    public var accountKey: String
    public var emailAddress: String?
    public var providerHint: String?
    public var displayName: String?
    public var isDefault: Bool
    public var emoji: String?

    public init(
        accountKey: String,
        emailAddress: String? = nil,
        providerHint: String? = nil,
        displayName: String? = nil,
        isDefault: Bool = false,
        emoji: String? = nil
    ) {
        self.accountKey = accountKey
        self.emailAddress = emailAddress
        self.providerHint = providerHint
        self.displayName = displayName
        self.isDefault = isDefault
        self.emoji = emoji
    }
}

public struct DiscoveredFolder: Equatable, Sendable {
    public var accountKey: String
    public var providerName: String
    public var role: FolderRole

    public init(accountKey: String, providerName: String, role: FolderRole = .unknown) {
        self.accountKey = accountKey
        self.providerName = providerName
        self.role = role
    }
}

public struct MailAddress: Codable, Equatable, Sendable {
    public var displayName: String?
    public var emailAddress: String

    public init(displayName: String? = nil, emailAddress: String) {
        self.displayName = displayName
        self.emailAddress = emailAddress
    }
}

public struct EnvelopeMessage: Equatable, Sendable {
    public var accountKey: String
    public var folderName: String
    public var himalayaEnvelopeID: String
    public var rfcMessageID: String?
    public var fallbackDedupeKey: String?
    public var subject: String?
    public var from: MailAddress?
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var messageDate: String?
    public var direction: MessageDirection
    public var hasAttachments: Bool
    public var flags: [String]

    public init(
        accountKey: String,
        folderName: String,
        himalayaEnvelopeID: String,
        rfcMessageID: String? = nil,
        fallbackDedupeKey: String? = nil,
        subject: String? = nil,
        from: MailAddress? = nil,
        to: [MailAddress] = [],
        cc: [MailAddress] = [],
        messageDate: String? = nil,
        direction: MessageDirection = .incoming,
        hasAttachments: Bool = false,
        flags: [String] = []
    ) {
        self.accountKey = accountKey
        self.folderName = folderName
        self.himalayaEnvelopeID = himalayaEnvelopeID
        self.rfcMessageID = rfcMessageID
        self.fallbackDedupeKey = fallbackDedupeKey
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.messageDate = messageDate
        self.direction = direction
        self.hasAttachments = hasAttachments
        self.flags = flags
    }
}

public struct StoredFolder: Equatable, Sendable {
    public var id: Int64
    public var accountKey: String
    public var providerName: String
    public var role: FolderRole

    public init(id: Int64, accountKey: String, providerName: String, role: FolderRole) {
        self.id = id
        self.accountKey = accountKey
        self.providerName = providerName
        self.role = role
    }
}

public struct MessageLocationTarget: Equatable, Sendable {
    public var messageID: Int64
    public var accountKey: String
    public var sourceFolderName: String
    public var sourceFolderRole: FolderRole
    public var himalayaEnvelopeID: String

    public init(
        messageID: Int64,
        accountKey: String,
        sourceFolderName: String,
        sourceFolderRole: FolderRole,
        himalayaEnvelopeID: String
    ) {
        self.messageID = messageID
        self.accountKey = accountKey
        self.sourceFolderName = sourceFolderName
        self.sourceFolderRole = sourceFolderRole
        self.himalayaEnvelopeID = himalayaEnvelopeID
    }
}

public struct TimelineMessage: Equatable, Sendable {
    public var messageID: Int64
    public var accountKey: String
    public var folderName: String?
    public var himalayaEnvelopeID: String?
    public var flags: [String]
    public var subject: String?
    public var from: MailAddress?
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var messageDate: String?
    public var direction: MessageDirection
    public var hasAttachments: Bool
    public var sanitizedHTML: String?
    public var textFallback: String?

    public init(
        messageID: Int64,
        accountKey: String,
        folderName: String? = nil,
        himalayaEnvelopeID: String? = nil,
        flags: [String] = [],
        subject: String? = nil,
        from: MailAddress? = nil,
        to: [MailAddress] = [],
        cc: [MailAddress] = [],
        messageDate: String? = nil,
        direction: MessageDirection,
        hasAttachments: Bool,
        sanitizedHTML: String? = nil,
        textFallback: String? = nil
    ) {
        self.messageID = messageID
        self.accountKey = accountKey
        self.folderName = folderName
        self.himalayaEnvelopeID = himalayaEnvelopeID
        self.flags = flags
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.messageDate = messageDate
        self.direction = direction
        self.hasAttachments = hasAttachments
        self.sanitizedHTML = sanitizedHTML
        self.textFallback = textFallback
    }
}

public struct TimelineMessageBody: Equatable, Sendable {
    public var sanitizedHTML: String?
    public var textFallback: String?

    public init(sanitizedHTML: String? = nil, textFallback: String? = nil) {
        self.sanitizedHTML = sanitizedHTML
        self.textFallback = textFallback
    }
}
