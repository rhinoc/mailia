import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ComposerRichTextController: ObservableObject {
    weak var textView: ComposerRichTextView?
    var onError: ((String) -> Void)?
    var onAddAttachments: (([MailiaOutgoingAttachment]) -> Void)?

    func toggleBold() {
        textView?.toggleBoldStyle()
        textView?.syncTypingAttributes()
    }

    func toggleItalic() {
        textView?.toggleItalicStyle()
        textView?.syncTypingAttributes()
    }

    func toggleUnderline() {
        textView?.toggleUnderlineStyle()
        textView?.syncTypingAttributes()
    }

    func addLink() {
        guard let textView else { return }
        let selectedRange = textView.selectedRange()
        let selectedText = selectedRange.length > 0
            ? (textView.string as NSString).substring(with: selectedRange)
            : ""
        let panel = NSAlert()
        panel.messageText = "Add Link"
        panel.informativeText = selectedText.isEmpty ? "Enter a URL to insert." : "Enter a URL for the selected text."
        panel.addButton(withTitle: "Add")
        panel.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://example.com"
        panel.accessoryView = field

        guard panel.runModal() == .alertFirstButtonReturn else { return }
        guard let url = normalizedURL(field.stringValue) else {
            onError?("Enter a valid link.")
            return
        }

        if selectedRange.length > 0 {
            textView.textStorage?.addAttribute(.link, value: url, range: selectedRange)
        } else {
            let attributed = NSAttributedString(
                string: url.absoluteString,
                attributes: ComposerTextDefaults.bodyAttributes.merging([.link: url]) { _, new in new }
            )
            textView.insertAttributedText(attributed)
        }
    }

    func insertInlineImageFromPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "Insert"
        guard panel.runModal() == .OK else { return }
        insertInlineImages(panel.urls)
    }

    func chooseFilesFromPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        routeSelectedFiles(panel.urls)
    }

    func addAttachmentsFromPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        addAttachments(panel.urls)
    }

    func insertInlineImages(_ urls: [URL]) {
        for url in urls {
            do {
                let attachment = try MailiaOutgoingAttachment.inlineImage(fileURL: url)
                guard let image = NSImage(contentsOf: url) else {
                    throw MailiaOutgoingAttachmentError.notAnImage(url.lastPathComponent)
                }
                textView?.insertInlineImage(attachment, image: image)
            } catch {
                onError?(error.localizedDescription)
            }
        }
    }

    func routeSelectedFiles(_ urls: [URL]) {
        let imageURLs = urls.filter { Self.isImageURL($0) }
        let attachmentURLs = urls.filter { !Self.isImageURL($0) }
        if !imageURLs.isEmpty {
            insertInlineImages(imageURLs)
        }
        if !attachmentURLs.isEmpty {
            addAttachments(attachmentURLs)
        }
    }

    func addAttachments(_ urls: [URL]) {
        var attachments: [MailiaOutgoingAttachment] = []
        for url in urls {
            do {
                attachments.append(try MailiaOutgoingAttachment.attachment(fileURL: url))
            } catch {
                onError?(error.localizedDescription)
            }
        }
        if !attachments.isEmpty {
            onAddAttachments?(attachments)
        }
    }

    private func normalizedURL(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: "https://\(trimmed)")
    }

    private static func isImageURL(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .image)
        }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }
}

