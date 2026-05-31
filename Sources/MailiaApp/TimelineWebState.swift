import Foundation
import AppKit

struct TimelineWebState: Codable, Equatable, Sendable {
    var entity: Entity?
    var items: [Item]
    var isLoadingTimeline: Bool
    var isLoadingOlderTimeline: Bool
    var isLoadingNewerTimeline: Bool
    var hasOlderTimeline: Bool
    var hasNewerTimeline: Bool
    var bodyStates: [String: BodyState]
    var attachmentDownloadStates: [String: AttachmentDownloadState]
    var replySendState: ReplySendState
    var sendAccounts: [SendAccount]
    var selectedSendAccountKey: String?
    var scrollAnchor: ScrollAnchor?
    var bodyDisplayMode: String
    var loadRemoteContent: Bool
    var showTimelineAvatars: Bool

    init(
        entity: Entity?,
        items: [Item],
        isLoadingTimeline: Bool,
        isLoadingOlderTimeline: Bool,
        isLoadingNewerTimeline: Bool,
        hasOlderTimeline: Bool,
        hasNewerTimeline: Bool,
        bodyStates: [String: BodyState] = [:],
        attachmentDownloadStates: [String: AttachmentDownloadState] = [:],
        replySendState: ReplySendState = .idle,
        sendAccounts: [SendAccount] = [],
        selectedSendAccountKey: String? = nil,
        scrollAnchor: ScrollAnchor? = nil,
        bodyDisplayMode: String = "html",
        loadRemoteContent: Bool = false,
        showTimelineAvatars: Bool = true
    ) {
        self.entity = entity
        self.items = items
        self.isLoadingTimeline = isLoadingTimeline
        self.isLoadingOlderTimeline = isLoadingOlderTimeline
        self.isLoadingNewerTimeline = isLoadingNewerTimeline
        self.hasOlderTimeline = hasOlderTimeline
        self.hasNewerTimeline = hasNewerTimeline
        self.bodyStates = bodyStates
        self.attachmentDownloadStates = attachmentDownloadStates
        self.replySendState = replySendState
        self.sendAccounts = sendAccounts
        self.selectedSendAccountKey = selectedSendAccountKey
        self.scrollAnchor = scrollAnchor
        self.bodyDisplayMode = bodyDisplayMode
        self.loadRemoteContent = loadRemoteContent
        self.showTimelineAvatars = showTimelineAvatars
    }
}

extension TimelineWebState {
    struct Entity: Codable, Equatable, Sendable {
        var id: Int64
        var displayName: String
        var primaryEmailAddress: String?
        var emailAddresses: [String]
        var kind: String
        var unreadCount: Int
        var latestSubject: String
        var latestDate: Date?
        var accountLabel: String
        var workspace: String
        var avatarImageDataURL: String?
    }

    struct Item: Codable, Equatable, Sendable {
        var id: Int64
        var entityID: Int64
        var direction: String
        var subject: String
        var preview: String
        var html: String?
        var date: Date?
        var accountLabel: String
        var folderLabel: String
        var envelopeID: String
        var isFlagged: Bool
        var fromLabel: String
        var toLabel: String
        var hasAttachments: Bool
    }

    struct SendAccount: Codable, Equatable, Sendable {
        var id: String
        var label: String
        var emailAddress: String?
        var isDefault: Bool
        var emoji: String?
    }

    enum BodyState: Codable, Equatable, Sendable {
        case notRequested
        case loading
        case loaded(Body)
        case failed(String)

        private enum CodingKeys: String, CodingKey {
            case status
            case body
            case message
        }

