import SwiftUI
import AppKit
import QuartzCore

fileprivate enum NewMessageComposerFocusedField: Hashable {
    case recipients
    case subject
}

private enum ComposerControlMetrics {
    static let singleLineHeight: CGFloat = 20
    static let maxInputHeight: CGFloat = 132
    static let controlSize: CGFloat = 36
    static let trailingControlWidth: CGFloat = 104
    static let statusLineHeight: CGFloat = 16
    static let multilineInputCornerRadius: CGFloat = 14
    static let inputHorizontalPadding: CGFloat = 15
    static let inputVerticalPadding: CGFloat = 8
    static let composerHorizontalPadding: CGFloat = 14
    static let composerTopPadding: CGFloat = 20
    static let composerBottomPadding: CGFloat = 20
}

enum MailiaComposerShortcut: String, CaseIterable, Identifiable, Sendable {
    case off
    case enter
    case commandEnter
    case shiftEnter

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            "Off"
        case .enter:
            "Enter"
        case .commandEnter:
            "Command+Enter"
        case .shiftEnter:
            "Shift+Enter"
        }
    }

    static var uniqueSendOptions: [MailiaComposerShortcut] {
        unique(Self.allCases)
    }

    func matches(_ event: NSEvent) -> Bool {
        guard self != .off, Self.isReturnKey(event) else { return false }

        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])

        switch self {
        case .off:
            return false
        case .enter:
            return modifiers.isEmpty
        case .commandEnter:
            return modifiers == .command
        case .shiftEnter:
            return modifiers == .shift
        }
    }

    private static func isReturnKey(_ event: NSEvent) -> Bool {
        event.keyCode == 36 || event.keyCode == 76
    }

    private static func unique(_ shortcuts: [MailiaComposerShortcut]) -> [MailiaComposerShortcut] {
        var seen = Set<String>()
        var result: [MailiaComposerShortcut] = []
        for shortcut in shortcuts {
            guard seen.insert(shortcut.rawValue).inserted else { continue }
            result.append(shortcut)
        }
        return result
    }
}

struct MailiaComposerSettings: Equatable, Sendable {
    static let defaultSendShortcut = MailiaComposerShortcut.enter
    static let defaultAllowUndoAfterSend = true
    static let defaultUndoDelaySeconds = 5
    static let allowedUndoDelaySeconds = unique([3, 5, 10, 15, 30])

    var sendShortcut: MailiaComposerShortcut = Self.defaultSendShortcut
    var allowUndoAfterSend: Bool = Self.defaultAllowUndoAfterSend
    var undoDelaySeconds: Int = Self.defaultUndoDelaySeconds

    var normalizedUndoDelaySeconds: Int {
        Self.allowedUndoDelaySeconds.contains(undoDelaySeconds) ? undoDelaySeconds : Self.defaultUndoDelaySeconds
    }

    var lineBreakShortcut: MailiaComposerShortcut {
        sendShortcut == .enter ? .shiftEnter : .enter
    }

    static func saved(defaults: UserDefaults = .standard) -> MailiaComposerSettings {
        let shortcutRawValue = defaults.string(
            forKey: MailiaPreferenceKeys.composerSendShortcut
        ) ?? Self.defaultSendShortcut.rawValue
        let sendShortcut = MailiaComposerShortcut(rawValue: shortcutRawValue) ?? Self.defaultSendShortcut
        let allowUndo = defaults.object(
            forKey: MailiaPreferenceKeys.composerAllowUndoAfterSend
        ) as? Bool ?? Self.defaultAllowUndoAfterSend
        let delay = defaults.object(
            forKey: MailiaPreferenceKeys.composerUndoDelaySeconds
        ) as? Int ?? Self.defaultUndoDelaySeconds

        return MailiaComposerSettings(
            sendShortcut: sendShortcut,
            allowUndoAfterSend: allowUndo,
            undoDelaySeconds: Self.allowedUndoDelaySeconds.contains(delay) ? delay : Self.defaultUndoDelaySeconds
        )
    }

    static func undoDelayLabel(_ seconds: Int) -> String {
        "\(seconds) seconds"
    }

    private static func unique(_ values: [Int]) -> [Int] {
        var seen = Set<Int>()
        var result: [Int] = []
        for value in values {
            guard seen.insert(value).inserted else { continue }
            result.append(value)
        }
        return result
    }
}

@propertyWrapper
struct ComposerBehaviorSettingsStorage: DynamicProperty {
    @AppStorage(MailiaPreferenceKeys.composerSendShortcut)
    private var sendShortcut = MailiaComposerSettings.defaultSendShortcut.rawValue
    @AppStorage(MailiaPreferenceKeys.composerAllowUndoAfterSend)
    private var allowUndoAfterSend = MailiaComposerSettings.defaultAllowUndoAfterSend
    @AppStorage(MailiaPreferenceKeys.composerUndoDelaySeconds)
    private var undoDelaySeconds = MailiaComposerSettings.defaultUndoDelaySeconds

    var wrappedValue: MailiaComposerSettings {
        get {
            MailiaComposerSettings(
                sendShortcut: MailiaComposerShortcut(rawValue: sendShortcut)
                    ?? MailiaComposerSettings.defaultSendShortcut,
                allowUndoAfterSend: allowUndoAfterSend,
                undoDelaySeconds: MailiaComposerSettings.allowedUndoDelaySeconds.contains(undoDelaySeconds)
                    ? undoDelaySeconds
                    : MailiaComposerSettings.defaultUndoDelaySeconds
            )
        }
        nonmutating set {
            sendShortcut = newValue.sendShortcut.rawValue
            allowUndoAfterSend = newValue.allowUndoAfterSend
            undoDelaySeconds = newValue.normalizedUndoDelaySeconds
        }
    }
}

@MainActor
private final class ComposerSendStateController<Payload>: ObservableObject {
    private enum LocalStatus {
        case idle
        case sending
        case sent
    }