struct RichComposerTextView: NSViewRepresentable {
    @Binding var attributedText: NSAttributedString
    @Binding var height: CGFloat
    var isEnabled: Bool
    var minHeight: CGFloat
    var maxHeight: CGFloat
    var sendShortcut: MailiaComposerShortcut
    var controller: ComposerRichTextController
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerRichTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSubmit()
        }
        textView.onInlineImagesDropped = { [weak controller] urls in
            controller?.insertInlineImages(urls)
        }
        textView.onFilesDropped = { [weak controller] urls in
            controller?.addAttachments(urls)
        }
        textView.sendShortcut = sendShortcut
        textView.font = ComposerTextDefaults.bodyFont
        textView.typingAttributes = ComposerTextDefaults.bodyAttributes
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFontPanel = false
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
        textView.textStorage?.setAttributedString(attributedText)
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])

        controller.textView = textView

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
        guard let textView = scrollView.documentView as? ComposerRichTextView else { return }
        controller.textView = textView
        textView.onSubmit = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSubmit()
        }
        textView.onInlineImagesDropped = { [weak controller] urls in
            controller?.insertInlineImages(urls)
        }
        textView.onFilesDropped = { [weak controller] urls in
            controller?.addAttachments(urls)
        }
        textView.sendShortcut = sendShortcut
        if !textView.attributedString().isEqual(to: attributedText) {
            textView.textStorage?.setAttributedString(attributedText)
        }
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        DispatchQueue.main.async {
            context.coordinator.recomputeHeight(textView: textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichComposerTextView

        init(_ parent: RichComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ComposerRichTextView else { return }
            parent.attributedText = textView.attributedString()
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

final class ComposerRichTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onInlineImagesDropped: (([URL]) -> Void)?
    var onFilesDropped: (([URL]) -> Void)?
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

    func insertAttributedText(_ value: NSAttributedString) {
        textStorage?.replaceCharacters(in: selectedRange(), with: value)
        didChangeText()
    }

    func insertInlineImage(_ attachment: MailiaOutgoingAttachment, image: NSImage) {
        let textAttachment = ComposerInlineImageTextAttachment(outgoingAttachment: attachment, image: image)
        let attributed = NSMutableAttributedString(attributedString: NSAttributedString(attachment: textAttachment))
        attributed.append(NSAttributedString(string: "\n", attributes: ComposerTextDefaults.bodyAttributes))
        insertAttributedText(attributed)
    }

    func toggleBoldStyle() {
        toggleFontTrait(.boldFontMask)
    }

    func toggleItalicStyle() {
        toggleFontTrait(.italicFontMask)
    }

    func toggleUnderlineStyle() {
        let range = selectedRange()
        if range.length == 0 {
            if currentUnderlineStyle(in: typingAttributes) == nil {
                typingAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            } else {
                typingAttributes.removeValue(forKey: .underlineStyle)
            }
            return
        }

        guard let textStorage else { return }
        textStorage.beginEditing()
        textStorage.enumerateAttributes(in: range) { attributes, subrange, _ in
            if currentUnderlineStyle(in: attributes) == nil {
                textStorage.addAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: subrange
                )
            } else {
                textStorage.removeAttribute(.underlineStyle, range: subrange)
            }
        }
        textStorage.endEditing()
        didChangeText()
    }

    func syncTypingAttributes() {
        if typingAttributes[.font] == nil {
            typingAttributes[.font] = ComposerTextDefaults.bodyFont
        }
        if typingAttributes[.foregroundColor] == nil {
            typingAttributes[.foregroundColor] = NSColor.labelColor
        }
    }

    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        let range = selectedRange()
        if range.length == 0 {
            let font = (typingAttributes[.font] as? NSFont) ?? ComposerTextDefaults.bodyFont
            typingAttributes[.font] = toggledFont(font, trait: trait)
            return
        }

        guard let textStorage else { return }
        textStorage.beginEditing()
        textStorage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = (value as? NSFont) ?? ComposerTextDefaults.bodyFont
            textStorage.addAttribute(.font, value: toggledFont(font, trait: trait), range: subrange)
        }
        textStorage.endEditing()
        didChangeText()
    }

    private func toggledFont(_ font: NSFont, trait: NSFontTraitMask) -> NSFont {
        let manager = NSFontManager.shared
        let traits = manager.traits(of: font)
        if traits.contains(trait) {
            return manager.convert(font, toNotHaveTrait: trait)
        }
        return manager.convert(font, toHaveTrait: trait)
    }

    private func currentUnderlineStyle(in attributes: [NSAttributedString.Key: Any]) -> Int? {
        guard let rawValue = attributes[.underlineStyle] as? Int, rawValue != 0 else {
            return nil
        }
        return rawValue
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "b":
                toggleBoldStyle()
                syncTypingAttributes()
                return
            case "i":
                toggleItalicStyle()
                syncTypingAttributes()
                return
            case "u":
                toggleUnderlineStyle()
                syncTypingAttributes()
                return
            default:
                break
            }
        }

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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers == .command else {
            return super.performKeyEquivalent(with: event)
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b":
            toggleBoldStyle()
            syncTypingAttributes()
            return true
        case "i":
            toggleItalicStyle()
            syncTypingAttributes()
            return true
        case "u":
            toggleUnderlineStyle()
            syncTypingAttributes()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func underline(_ sender: Any?) {
        toggleUnderlineStyle()
        syncTypingAttributes()
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.fileURLs, !urls.isEmpty {
            routeDroppedFiles(urls)
            return
        }
        if let image = NSImage(pasteboard: pasteboard),
           let url = stagePastedImage(image) {
            onInlineImagesDropped?([url])
            return
        }
        pasteAsPlainText(sender)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        if pasteboard.fileURLs?.isEmpty == false {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.fileURLs, !urls.isEmpty else {
            return super.performDragOperation(sender)
        }
        routeDroppedFiles(urls)
        return true
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

    private func routeDroppedFiles(_ urls: [URL]) {
        let imageURLs = urls.filter { Self.isImageURL($0) }
        let otherURLs = urls.filter { !Self.isImageURL($0) }
        if !imageURLs.isEmpty {
            onInlineImagesDropped?(imageURLs)
        }
        if !otherURLs.isEmpty {
            onFilesDropped?(otherURLs)
        }
    }

    private func stagePastedImage(_ image: NSImage) -> URL? {
        guard let data = image.pngData else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailiaComposerImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func isImageURL(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .image)
        }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    private func installRoundedInsertionPointLayerIfNeeded() {
        guard roundedInsertionPointLayer.superlayer == nil else { return }
        wantsLayer = true
        layer?.addSublayer(roundedInsertionPointLayer)
    }

    private func startRoundedInsertionPointBlinkIfNeeded() {
        guard roundedInsertionPointLayer.animation(forKey: insertionPointBlinkAnimationKey) == nil else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0
        animation.duration = 0.55
        animation.autoreverses = true
        animation.repeatCount = .infinity
        roundedInsertionPointLayer.add(animation, forKey: insertionPointBlinkAnimationKey)
    }

    private func hideRoundedInsertionPoint() {
        roundedInsertionPointLayer.removeAnimation(forKey: insertionPointBlinkAnimationKey)
        roundedInsertionPointLayer.removeFromSuperlayer()
    }

    private func resolvedInsertionPointColor(_ fallback: NSColor) -> NSColor {
        insertionPointColor ?? fallback
    }
}

private extension NSPasteboard {
    var fileURLs: [URL]? {
        readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
    }
}

private extension NSImage {
    var pngData: Data? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
