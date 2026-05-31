import SwiftUI
import WebKit

struct TimelineWebView: NSViewRepresentable {
    let state: TimelineWebState
    let items: [MailiaTimelineItem]
    let entity: MailiaEntitySummary?
    let onRequestBody: (MailiaTimelineItem, Int?) -> Void
    let onRequestOlder: () -> Void
    let onRequestNewer: () -> Void
    let onSetMessageFlag: (MailiaTimelineItem, Bool) -> Void
    let onDownloadAttachments: (MailiaTimelineItem) -> Void
    let onSendReply: (MailiaTimelineItem, String, Bool, String?) -> Void
    let onSelectSendAccount: (String) -> Void
    let onEntityAction: (MailiaEntityAction, MailiaEntitySummary) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let bridge = context.coordinator.bridge
        context.coordinator.apply(view: self)
        bridge.load()
        return bridge.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.apply(view: self)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.bridge.dismantle()
    }

    @MainActor
    final class Coordinator {
        let bridge = TimelineWebBridgeCoordinator()
        private var itemsByID: [Int64: MailiaTimelineItem] = [:]
        private var entity: MailiaEntitySummary?
        private var state: TimelineWebState?
        private var onRequestBody: ((MailiaTimelineItem, Int?) -> Void)?
        private var onRequestOlder: (() -> Void)?
        private var onRequestNewer: (() -> Void)?
        private var onSetMessageFlag: ((MailiaTimelineItem, Bool) -> Void)?
        private var onDownloadAttachments: ((MailiaTimelineItem) -> Void)?
        private var onSendReply: ((MailiaTimelineItem, String, Bool, String?) -> Void)?
        private var onSelectSendAccount: ((String) -> Void)?
        private var onEntityAction: ((MailiaEntityAction, MailiaEntitySummary) -> Void)?

        func apply(view: TimelineWebView) {
            itemsByID = Dictionary(uniqueKeysWithValues: view.items.map { ($0.id, $0) })
            entity = view.entity
            state = view.state
            onRequestBody = view.onRequestBody
            onRequestOlder = view.onRequestOlder
            onRequestNewer = view.onRequestNewer
            onSetMessageFlag = view.onSetMessageFlag
            onDownloadAttachments = view.onDownloadAttachments
            onSendReply = view.onSendReply
            onSelectSendAccount = view.onSelectSendAccount
            onEntityAction = view.onEntityAction

            bridge.onEvent = { [weak self] event in
                self?.handle(event)
            }
            bridge.onEventDecodingError = { error in
                NSLog("[MailiaTimelineWeb] \(error.localizedDescription)")
            }

            do {
                try bridge.pushState(view.state)
            } catch {
                NSLog("[MailiaTimelineWeb] \(error.localizedDescription)")
            }
        }

        private func handle(_ event: TimelineWebEvent) {
            switch event {
            case .ready:
                if let state {
                    do {
                        try bridge.pushState(state)
                    } catch {
                        NSLog("[MailiaTimelineWeb] \(error.localizedDescription)")
                    }
                }
            case .requestOlder:
                onRequestOlder?()
            case .requestNewer:
                onRequestNewer?()
            case .requestBody(let messageID, let priority):
                guard let item = itemsByID[messageID] else { return }
                onRequestBody?(item, priority)
            case .sendReply(let messageID, let body, let replyAll, let accountKey):
                guard let item = itemsByID[messageID] else { return }
                onSendReply?(item, body, replyAll, accountKey)
            case .selectSendAccount(let accountKey):
                onSelectSendAccount?(accountKey)
            case .setMessageFlag(let messageID, let isFlagged):
                guard let item = itemsByID[messageID] else { return }
                onSetMessageFlag?(item, isFlagged)
            case .downloadAttachments(let messageID):
                guard let item = itemsByID[messageID] else { return }
                onDownloadAttachments?(item)
            case .entityAction(let action, _):
                guard let entity, let action = Self.entityAction(named: action) else { return }
                onEntityAction?(action, entity)
            case .scrollAnchor:
                break
            case .log(let level, let message):
                NSLog("[MailiaTimelineWeb:\(level)] \(message)")
            case .unknown(let type, _):
                NSLog("[MailiaTimelineWeb] Ignoring event '\(type)'")
            }
        }

        private static func entityAction(named name: String) -> MailiaEntityAction? {
            switch name {
            case "moveToInbox":
                .moveToInbox
            case "moveToJunk":
                .moveToJunk
            case "moveToTrash":
                .moveToTrash
            case "flagImportant":
                .flagImportant
            case "removeFlag":
                .removeFlag
            default:
                nil
            }
        }
    }
}