    @Published private(set) var queuedPayload: Payload?
    @Published private(set) var remainingSeconds: Int

    @Published private var localStatus: LocalStatus = .idle
    private var sendTask: Task<Void, Never>?
    private var sentResetTask: Task<Void, Never>?

    init() {
        self.remainingSeconds = 0
    }

    var isQueued: Bool {
        queuedPayload != nil
    }

    var isSending: Bool {
        localStatus == .sending
    }

    var isShowingSentConfirmation: Bool {
        localStatus == .sent
    }

    func queue(
        _ payload: Payload,
        settings: MailiaComposerSettings,
        send: @escaping @MainActor (Payload) -> Void
    ) {
        sentResetTask?.cancel()
        sendTask?.cancel()
        let delaySeconds = settings.normalizedUndoDelaySeconds

        guard settings.allowUndoAfterSend, delaySeconds > 0 else {
            queuedPayload = nil
            remainingSeconds = 0
            localStatus = .sending
            send(payload)
            return
        }

        queuedPayload = payload
        remainingSeconds = delaySeconds

        sendTask = Task { @MainActor in
            for second in stride(from: delaySeconds, through: 1, by: -1) {
                remainingSeconds = second
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            queuedPayload = nil
            localStatus = .sending
            send(payload)
        }
    }

    func undo() {
        sendTask?.cancel()
        sendTask = nil
        queuedPayload = nil
        remainingSeconds = 0
    }

    func handleSendStateChange(
        _ state: MailiaReplySendState,
        onSent: () -> Void
    ) {
        switch state {
        case .sent:
            onSent()
            markSent()
        case .failed:
            localStatus = .idle
        case .idle, .sending:
            break
        }
    }

    func clearSentConfirmationIf(hasDraftContent: Bool) {
        guard localStatus == .sent, hasDraftContent else { return }
        sentResetTask?.cancel()
        localStatus = .idle
    }

    func cancel() {
        sendTask?.cancel()
        sentResetTask?.cancel()
    }

    private func markSent() {
        localStatus = .sent
        sentResetTask?.cancel()
        sentResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if Task.isCancelled { return }
            if localStatus == .sent {
                localStatus = .idle
            }
        }
    }
}

private struct SendAccountSelection {
    let sendAccounts: [MailiaSendAccount]
    let selectedSendAccountKey: String?

    var selectedAccountID: String {
        selectedSendAccountKey
            ?? sendAccounts.first(where: { $0.isDefault })?.id
            ?? sendAccounts.first?.id
            ?? ""
    }

    var selectedAccount: MailiaSendAccount? {
        sendAccounts.first { $0.id == selectedAccountID }
    }

    var currentAccountLabel: String {
        guard let account = selectedAccount else {
            return "Default"
        }
        return Self.accountLabel(account)
    }

    static func accountLabel(_ account: MailiaSendAccount) -> String {
        account.emailAddress ?? account.label
    }
}

private struct ComposerChrome<Input: View>: View {
    let statusMessage: String?
    let sendAccounts: [MailiaSendAccount]
    let selectedSendAccountKey: String?
    let isInputDisabled: Bool
    let isQueued: Bool
    let remainingSeconds: Int
    let isSending: Bool
    let isShowingSentConfirmation: Bool
    let canSend: Bool
    let onAddContent: () -> Void
    let onSend: () -> Void
    let onUndo: () -> Void
    let onSelectSendAccount: (String) -> Void
    @ViewBuilder let input: () -> Input

    var body: some View {
        VStack(spacing: 6) {
            statusLine
            composerRow
        }
        .padding(.horizontal, ComposerControlMetrics.composerHorizontalPadding)
        .padding(.top, ComposerControlMetrics.composerTopPadding)
        .padding(.bottom, ComposerControlMetrics.composerBottomPadding)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack {
            Spacer(minLength: 0)
            if let statusMessage, !isQueued {
                ComposerStatusText(text: statusMessage, isError: true)
            }
        }
        .frame(height: ComposerControlMetrics.statusLineHeight)
    }

    @ViewBuilder
    private var composerRow: some View {
        let row = HStack(alignment: .bottom, spacing: 8) {
            ComposerAddContentButton(
                isDisabled: isInputDisabled,
                onAddContent: onAddContent
            )
            input()
            if sendAccounts.count > 1 {
                SendAccountPicker(
                    sendAccounts: sendAccounts,
                    selectedSendAccountKey: selectedSendAccountKey,
                    isDisabled: isInputDisabled,
                    onSelectSendAccount: onSelectSendAccount
                )
            }
            if isQueued {
                ComposerUndoButton(
                    remainingSeconds: remainingSeconds,
                    onUndo: onUndo
                )
            } else {
                ComposerSendButton(
                    isSending: isSending,
                    isShowingSentConfirmation: isShowingSentConfirmation,
                    canSend: canSend,
                    onSend: onSend
                )
            }
        }

        GlassEffectContainer(spacing: 8) {
            row
        }
    }
}

private struct SendAccountPicker: View {
    let sendAccounts: [MailiaSendAccount]
    let selectedSendAccountKey: String?
    let isDisabled: Bool
    let onSelectSendAccount: (String) -> Void

    private var selection: SendAccountSelection {
        SendAccountSelection(
            sendAccounts: sendAccounts,
            selectedSendAccountKey: selectedSendAccountKey
        )
    }

    var body: some View {
        Menu {
            ForEach(sendAccounts) { account in
                Button {
                    onSelectSendAccount(account.id)
                } label: {
                    if account.id == selection.selectedAccountID {
                        Label(SendAccountSelection.accountLabel(account), systemImage: "checkmark")
                    } else {
                        Text(SendAccountSelection.accountLabel(account))
                    }
                }
            }
        } label: {
            AccountMenuEmojiLabel(
                account: selection.selectedAccount,
                fallbackEmoji: AccountEmojiFallback.emoji(
                    for: selection.selectedAccountID,
                    in: sendAccounts
                )
            )
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .frame(width: ComposerControlMetrics.controlSize, height: ComposerControlMetrics.controlSize)
        .contentShape(Circle())
        .modifier(GlassChrome(shape: AnyShape(Circle()), tint: nil, interactive: true))
        .fixedSize()
        .disabled(isDisabled)
        .help("Sending account: \(selection.currentAccountLabel)")
    }
}

private struct ComposerAddContentButton: View {
    let isDisabled: Bool
    let onAddContent: () -> Void

