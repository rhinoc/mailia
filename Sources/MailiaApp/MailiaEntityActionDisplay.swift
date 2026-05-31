import MailiaCore
import SwiftUI

extension MailiaEntityAction {
    var label: String {
        switch self {
        case .moveToInbox:
            "Inbox"
        case .moveToJunk:
            "Junk"
        case .moveToTrash:
            "Trash"
        case .flagImportant:
            "Flag"
        case .removeFlag:
            "Unflag"
        }
    }

    var systemImage: String {
        switch self {
        case .moveToInbox:
            "tray.and.arrow.down"
        case .moveToJunk:
            "nosign"
        case .moveToTrash:
            "trash"
        case .flagImportant:
            "flag"
        case .removeFlag:
            "flag.slash"
        }
    }

    var buttonRole: ButtonRole? {
        switch self {
        case .moveToTrash:
            .destructive
        case .moveToInbox, .moveToJunk, .flagImportant, .removeFlag:
            nil
        }
    }
}