        private enum Status: String, Codable {
            case notRequested
            case loading
            case loaded
            case failed
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let status = try container.decode(Status.self, forKey: .status)
            switch status {
            case .notRequested:
                self = .notRequested
            case .loading:
                self = .loading
            case .loaded:
                self = .loaded(try container.decode(Body.self, forKey: .body))
            case .failed:
                self = .failed(try container.decode(String.self, forKey: .message))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .notRequested:
                try container.encode(Status.notRequested, forKey: .status)
            case .loading:
                try container.encode(Status.loading, forKey: .status)
            case .loaded(let body):
                try container.encode(Status.loaded, forKey: .status)
                try container.encode(body, forKey: .body)
            case .failed(let message):
                try container.encode(Status.failed, forKey: .status)
                try container.encode(message, forKey: .message)
            }
        }
    }

    struct Body: Codable, Equatable, Sendable {
        var html: String?
        var text: String?
    }

    enum AttachmentDownloadState: Codable, Equatable, Sendable {
        case idle
        case downloading
        case downloaded(AttachmentDownloadResult)
        case failed(String)

        private enum CodingKeys: String, CodingKey {
            case status
            case result
            case message
        }

        private enum Status: String, Codable {
            case idle
            case downloading
            case downloaded
            case failed
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let status = try container.decode(Status.self, forKey: .status)
            switch status {
            case .idle:
                self = .idle
            case .downloading:
                self = .downloading
            case .downloaded:
                self = .downloaded(try container.decode(AttachmentDownloadResult.self, forKey: .result))
            case .failed:
                self = .failed(try container.decode(String.self, forKey: .message))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .idle:
                try container.encode(Status.idle, forKey: .status)
            case .downloading:
                try container.encode(Status.downloading, forKey: .status)
            case .downloaded(let result):
                try container.encode(Status.downloaded, forKey: .status)
                try container.encode(result, forKey: .result)
            case .failed(let message):
                try container.encode(Status.failed, forKey: .status)
                try container.encode(message, forKey: .message)
            }
        }
    }

    struct AttachmentDownloadResult: Codable, Equatable, Sendable {
        var directoryPath: String
        var fileNames: [String]
    }

    enum ReplySendState: Codable, Equatable, Sendable {
        case idle
        case sending
        case sent
        case failed(String)

        private enum CodingKeys: String, CodingKey {
            case status
            case message
        }

        private enum Status: String, Codable {
            case idle
            case sending
            case sent
            case failed
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let status = try container.decode(Status.self, forKey: .status)
            switch status {
            case .idle:
                self = .idle
            case .sending:
                self = .sending
            case .sent:
                self = .sent
            case .failed:
                self = .failed(try container.decode(String.self, forKey: .message))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .idle:
                try container.encode(Status.idle, forKey: .status)
            case .sending:
                try container.encode(Status.sending, forKey: .status)
            case .sent:
                try container.encode(Status.sent, forKey: .status)
            case .failed(let message):
                try container.encode(Status.failed, forKey: .status)
                try container.encode(message, forKey: .message)
            }
        }
    }

    struct ScrollAnchor: Codable, Equatable, Sendable {
        enum Edge: String, Codable, Sendable {
            case top
            case bottom
        }

        var id: Int64
        var edge: Edge
        var generation: Int
    }
}

extension TimelineWebState {
    init(
        entity: MailiaEntitySummary?,
        items: [MailiaTimelineItem],
        isLoadingTimeline: Bool,
        isLoadingOlderTimeline: Bool,
        isLoadingNewerTimeline: Bool,
        hasOlderTimeline: Bool,
        hasNewerTimeline: Bool,
        bodyStates: [Int64: MailiaTimelineBodyState],
        attachmentDownloadStates: [Int64: MailiaAttachmentDownloadState],
        replySendState: MailiaReplySendState = .idle,
        sendAccounts: [MailiaSendAccount] = [],
        selectedSendAccountKey: String? = nil,
        scrollAnchor: MailiaTimelineScrollAnchor?,
        bodyDisplayMode: String = "html",
        loadRemoteContent: Bool = false,
        showTimelineAvatars: Bool = true
    ) {
        self.init(
            entity: entity.map(Entity.init),
            items: items.map(Item.init),
            isLoadingTimeline: isLoadingTimeline,
            isLoadingOlderTimeline: isLoadingOlderTimeline,
            isLoadingNewerTimeline: isLoadingNewerTimeline,
            hasOlderTimeline: hasOlderTimeline,
            hasNewerTimeline: hasNewerTimeline,
            bodyStates: bodyStates.reduce(into: [:]) { result, entry in
                result[String(entry.key)] = BodyState(entry.value)
            },
            attachmentDownloadStates: attachmentDownloadStates.reduce(into: [:]) { result, entry in
                result[String(entry.key)] = AttachmentDownloadState(entry.value)
            },
            replySendState: ReplySendState(replySendState),
            sendAccounts: sendAccounts.map(SendAccount.init),
            selectedSendAccountKey: selectedSendAccountKey,
            scrollAnchor: scrollAnchor.map(ScrollAnchor.init),
            bodyDisplayMode: bodyDisplayMode,
            loadRemoteContent: loadRemoteContent,
            showTimelineAvatars: showTimelineAvatars
        )
    }
}