    var body: some View {
        Button(action: onAddContent) {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: ComposerControlMetrics.controlSize, height: ComposerControlMetrics.controlSize)
                .contentShape(Circle())
                .modifier(GlassChrome(shape: AnyShape(Circle()), tint: nil, interactive: true))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
        .help("Add photo or file")
    }
}

private struct ComposerUndoButton: View {
    let remainingSeconds: Int
    let onUndo: () -> Void

    var body: some View {
        Button(action: onUndo) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.uturn.backward")
                Text("Undo \(remainingSeconds)s")
                    .monospacedDigit()
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(
                width: ComposerControlMetrics.trailingControlWidth,
                height: ComposerControlMetrics.controlSize
            )
            .modifier(GlassChrome(shape: AnyShape(Capsule(style: .continuous)), tint: .red, interactive: true))
        }
        .buttonStyle(.plain)
    }
}

private struct ComposerSendButton: View {
    let isSending: Bool
    let isShowingSentConfirmation: Bool
    let canSend: Bool
    let onSend: () -> Void

    var body: some View {
        Button(action: onSend) {
            ZStack {
                if isSending {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else if isShowingSentConfirmation {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: ComposerControlMetrics.controlSize, height: ComposerControlMetrics.controlSize)
            .contentShape(Circle())
            .modifier(GlassChrome(
                shape: AnyShape(Circle()),
                tint: isShowingSentConfirmation ? .green : .blue,
                interactive: true
            ))
            .opacity(canSend || isSending || isShowingSentConfirmation ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .help("Send")
    }
}

private struct ComposerStatusText: View {
    let text: String
    let isError: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(isError ? Color(nsColor: .systemRed) : Color.secondary)
            .lineLimit(1)
            .multilineTextAlignment(.trailing)
    }
}

/// Native reply composer that occupies the bottom of the timeline pane.
///
/// On macOS 26+ the input and controls use the system Liquid Glass material so
/// the bar keeps the native control treatment. On earlier systems it falls back
/// to a translucent rounded rectangle. The input expands upward once the draft
/// wraps onto multiple lines (Shift+Enter).
struct ReplyComposerBar: View {
    let target: MailiaTimelineItem?
    let sendAccounts: [MailiaSendAccount]
    let selectedSendAccountKey: String?
    let sendState: MailiaReplySendState
    let onSend: (MailiaComposerContent, String?) -> Void
    let onSelectSendAccount: (String) -> Void
    let onEdited: () -> Void

    private static let singleLineHeight = ComposerControlMetrics.singleLineHeight
    private static let maxInputHeight = ComposerControlMetrics.maxInputHeight

    @State private var draft = NSAttributedString(string: "", attributes: ComposerTextDefaults.bodyAttributes)
    @State private var attachments: [MailiaOutgoingAttachment] = []
    @State private var textHeight: CGFloat = ReplyComposerBar.singleLineHeight
    @StateObject private var sendController = ComposerSendStateController<MailiaComposerContent>()
    @StateObject private var editorController = ComposerRichTextController()
    @State private var validationMessage: String?
    @ComposerBehaviorSettingsStorage
    private var composerSettings

    private var selectedAccountID: String {
        SendAccountSelection(
            sendAccounts: sendAccounts,
            selectedSendAccountKey: selectedSendAccountKey
        ).selectedAccountID
    }

    private var isSending: Bool {
        if case .sending = sendState { return true }
        return sendController.isSending
    }

    private var hasTarget: Bool { target != nil }
    private var isInputDisabled: Bool { sendController.isQueued || isSending }
    private var content: MailiaComposerContent {
        MailiaComposerContent(attributedBody: draft, attachments: attachments)
    }

    private var canSend: Bool {
        hasTarget && content.hasRenderableContent && !sendController.isQueued && !isSending
    }

    private var sendFailureMessage: String? {
        if let validationMessage {
            return validationMessage
        }
        if case .failed(let message) = sendState {
            return message
        }
        return nil
    }

    var body: some View {
        ComposerChrome(
            statusMessage: sendFailureMessage,
            sendAccounts: sendAccounts,
            selectedSendAccountKey: selectedSendAccountKey,
            isInputDisabled: isInputDisabled,
            isQueued: sendController.isQueued,
            remainingSeconds: sendController.remainingSeconds,
            isSending: isSending,
                isShowingSentConfirmation: sendController.isShowingSentConfirmation,
                canSend: canSend,
                onAddContent: editorController.chooseFilesFromPanel,
                onSend: queueSend,
            onUndo: sendController.undo,
            onSelectSendAccount: onSelectSendAccount
        ) {
            inputField
        }
        .onChange(of: sendState) { _, newValue in
            handleSendStateChange(newValue)
        }
        .onChange(of: draft) { _, _ in
            clearFailedSendStateAfterEdit()
        }
        .onChange(of: attachments) { _, _ in
            clearFailedSendStateAfterEdit()
        }
        .onAppear {
            editorController.onError = { message in
                validationMessage = message
            }
            editorController.onAddAttachments = { newAttachments in
                attachments.append(contentsOf: newAttachments)
            }
        }
        .onDisappear {
            sendController.cancel()
        }
    }

    private var inputField: some View {
        ComposerBodyInputField(
            attributedText: $draft,
            height: $textHeight,
            attachments: attachments,
            placeholder: "Reply…",
            isEnabled: !isInputDisabled,
            maxHeight: Self.maxInputHeight,
            sendShortcut: composerSettings.sendShortcut,
            editorController: editorController,
            onRemoveAttachment: removeAttachment,
            onSubmit: queueSend
        )
    }

    private func queueSend() {
        guard canSend else { return }
        let account = selectedAccountID
        let payload = content

        sendController.queue(payload, settings: composerSettings) { content in
            onSend(content, account.isEmpty ? nil : account)
        }
    }

    private func handleSendStateChange(_ state: MailiaReplySendState) {
        sendController.handleSendStateChange(state) {
            draft = NSAttributedString(string: "", attributes: ComposerTextDefaults.bodyAttributes)
            attachments = []
            textHeight = Self.singleLineHeight
            validationMessage = nil
        }
    }

    private func clearFailedSendStateAfterEdit() {
        validationMessage = nil
        sendController.clearSentConfirmationIf(hasDraftContent: content.hasRenderableContent)
        if case .failed = sendState {
            onEdited()
        }
    }

    private func removeAttachment(_ attachment: MailiaOutgoingAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }
}

private struct NewMessageComposerPayload {
    let recipients: [String]
    let subject: String?
    let content: MailiaComposerContent
    let accountID: String
}

struct NewMessageComposerView: View {
    let sendAccounts: [MailiaSendAccount]
    let selectedSendAccountKey: String?
    let suggestions: [MailiaRecipientSuggestion]
    let sendState: MailiaReplySendState
    let onSend: ([String], String?, MailiaComposerContent, String?) -> Void
    let onSelectSendAccount: (String) -> Void
    let onEdited: () -> Void

    private static let singleLineHeight = ComposerControlMetrics.singleLineHeight
    private static let maxBodyHeight = ComposerControlMetrics.maxInputHeight

    @State private var recipients: [String] = []
    @State private var recipientDraft = ""
    @State private var subject = ""
    @State private var bodyText = NSAttributedString(string: "", attributes: ComposerTextDefaults.bodyAttributes)
    @State private var attachments: [MailiaOutgoingAttachment] = []
    @State private var bodyHeight = NewMessageComposerView.singleLineHeight
    @State private var validationMessage: String?
    @StateObject private var sendController = ComposerSendStateController<NewMessageComposerPayload>()
    @StateObject private var editorController = ComposerRichTextController()
    @State private var highlightedSuggestionID: String?
    @State private var selectedRecipient: String?
    @State private var isRecipientFieldFocused = false
    @ComposerBehaviorSettingsStorage
    private var composerSettings
    @FocusState private var focusedField: NewMessageComposerFocusedField?

    private var selectedAccountID: String {
        SendAccountSelection(
            sendAccounts: sendAccounts,
            selectedSendAccountKey: selectedSendAccountKey
        ).selectedAccountID
    }

    private var isSending: Bool {
        if case .sending = sendState { return true }
        return sendController.isSending
    }

    private var content: MailiaComposerContent {
        MailiaComposerContent(attributedBody: bodyText, attachments: attachments)
    }

    private var resolvedRecipients: [String] {
        normalizedRecipients(recipients + Self.parseRecipients(recipientDraft))
    }

    private var canSend: Bool {
        content.hasRenderableContent && !resolvedRecipients.isEmpty && !sendController.isQueued && !isSending
    }

    private var statusMessage: String? {
        if let validationMessage {
            return validationMessage
        }
        if case .failed(let message) = sendState {
            return message
        }
        return nil
    }

    private var filteredSuggestions: [MailiaRecipientSuggestion] {
        let query = recipientDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isRecipientFieldFocused, !query.isEmpty else { return [] }

        let selectedEmails = Set(resolvedRecipients.map { $0.lowercased() })
        return suggestions
            .filter { suggestion in
                !selectedEmails.contains(suggestion.email.lowercased())
                    && (suggestion.name.lowercased().contains(query)
                        || suggestion.email.lowercased().contains(query))
            }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerFields
            Spacer(minLength: 0)
            composerBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: sendState) { _, newValue in
            handleSendStateChange(newValue)
        }
        .onChange(of: recipients) { _, _ in
            clearErrorsAfterEdit()
        }
        .onChange(of: recipientDraft) { _, _ in
            clearErrorsAfterEdit()
        }
        .onChange(of: subject) { _, _ in
            clearErrorsAfterEdit()
        }
        .onChange(of: bodyText) { _, _ in
            clearErrorsAfterEdit()
        }
        .onChange(of: attachments) { _, _ in
            clearErrorsAfterEdit()
        }
        .onAppear {
            editorController.onError = { message in
                validationMessage = message
            }
            editorController.onAddAttachments = { newAttachments in
                attachments.append(contentsOf: newAttachments)
            }
        }
        .onDisappear {
            sendController.cancel()
        }
    }

    private var headerFields: some View {
        VStack(spacing: 0) {
            recipientRow
            Divider()
            subjectRow
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var recipientRow: some View {
        HStack(spacing: 12) {
            Text("To")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)

            FlowRecipientField(
                recipients: recipients,
                draft: $recipientDraft,
                selectedRecipient: $selectedRecipient,
                isFocused: $isRecipientFieldFocused,
                focusedField: $focusedField,
                onRemove: removeRecipient,
                onSelect: selectRecipient,
                onCommit: commitRecipientDraft,
                onDraftEdited: handleRecipientDraftEdited,
                onKey: handleRecipientInputKey
            )
        }
        .frame(height: 40)
        .padding(.horizontal, 16)
        .onAppear {
            focusedField = .recipients
        }
        .onChange(of: focusedField) { _, newValue in
            if newValue == .subject {
                isRecipientFieldFocused = false
            }
        }
        .overlay(alignment: .topLeading) {
            if !filteredSuggestions.isEmpty {
                suggestionMenu
                    .padding(.top, 40)
                    .padding(.leading, 86)
                    .padding(.trailing, 16)
            }
        }
        .zIndex(2)
    }

    private var subjectRow: some View {
        HStack(spacing: 12) {
            Text("Subject")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)

            ZStack(alignment: .leading) {
                if subject.isEmpty {
                    Text("Subject")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(nsColor: .placeholderTextColor))
                        .allowsHitTesting(false)
                }

                TextField("", text: $subject)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focusedField, equals: .subject)
                    .onSubmit {
                        focusedField = nil
                    }
            }
            .frame(height: 24)
        }
        .frame(height: 40)
        .padding(.horizontal, 16)
    }

