public enum FolderRole: String, Codable, CaseIterable, Sendable {
    case normal
    case sent
    case junk
    case trash
    case drafts
    case outbox
    case unknown
}

public enum MessageDirection: String, Codable, CaseIterable, Sendable {
    case incoming
    case outgoing
}

public enum EntityKind: String, Codable, CaseIterable, Sendable {
    case person
    case organization
    case service
    case newsletter
    case unknown
}

public enum RelationKind: String, Codable, CaseIterable, Sendable {
    case from
    case to
    case cc
    case bcc
}

public enum ActionType: String, Codable, CaseIterable, Sendable {
    case syncRun = "sync_run"
    case markRead = "mark_read"
    case trustSender = "trust_sender"
    case moveToInbox = "move_to_inbox"
    case downloadAttachments = "download_attachments"
    case himalayaCommand = "himalaya_command"
}

public struct CacheStats: Equatable, Sendable {
    public var itemCount: Int
    public var byteSize: Int64

    public init(itemCount: Int, byteSize: Int64) {
        self.itemCount = itemCount
        self.byteSize = byteSize
    }
}