extension TimelineWebState.SendAccount {
    init(_ account: MailiaSendAccount) {
        self.init(
            id: account.id,
            label: account.label,
            emailAddress: account.emailAddress,
            isDefault: account.isDefault,
            emoji: account.emoji
        )
    }
}

extension TimelineWebState.Entity {
    init(_ entity: MailiaEntitySummary) {
        self.init(
            id: entity.id,
            displayName: entity.displayName,
            primaryEmailAddress: entity.primaryEmailAddress,
            emailAddresses: entity.emailAddresses,
            kind: entity.kind.rawValue,
            unreadCount: entity.unreadCount,
            latestSubject: entity.latestSubject,
            latestDate: entity.latestDate,
            accountLabel: entity.accountLabel,
            workspace: entity.workspace.rawValue,
            avatarImageDataURL: entity.avatarImageDataURL ?? EntityAvatarRenderer.dataURL(
                id: entity.id,
                displayName: entity.displayName
            )
        )
    }
}

extension TimelineWebState.Item {
    init(_ item: MailiaTimelineItem) {
        self.init(
            id: item.id,
            entityID: item.entityID,
            direction: item.direction.rawValue,
            subject: item.subject,
            preview: item.preview,
            html: item.html,
            date: item.date,
            accountLabel: item.accountLabel,
            folderLabel: item.folderLabel,
            envelopeID: item.envelopeID,
            isFlagged: item.isFlagged,
            fromLabel: item.fromLabel,
            toLabel: item.toLabel,
            hasAttachments: item.hasAttachments
        )
    }
}

extension TimelineWebState.BodyState {
    init(_ state: MailiaTimelineBodyState) {
        switch state {
        case .notRequested:
            self = .notRequested
        case .loading:
            self = .loading
        case .loaded(let body):
            self = .loaded(TimelineWebState.Body(body))
        case .failed(let message):
            self = .failed(message)
        }
    }
}

extension TimelineWebState.Body {
    init(_ body: MailiaTimelineBody) {
        self.init(html: body.html, text: body.text)
    }
}

extension TimelineWebState.AttachmentDownloadState {
    init(_ state: MailiaAttachmentDownloadState) {
        switch state {
        case .idle:
            self = .idle
        case .downloading:
            self = .downloading
        case .downloaded(let result):
            self = .downloaded(TimelineWebState.AttachmentDownloadResult(result))
        case .failed(let message):
            self = .failed(message)
        }
    }
}

extension TimelineWebState.AttachmentDownloadResult {
    init(_ result: MailiaAttachmentDownloadResult) {
        self.init(directoryPath: result.directoryPath, fileNames: result.fileNames)
    }
}

extension TimelineWebState.ReplySendState {
    init(_ state: MailiaReplySendState) {
        switch state {
        case .idle:
            self = .idle
        case .sending:
            self = .sending
        case .sent:
            self = .sent
        case .failed(let message):
            self = .failed(message)
        }
    }
}