    private var suggestionMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(filteredSuggestions) { suggestion in
                let isHighlighted = isHighlightedSuggestion(suggestion)
                HStack(spacing: 10) {
                    RecipientSuggestionAvatar(suggestion: suggestion)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(suggestion.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(suggestion.email)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background {
                    if isHighlighted {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onTapGesture {
                    acceptSuggestion(suggestion)
                }
                .onHover { isHovering in
                    if isHovering {
                        highlightedSuggestionID = suggestion.id
                    }
                }
            }
        }
        .padding(5)
        .frame(maxWidth: 360, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
    }

    private var composerBar: some View {
        ComposerChrome(
            statusMessage: statusMessage,
            sendAccounts: sendAccounts,
            selectedSendAccountKey: selectedSendAccountKey,
            isInputDisabled: sendController.isQueued || isSending,
            isQueued: sendController.isQueued,
            remainingSeconds: sendController.remainingSeconds,
            isSending: isSending,
                isShowingSentConfirmation: sendController.isShowingSentConfirmation,
                canSend: canSend,
                onAddContent: editorController.chooseFilesFromPanel,
                onSend: queueSend,
            onUndo: sendController.undo,
            onSelectSendAccount: onSelectSendAccount
        ) {
            bodyInput
        }
    }

    private var bodyInput: some View {
        ComposerBodyInputField(
            attributedText: $bodyText,
            height: $bodyHeight,
            attachments: attachments,
            placeholder: "Message...",
            isEnabled: !sendController.isQueued && !isSending,
            maxHeight: Self.maxBodyHeight,
            sendShortcut: composerSettings.sendShortcut,
            editorController: editorController,
            onRemoveAttachment: removeAttachment,
            onSubmit: queueSend
        )
    }

    private func queueSend() {
        guard !sendController.isQueued, !isSending else { return }
        validationMessage = nil

        let sendRecipients = resolvedRecipients
        guard !sendRecipients.isEmpty else {
            validationMessage = "Add at least one recipient before sending."
            focusedField = .recipients
            return
        }

        let content = content
        guard content.hasRenderableContent else { return }

        commitRecipientDraft()

        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = trimmedSubject.isEmpty ? nil : trimmedSubject
        let account = selectedAccountID
        let payload = NewMessageComposerPayload(
            recipients: sendRecipients,
            subject: subject,
            content: content,
            accountID: account
        )

        sendController.queue(payload, settings: composerSettings) { payload in
            onSend(
                payload.recipients,
                payload.subject,
                payload.content,
                payload.accountID.isEmpty ? nil : payload.accountID
            )
        }
    }

    private func handleSendStateChange(_ state: MailiaReplySendState) {
        sendController.handleSendStateChange(state) {
            recipients = []
            recipientDraft = ""
            subject = ""
            bodyText = NSAttributedString(string: "", attributes: ComposerTextDefaults.bodyAttributes)
            attachments = []
            bodyHeight = Self.singleLineHeight
            validationMessage = nil
        }
    }

    private func clearErrorsAfterEdit() {
        sendController.clearSentConfirmationIf(hasDraftContent: hasDraftContent)
        validationMessage = nil
        if case .failed = sendState {
            onEdited()
        }
    }

    private var hasDraftContent: Bool {
        !recipients.isEmpty
            || !recipientDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || content.hasRenderableContent
    }

    private func removeAttachment(_ attachment: MailiaOutgoingAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    private func commitRecipientDraft() {
        let parsed = Self.parseRecipients(recipientDraft)
        guard !parsed.isEmpty else { return }
        recipients = normalizedRecipients(recipients + parsed)
        recipientDraft = ""
        selectedRecipient = nil
        highlightedSuggestionID = nil
        validationMessage = nil
    }

    private func addRecipient(_ address: String) {
        recipients = normalizedRecipients(recipients + [address])
        selectedRecipient = nil
        highlightedSuggestionID = nil
    }

    private func removeRecipient(_ recipient: String) {
        recipients.removeAll { $0 == recipient }
        if selectedRecipient == recipient {
            selectedRecipient = nil
        }
    }

    private func selectRecipient(_ recipient: String) {
        selectedRecipient = recipient
        highlightedSuggestionID = nil
        focusedField = .recipients
    }

    private func handleRecipientDraftEdited() {
        selectedRecipient = nil
        if !filteredSuggestions.contains(where: { $0.id == highlightedSuggestionID }) {
            highlightedSuggestionID = filteredSuggestions.first?.id
        }
    }

    private func handleRecipientInputKey(_ key: RecipientInputKey, currentText: String) -> Bool {
        switch key {
        case .tab, .enter:
            if let suggestion = highlightedSuggestion ?? filteredSuggestions.first {
                acceptSuggestion(suggestion)
                if key == .enter, !resolvedRecipients.isEmpty, content.hasRenderableContent {
                    queueSend()
                }
                return true
            }
            if key == .enter {
                let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    recipientDraft = currentText
                }
                commitRecipientDraft()
                if !resolvedRecipients.isEmpty, content.hasRenderableContent {
                    queueSend()
                } else {
                    focusedField = .subject
                }
                return true
            }
            return false
        case .moveUp:
            moveSuggestionHighlight(by: -1)
            return !filteredSuggestions.isEmpty
        case .moveDown:
            moveSuggestionHighlight(by: 1)
            return !filteredSuggestions.isEmpty
        case .escape:
            highlightedSuggestionID = nil
            return !filteredSuggestions.isEmpty
        case .deleteBackward, .deleteForward:
            guard currentText.isEmpty else { return false }
            if let selectedRecipient {
                removeRecipient(selectedRecipient)
                return true
            }
            if key == .deleteBackward, let lastRecipient = recipients.last {
                selectedRecipient = lastRecipient
                return true
            }
            return false
        }
    }

    private var highlightedSuggestion: MailiaRecipientSuggestion? {
        guard let highlightedSuggestionID else { return nil }
        return filteredSuggestions.first { $0.id == highlightedSuggestionID }
    }

    private func isHighlightedSuggestion(_ suggestion: MailiaRecipientSuggestion) -> Bool {
        let activeID = highlightedSuggestionID ?? filteredSuggestions.first?.id
        return suggestion.id == activeID
    }

    private func moveSuggestionHighlight(by offset: Int) {
        guard !filteredSuggestions.isEmpty else { return }
        let currentIndex = highlightedSuggestionID.flatMap { id in
            filteredSuggestions.firstIndex { $0.id == id }
        } ?? (offset > 0 ? -1 : 0)
        let count = filteredSuggestions.count
        let nextIndex = (currentIndex + offset + count) % count
        highlightedSuggestionID = filteredSuggestions[nextIndex].id
    }

    private func acceptSuggestion(_ suggestion: MailiaRecipientSuggestion) {
        addRecipient(suggestion.email)
        recipientDraft = ""
        validationMessage = nil
        focusedField = .recipients
    }

    private func normalizedRecipients(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private static func parseRecipients(_ value: String) -> [String] {
        value
            .split { character in
                character == "," || character == ";" || character.isNewline
            }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private enum RecipientInputKey: Equatable {
    case tab
    case enter
    case moveUp
    case moveDown
    case escape
    case deleteBackward
    case deleteForward
}

private struct FlowRecipientField: View {
    let recipients: [String]
    @Binding var draft: String
    @Binding var selectedRecipient: String?
    @Binding var isFocused: Bool
    var focusedField: FocusState<NewMessageComposerFocusedField?>.Binding
    let onRemove: (String) -> Void
    let onSelect: (String) -> Void
    let onCommit: () -> Void
    let onDraftEdited: () -> Void
    let onKey: (RecipientInputKey, String) -> Bool

    var body: some View {
        HStack(spacing: 6) {
            if !recipients.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(recipients, id: \.self) { recipient in
                            RecipientToken(
                                recipient: recipient,
                                isSelected: selectedRecipient == recipient,
                                onSelect: { onSelect(recipient) },
                                onRemove: { onRemove(recipient) }
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .fixedSize(horizontal: true, vertical: false)
            }

            RecipientDraftTextField(
                text: $draft,
                showPlaceholder: recipients.isEmpty,
                isFocused: $isFocused,
                focusedField: focusedField,
                onCommit: onCommit,
                onDraftEdited: onDraftEdited,
                onKey: onKey
            )
            .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            .frame(height: 24)

            Spacer(minLength: 0)
                .contentShape(Rectangle())
                .onTapGesture {
                    requestFocus()
                }
        }
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func requestFocus() {
        isFocused = true
        focusedField.wrappedValue = .recipients
    }
}

/// Plain single-line recipient input backed by `NSTextField` so placeholder,
/// typed text, and Subject share the same baseline without automatic email
/// link styling from the system field editor.
private struct RecipientDraftTextField: NSViewRepresentable {
    @Binding var text: String
    var showPlaceholder: Bool
    @Binding var isFocused: Bool
    var focusedField: FocusState<NewMessageComposerFocusedField?>.Binding
    var onCommit: () -> Void
    var onDraftEdited: () -> Void
    var onKey: (RecipientInputKey, String) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> RecipientNSTextField {
        let field = RecipientNSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.isEditable = true
        field.isSelectable = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.stringValue = text
        field.placeholderAttributedString = showPlaceholder ? Self.placeholder : nil
        field.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.syncFocus(focused)
        }
        return field
    }

    func updateNSView(_ field: RecipientNSTextField, context: Context) {
        context.coordinator.parent = self
        field.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.syncFocus(focused)
        }

        if text.isEmpty {
            if !field.stringValue.isEmpty {
                field.stringValue = ""
            }
        } else if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderAttributedString = showPlaceholder ? Self.placeholder : nil

        let shouldFocus = focusedField.wrappedValue == .recipients
        if shouldFocus,
           field.window?.firstResponder !== field.currentEditor(),
           field.window?.firstResponder !== field {
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
            }
        }
    }

    private static var placeholder: NSAttributedString {
        NSAttributedString(
            string: "name@example.com",
            attributes: [
                .foregroundColor: NSColor.placeholderTextColor,
                .font: NSFont.systemFont(ofSize: 15)
            ]
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RecipientDraftTextField
        private var pendingFocus: Bool?
        private var isFocusSyncScheduled = false

        init(_ parent: RecipientDraftTextField) {
            self.parent = parent
        }

        func syncFocus(_ focused: Bool) {
            pendingFocus = focused
            guard !isFocusSyncScheduled else { return }

            isFocusSyncScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let focused = self.pendingFocus
                self.pendingFocus = nil
                self.isFocusSyncScheduled = false
                guard let focused else { return }

                if self.parent.isFocused != focused {
                    self.parent.isFocused = focused
                }
                if focused, self.parent.focusedField.wrappedValue != .recipients {
                    self.parent.focusedField.wrappedValue = .recipients
                }
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let newValue = field.stringValue
            parent.text = newValue
            syncFocus(true)
            if !newValue.isEmpty {
                parent.onDraftEdited()
            }
            if newValue.contains(",") || newValue.contains(";") || newValue.contains(where: \.isNewline) {
                parent.onCommit()
            }
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            syncFocus(true)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
            syncFocus(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            let key: RecipientInputKey?
            switch commandSelector {
            case #selector(NSResponder.insertTab(_:)):
                key = .tab
            case #selector(NSResponder.insertNewline(_:)):
                key = .enter
            case #selector(NSResponder.moveUp(_:)):
                key = .moveUp
            case #selector(NSResponder.moveDown(_:)):
                key = .moveDown
            case #selector(NSResponder.cancelOperation(_:)):
                key = .escape
            case #selector(NSResponder.deleteBackward(_:)):
                key = .deleteBackward
            case #selector(NSResponder.deleteForward(_:)):
                key = .deleteForward
            default:
                key = nil
            }

            guard let key else { return false }
            let currentText = (control as? NSTextField)?.stringValue ?? parent.text
            if currentText != parent.text {
                parent.text = currentText
            }
            return parent.onKey(key, currentText)
        }
    }
}

private final class RecipientNSTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?

    override class var cellClass: AnyClass? {
        get { RecipientTextFieldCell.self }
        set { super.cellClass = newValue }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onFocusChange?(true)
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome {
            onFocusChange?(true)
        }
        return didBecome
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign {
            onFocusChange?(false)
        }
        return didResign
    }
}

private final class RecipientTextFieldCell: NSTextFieldCell {
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        if let textView = editor as? NSTextView {
            textView.isAutomaticDataDetectionEnabled = false
            textView.linkTextAttributes = [.foregroundColor: NSColor.labelColor]
            textView.insertionPointColor = .systemBlue
            textView.isEditable = true
            textView.isSelectable = true
        }
        return editor
    }
}

private struct RecipientToken: View {
    let recipient: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(recipient)
                .font(.system(size: 14))
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 15, height: 15)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 24)
        .background(isSelected ? Color.accentColor.opacity(0.28) : Color.accentColor.opacity(0.16))
        .overlay {
            if isSelected {
                Capsule(style: .continuous)
                    .stroke(Color.accentColor.opacity(0.65), lineWidth: 1)
            }
        }
        .clipShape(Capsule(style: .continuous))
        .contentShape(Capsule(style: .continuous))
        .onTapGesture(perform: onSelect)
    }
}

private struct RecipientSuggestionAvatar: View {
    let suggestion: MailiaRecipientSuggestion
    private let size: CGFloat = 28

    var body: some View {
        Group {
            if let image = avatarImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.24))
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }

    private var avatarImage: NSImage? {
        if let dataURL = suggestion.avatarImageDataURL,
           let image = NSImage.mailiaImage(dataURL: dataURL) {
            return image
        }

        return EntityAvatarRenderer.image(
            id: suggestion.entityID,
            displayName: suggestion.name,
            size: size
        )
    }
}

private struct AccountMenuEmojiLabel: View {
    let account: MailiaSendAccount?
    let fallbackEmoji: String

