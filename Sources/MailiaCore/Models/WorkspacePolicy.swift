public enum MailiaEntityAction: Hashable, Sendable {
    case moveToInbox
    case moveToJunk
    case moveToTrash
    case flagImportant
    case removeFlag
}

public extension MailiaEntityAction {
    var statusLabel: String {
        switch self {
        case .moveToInbox:
            "Moving to Inbox..."
        case .moveToJunk:
            "Moving to Junk..."
        case .moveToTrash:
            "Moving to Trash..."
        case .flagImportant:
            "Flagging..."
        case .removeFlag:
            "Removing flag..."
        }
    }

    func progressStatus(current: Int, total: Int) -> String {
        switch self {
        case .moveToInbox:
            "Moving \(current) of \(total) to Inbox..."
        case .moveToJunk:
            "Moving \(current) of \(total) to Junk..."
        case .moveToTrash:
            "Moving \(current) of \(total) to Trash..."
        case .flagImportant:
            "Flagging \(current) of \(total)..."
        case .removeFlag:
            "Removing flag \(current) of \(total)..."
        }
    }
}

public enum WorkspacePolicy {
    public static func visibleRoles(for workspace: Workspace) -> [FolderRole] {
        switch workspace {
        case .main:
            [.normal, .sent]
        case .junk:
            [.junk]
        case .flagged:
            [.normal, .sent, .junk]
        }
    }
}

public enum EntityActionPolicy {
    public static func visibleActions(for workspace: Workspace) -> [MailiaEntityAction] {
        switch workspace {
        case .main:
            [.moveToJunk, .flagImportant, .moveToTrash]
        case .junk:
            [.moveToInbox, .flagImportant, .moveToTrash]
        case .flagged:
            [.moveToJunk, .removeFlag, .moveToTrash]
        }
    }

    public static func hidesEntityInCurrentWorkspace(_ action: MailiaEntityAction, workspace: Workspace) -> Bool {
        switch action {
        case .moveToInbox, .moveToJunk, .moveToTrash:
            true
        case .flagImportant:
            false
        case .removeFlag:
            workspace == .flagged
        }
    }

    public static func sourceRoles(for action: MailiaEntityAction) -> [FolderRole] {
        switch action {
        case .moveToInbox:
            [.junk]
        case .moveToJunk:
            [.normal]
        case .moveToTrash:
            WorkspacePolicy.visibleRoles(for: .flagged)
        case .flagImportant, .removeFlag:
            WorkspacePolicy.visibleRoles(for: .flagged)
        }
    }

    public static func targetRole(for action: MailiaEntityAction) -> FolderRole? {
        switch action {
        case .moveToInbox:
            .normal
        case .moveToJunk:
            .junk
        case .moveToTrash:
            .trash
        case .flagImportant, .removeFlag:
            nil
        }
    }
}