extension TimelineWebState.ScrollAnchor {
    init(_ anchor: MailiaTimelineScrollAnchor) {
        let edge: Edge
        switch anchor.edge {
        case .top:
            edge = .top
        case .bottom:
            edge = .bottom
        }

        self.init(id: anchor.id, edge: edge, generation: anchor.generation)
    }
}

enum EntityAvatarRenderer {
    static let defaultSize: CGFloat = 34
    private static let dataURLSize: CGFloat = 96

    static func dataURL(id: Int64, displayName: String) -> String? {
        guard let pngData = pngData(id: id, displayName: displayName, size: dataURLSize) else {
            return nil
        }

        return "data:image/png;base64,\(pngData.base64EncodedString())"
    }

    static func image(id: Int64, displayName: String, size: CGFloat = defaultSize) -> NSImage? {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: image.size).fill()

        let bounds = NSRect(origin: .zero, size: image.size)
        let path = NSBezierPath(ovalIn: bounds)
        color(id: id, displayName: displayName).setFill()
        path.fill()

        drawText(initials(displayName: displayName), in: bounds)

        return image
    }

    private static func pngData(id: Int64, displayName: String, size: CGFloat) -> Data? {
        guard let image = image(id: id, displayName: displayName, size: size),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }

    private static func initials(displayName: String) -> String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "?" }

        let token = name
            .split(whereSeparator: { $0.isAvatarTokenSeparator })
            .map(String.init)
            .first ?? name

        if token.allSatisfy(\.isHanCharacter) {
            if token.count >= 4 {
                let firstLine = String(token.prefix(2))
                let secondLine = String(token.dropFirst(2).prefix(2))
                return "\(firstLine)\n\(secondLine)"
            }
            return String(token.prefix(3))
        }

        return String(token.prefix(6))
    }

    private static func drawText(_ text: String, in bounds: NSRect) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count > 1 {
            drawMultilineText(lines, in: bounds)
        } else {
            drawSingleLineText(text, in: bounds)
        }
    }

    private static func drawSingleLineText(_ text: String, in bounds: NSRect) {
        let maxWidth = bounds.width - 7
        let maxHeight = bounds.height - 8
        var fontSize = singleLineFontSize(characterCount: text.count, size: bounds.width)
        var attributes = textAttributes(fontSize: fontSize)
        var textSize = NSString(string: text).size(withAttributes: attributes)

        if textSize.width > maxWidth {
            fontSize *= maxWidth / textSize.width
            attributes = textAttributes(fontSize: fontSize)
            textSize = NSString(string: text).size(withAttributes: attributes)
        }
        if textSize.height > maxHeight {
            fontSize *= maxHeight / textSize.height
            attributes = textAttributes(fontSize: fontSize)
            textSize = NSString(string: text).size(withAttributes: attributes)
        }

        NSString(string: text).draw(
            at: NSPoint(
                x: bounds.midX - textSize.width / 2,
                y: bounds.midY - textSize.height / 2
            ),
            withAttributes: attributes
        )
    }

    private static func drawMultilineText(_ lines: [String], in bounds: NSRect) {
        let maxWidth = bounds.width - 8
        let maxHeight = bounds.height - 8
        var fontSize = bounds.width * 0.31
        var attributes = textAttributes(fontSize: fontSize)
        var lineSizes = lines.map { NSString(string: $0).size(withAttributes: attributes) }
        var totalHeight = lineSizes.reduce(0) { $0 + $1.height } - CGFloat(max(0, lines.count - 1))

        let widestLine = lineSizes.map(\.width).max() ?? 0
        let widthScale = widestLine > 0 ? min(1, maxWidth / widestLine) : 1
        let heightScale = totalHeight > 0 ? min(1, maxHeight / totalHeight) : 1
        let scale = min(widthScale, heightScale)
        if scale < 1 {
            fontSize *= scale
            attributes = textAttributes(fontSize: fontSize)
            lineSizes = lines.map { NSString(string: $0).size(withAttributes: attributes) }
            totalHeight = lineSizes.reduce(0) { $0 + $1.height } - CGFloat(max(0, lines.count - 1))
        }

        var y = bounds.midY - totalHeight / 2
        for (line, lineSize) in zip(lines, lineSizes) {
            NSString(string: line).draw(
                at: NSPoint(
                    x: bounds.midX - lineSize.width / 2,
                    y: y
                ),
                withAttributes: attributes
            )
            y += lineSize.height - 1
        }
    }

    private static func textAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
    }

    private static func singleLineFontSize(characterCount: Int, size: CGFloat) -> CGFloat {
        switch characterCount {
        case 0...1:
            return size * 0.44
        case 2:
            return size * 0.40
        case 3:
            return size * 0.34
        case 4:
            return size * 0.31
        case 5:
            return size * 0.285
        default:
            return size * 0.265
        }
    }

    private static func color(id: Int64, displayName: String) -> NSColor {
        let seed = "\(id)-\(displayName)"
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let hue = CGFloat(Double(hash % 360) / 360.0)
        return NSColor(calibratedHue: hue, saturation: 0.58, brightness: 0.74, alpha: 1)
    }
}