    var body: some View {
        Group {
            if let emoji = MailiaSendAccount.normalizedEmoji(account?.emoji) {
                Text(emoji)
                    .font(.system(size: 17))
                    .foregroundStyle(.primary)
                    .symbolRenderingMode(.multicolor)
            } else if let image = accountAvatarImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())
            } else {
                Text(fallbackEmoji)
                    .font(.system(size: 17))
                    .foregroundStyle(.primary)
                    .symbolRenderingMode(.multicolor)
            }
        }
        .frame(width: 36, height: 36)
        .shadow(color: Color.black.opacity(0.18), radius: 1, x: 0, y: 1)
    }

    private var accountAvatarImage: NSImage? {
        guard let dataURL = account?.avatarImageDataURL?.nilIfBlank else {
            return nil
        }
        return NSImage.mailiaImage(dataURL: dataURL)
    }
}

private struct ComposerBodyInputField: View {
    @Binding var attributedText: NSAttributedString
    @Binding var height: CGFloat
    let attachments: [MailiaOutgoingAttachment]
    let placeholder: String
    let isEnabled: Bool
    let maxHeight: CGFloat
    let sendShortcut: MailiaComposerShortcut
    let editorController: ComposerRichTextController
    let onRemoveAttachment: (MailiaOutgoingAttachment) -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if isBodyEmpty {
                    Text(placeholder)
                        .font(.system(size: 15))
                        .foregroundStyle(Color(nsColor: .placeholderTextColor))
                        .padding(.horizontal, ComposerControlMetrics.inputHorizontalPadding)
                        .padding(.vertical, ComposerControlMetrics.inputVerticalPadding)
                        .allowsHitTesting(false)
                }

                RichComposerTextView(
                    attributedText: $attributedText,
                    height: $height,
                    isEnabled: isEnabled,
                    minHeight: ComposerControlMetrics.singleLineHeight,
                    maxHeight: maxHeight,
                    sendShortcut: sendShortcut,
                    controller: editorController,
                    onSubmit: onSubmit
                )
                .frame(height: min(max(height, ComposerControlMetrics.singleLineHeight), maxHeight))
                .padding(.horizontal, ComposerControlMetrics.inputHorizontalPadding)
                .padding(.vertical, ComposerControlMetrics.inputVerticalPadding)
            }

            if !attachments.isEmpty {
                ComposerAttachmentStrip(
                    attachments: attachments,
                    isEnabled: isEnabled,
                    onRemove: onRemoveAttachment
                )
            }
        }
        .frame(minHeight: ComposerControlMetrics.controlSize)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GlassChrome(shape: inputShape, tint: nil, interactive: true))
    }

    private var inputShape: AnyShape {
        if isSingleLineInput {
            return AnyShape(Capsule(style: .continuous))
        }

        return AnyShape(RoundedRectangle(
            cornerRadius: ComposerControlMetrics.multilineInputCornerRadius,
            style: .continuous
        ))
    }

    private var isSingleLineInput: Bool {
        attachments.isEmpty
            && !ComposerMessageSerializer.containsInlineImage(attributedText)
            && !attributedText.string.contains("\n")
            && height <= ComposerControlMetrics.singleLineHeight + 2
    }

    private var isBodyEmpty: Bool {
        attributedText.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !ComposerMessageSerializer.containsInlineImage(attributedText)
    }
}