private extension Character {
    var isAvatarTokenSeparator: Bool {
        isWhitespace || self == "-" || self == "_" || self == "."
    }

    var isHanCharacter: Bool {
        unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0x20000...0x2A6DF).contains(scalar.value)
                || (0x2A700...0x2B73F).contains(scalar.value)
                || (0x2B740...0x2B81F).contains(scalar.value)
                || (0x2B820...0x2CEAF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
        }
    }
}

enum TimelineWebEvent: Equatable, Sendable {
    case ready
    case requestOlder
    case requestNewer
    case requestBody(messageID: Int64, priority: Int?)
    case sendReply(messageID: Int64, body: String, replyAll: Bool, accountKey: String?)
    case selectSendAccount(accountKey: String)
    case setMessageFlag(messageID: Int64, isFlagged: Bool)
    case downloadAttachments(messageID: Int64)
    case entityAction(action: String, entityID: Int64?)
    case scrollAnchor(messageID: Int64, edge: TimelineWebState.ScrollAnchor.Edge)
    case log(level: String, message: String)
    case unknown(type: String, payload: TimelineWebJSONValue?)
}

struct TimelineWebEventEnvelope: Decodable, Equatable, Sendable {
    var type: String
    var payload: TimelineWebJSONValue?
}

extension TimelineWebEvent {
    init(envelope: TimelineWebEventEnvelope) throws {
        switch envelope.type {
        case "ready":
            self = .ready
        case "requestOlder":
            self = .requestOlder
        case "requestNewer":
            self = .requestNewer
        case "requestBody":
            let payload = try envelope.payloadObject(as: MessagePayload.self)
            self = .requestBody(messageID: payload.messageID, priority: payload.bodyPriority)
        case "sendReply":
            let payload = try envelope.payloadObject(as: SendReplyPayload.self)
            self = .sendReply(
                messageID: payload.messageID,
                body: payload.body,
                replyAll: payload.replyAll ?? false,
                accountKey: payload.accountKey
            )
        case "selectSendAccount":
            let payload = try envelope.payloadObject(as: SelectSendAccountPayload.self)
            self = .selectSendAccount(accountKey: payload.accountKey)
        case "setMessageFlag":
            let payload = try envelope.payloadObject(as: SetMessageFlagPayload.self)
            self = .setMessageFlag(messageID: payload.messageID, isFlagged: payload.isFlagged)
        case "downloadAttachments":
            let payload = try envelope.payloadObject(as: MessagePayload.self)
            self = .downloadAttachments(messageID: payload.messageID)
        case "entityAction":
            let payload = try envelope.payloadObject(as: EntityActionPayload.self)
            self = .entityAction(action: payload.action, entityID: payload.entityID)
        case "scrollAnchor":
            let payload = try envelope.payloadObject(as: ScrollAnchorPayload.self)
            self = .scrollAnchor(messageID: payload.messageID, edge: payload.edge)
        case "log":
            let payload = try envelope.payloadObject(as: LogPayload.self)
            self = .log(level: payload.level, message: payload.message)
        default:
            self = .unknown(type: envelope.type, payload: envelope.payload)
        }
    }