private struct ComposerAttachmentStrip: View {
    let attachments: [MailiaOutgoingAttachment]
    let isEnabled: Bool
    let onRemove: (MailiaOutgoingAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    ComposerAttachmentChip(
                        attachment: attachment,
                        isEnabled: isEnabled,
                        onRemove: onRemove
                    )
                }
            }
            .padding(.horizontal, 9)
            .padding(.bottom, 8)
        }
    }
}

private struct ComposerAttachmentChip: View {
    let attachment: MailiaOutgoingAttachment
    let isEnabled: Bool
    let onRemove: (MailiaOutgoingAttachment) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: attachment.byteSize, countStyle: .file))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Button {
                onRemove(attachment)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .frame(height: 34)
        .background(Color.primary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var iconName: String {
        attachment.contentType.lowercased().hasPrefix("image/") ? "photo" : "doc"
    }
}

/// Applies the system Liquid Glass material to a shape.
private struct GlassChrome: ViewModifier {
    let shape: AnyShape
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        content
            .background {
                OuterGlassShadow(shape: shape)
            }
            .glassEffect(makeGlass(), in: shape)
    }

    private func makeGlass() -> Glass {
        var glass = Glass.regular
        if let tint {
            glass = glass.tint(tint)
        }
        if interactive {
            glass = glass.interactive()
        }
        return glass
    }
}