    private struct MessagePayload: Decodable {
        var messageID: Int64
        var bodyPriority: Int?

        private enum CodingKeys: String, CodingKey {
            case messageID
            case id
            case bodyPriority
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let messageID = try container.decodeIfPresent(Int64.self, forKey: .messageID) {
                self.messageID = messageID
            } else {
                self.messageID = try container.decode(Int64.self, forKey: .id)
            }
            self.bodyPriority = try container.decodeIfPresent(Int.self, forKey: .bodyPriority)
        }
    }

    private struct SetMessageFlagPayload: Decodable {
        var messageID: Int64
        var isFlagged: Bool

        private enum CodingKeys: String, CodingKey {
            case messageID
            case id
            case isFlagged
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let messageID = try container.decodeIfPresent(Int64.self, forKey: .messageID) {
                self.messageID = messageID
            } else {
                self.messageID = try container.decode(Int64.self, forKey: .id)
            }
            self.isFlagged = try container.decode(Bool.self, forKey: .isFlagged)
        }
    }

    private struct SendReplyPayload: Decodable {
        var messageID: Int64
        var body: String
        var replyAll: Bool?
        var accountKey: String?

        private enum CodingKeys: String, CodingKey {
            case messageID
            case id
            case body
            case replyAll
            case accountKey
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let messageID = try container.decodeIfPresent(Int64.self, forKey: .messageID) {
                self.messageID = messageID
            } else {
            self.messageID = try container.decode(Int64.self, forKey: .id)
            }
            self.body = try container.decode(String.self, forKey: .body)
            self.replyAll = try container.decodeIfPresent(Bool.self, forKey: .replyAll)
            self.accountKey = try container.decodeIfPresent(String.self, forKey: .accountKey)
        }
    }

    private struct SelectSendAccountPayload: Decodable {
        var accountKey: String
    }

    private struct EntityActionPayload: Decodable {
        var action: String
        var entityID: Int64?
    }

    private struct ScrollAnchorPayload: Decodable {
        var messageID: Int64
        var edge: TimelineWebState.ScrollAnchor.Edge

        private enum CodingKeys: String, CodingKey {
            case messageID
            case id
            case edge
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let messageID = try container.decodeIfPresent(Int64.self, forKey: .messageID) {
                self.messageID = messageID
            } else {
                self.messageID = try container.decode(Int64.self, forKey: .id)
            }
            self.edge = try container.decode(TimelineWebState.ScrollAnchor.Edge.self, forKey: .edge)
        }
    }

    private struct LogPayload: Decodable {
        var level: String
        var message: String
    }
}

extension TimelineWebEventEnvelope {
    func event() throws -> TimelineWebEvent {
        try TimelineWebEvent(envelope: self)
    }

    fileprivate func payloadObject<T: Decodable>(as type: T.Type) throws -> T {
        guard let payload else {
            throw TimelineWebEventDecodingError.missingPayload(type: self.type)
        }

        let data = try JSONEncoder.timelineWeb.encode(payload)
        return try JSONDecoder.timelineWeb.decode(T.self, from: data)
    }
}

enum TimelineWebEventDecodingError: Error, LocalizedError, Equatable {
    case missingPayload(type: String)
    case unsupportedMessageBody

    var errorDescription: String? {
        switch self {
        case .missingPayload(let type):
            "Missing payload for timeline web event '\(type)'."
        case .unsupportedMessageBody:
            "Unsupported timeline web message body."
        }
    }
}

enum TimelineWebJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: TimelineWebJSONValue])
    case array([TimelineWebJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([TimelineWebJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: TimelineWebJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

extension JSONEncoder {
    static var timelineWeb: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var timelineWeb: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