struct OuterGlassShadow: View {
    let shape: AnyShape

    var body: some View {
        ZStack {
            shadowLayer(opacity: 0.12, radius: 18)
            shadowLayer(opacity: 0.07, radius: 30)
        }
        .allowsHitTesting(false)
    }

    private func shadowLayer(opacity: Double, radius: CGFloat) -> some View {
        shape
            .fill(Color.black)
            .shadow(color: Color.black.opacity(opacity), radius: radius, x: 0, y: 0)
            .overlay {
                ZStack {
                    shape
                        .fill(Color.black)
                    shape
                        .stroke(Color.black, lineWidth: 1)
                }
                .blendMode(.destinationOut)
            }
            .compositingGroup()
    }
}

/// Auto-growing multiline text view backed by `NSTextView` so we get native
/// IME handling, a system-blue insertion point, and configurable send/newline
/// shortcuts.
struct GrowingTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var isEnabled: Bool
    var minHeight: CGFloat
    var maxHeight: CGFloat
    var sendShortcut: MailiaComposerShortcut
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SubmittableTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSubmit()
        }
        textView.sendShortcut = sendShortcut
        textView.font = .systemFont(ofSize: 15)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = .labelColor
        textView.insertionPointColor = .systemBlue
        textView.wantsLayer = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? SubmittableTextView else { return }
        textView.onSubmit = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSubmit()
        }
        textView.sendShortcut = sendShortcut
        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        DispatchQueue.main.async {
            context.coordinator.recomputeHeight(textView: textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextView

        init(_ parent: GrowingTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            recomputeHeight(textView: textView)
        }

        func recomputeHeight(textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let clamped = min(max(used, parent.minHeight), parent.maxHeight)
            if abs(parent.height - clamped) > 0.5 {
                parent.height = clamped
            }
            textView.enclosingScrollView?.hasVerticalScroller = used > parent.maxHeight + 0.5
        }
    }
}

private final class SubmittableTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var sendShortcut: MailiaComposerShortcut = .enter
    private let insertionPointWidth: CGFloat = 2
    private let insertionPointBlinkAnimationKey = "mailiaInsertionPointBlink"
    private lazy var roundedInsertionPointLayer: CALayer = {
        let layer = CALayer()
        layer.opacity = 1
        layer.cornerCurve = .continuous
        layer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "backgroundColor": NSNull()
        ]
        return layer
    }()

    override func keyDown(with event: NSEvent) {
        // keyCode 36 == Return, 76 == numeric keypad Enter.
        if event.keyCode == 36 || event.keyCode == 76 {
            if sendShortcut.matches(event) {
                onSubmit?()
            } else {
                insertNewline(nil)
            }
            return
        }
        super.keyDown(with: event)
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard window?.firstResponder === self else {
            hideRoundedInsertionPoint()
            return
        }

        installRoundedInsertionPointLayerIfNeeded()

        var caretRect = rect
        caretRect.origin.x = max(0, caretRect.origin.x)
        caretRect.size.width = insertionPointWidth
        caretRect.size.height = max(caretRect.height, 15)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        roundedInsertionPointLayer.frame = caretRect
        roundedInsertionPointLayer.cornerRadius = insertionPointWidth / 2
        roundedInsertionPointLayer.backgroundColor = resolvedInsertionPointColor(color).cgColor
        CATransaction.commit()

        startRoundedInsertionPointBlinkIfNeeded()
    }

    override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        var invalidRect = invalidRect
        invalidRect.size.width += insertionPointWidth
        super.setNeedsDisplay(invalidRect, avoidAdditionalLayout: flag)
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign {
            hideRoundedInsertionPoint()
        }
        return didResign
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            hideRoundedInsertionPoint()
        }
    }

    private func installRoundedInsertionPointLayerIfNeeded() {
        wantsLayer = true
        guard let layer else { return }
        if roundedInsertionPointLayer.superlayer !== layer {
            layer.addSublayer(roundedInsertionPointLayer)
        }
    }

    private func hideRoundedInsertionPoint() {
        roundedInsertionPointLayer.removeAllAnimations()
        roundedInsertionPointLayer.opacity = 0
    }

    private func startRoundedInsertionPointBlinkIfNeeded() {
        roundedInsertionPointLayer.opacity = 1
        guard roundedInsertionPointLayer.animation(forKey: insertionPointBlinkAnimationKey) == nil else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0
        animation.duration = 0.72
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        roundedInsertionPointLayer.add(animation, forKey: insertionPointBlinkAnimationKey)
    }

    private func resolvedInsertionPointColor(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.deviceRGB) ?? .systemBlue
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
