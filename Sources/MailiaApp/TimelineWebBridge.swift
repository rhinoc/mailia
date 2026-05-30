import Foundation
import AppKit
import WebKit

@MainActor
final class TimelineWebBridgeCoordinator: NSObject {
    static let scriptMessageHandlerName = "mailiaTimeline"

    let webView: WKWebView
    var onEvent: ((TimelineWebEvent) -> Void)?
    var onEventDecodingError: ((Error) -> Void)?
    var contextMenuProvider: (() -> NSMenu?)? {
        didSet {
            configureContextMenu()
        }
    }
    private let assetLocator: TimelineWebAssetLocating
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var pendingStateJSON: String?
    private var hasFinishedInitialLoad = false

    init(
        webView: WKWebView? = nil,
        assetLocator: TimelineWebAssetLocating = TimelineWebAssetLocator(),
        encoder: JSONEncoder = .timelineWeb,
        decoder: JSONDecoder = .timelineWeb
    ) {
        self.assetLocator = assetLocator
        self.encoder = encoder
        self.decoder = decoder

        if let webView {
            self.webView = webView
        } else {
            self.webView = TimelineInspectableWebView(frame: .zero, configuration: Self.makeConfiguration())
        }

        super.init()

        configureInspectableWebView()
        configureContextMenu()
        configureScrollView()
        DispatchQueue.main.async { [weak self] in
            self?.configureScrollView()
        }
        self.webView.navigationDelegate = self
        self.webView.uiDelegate = self
        self.webView.configuration.userContentController.add(
            WeakTimelineWebScriptMessageHandler(coordinator: self),
            name: Self.scriptMessageHandlerName
        )
    }

    func load() {
        hasFinishedInitialLoad = false

        if let indexURL = assetLocator.timelineIndexURL() {
            webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
            return
        }

        webView.loadHTMLString(Self.placeholderHTML, baseURL: nil)
    }

    func pushState(_ state: TimelineWebState) throws {
        let data = try encoder.encode(state)
        guard let json = String(data: data, encoding: .utf8) else {
            throw TimelineWebBridgeError.unableToEncodeState
        }
        pushStateJSON(json)
    }

    func pushStateJSON(_ json: String) {
        guard hasFinishedInitialLoad else {
            pendingStateJSON = json
            return
        }

        evaluateReceiveState(json)
    }

    func dismantle() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.scriptMessageHandlerName)
        onEvent = nil
        onEventDecodingError = nil
    }

    fileprivate func receiveScriptMessage(_ message: WKScriptMessage) {
        do {
            let envelope = try decodeEnvelope(from: message.body)
            onEvent?(try envelope.event())
        } catch {
            onEventDecodingError?(error)
        }
    }

    private func decodeEnvelope(from body: Any) throws -> TimelineWebEventEnvelope {
        if let data = body as? Data {
            return try decoder.decode(TimelineWebEventEnvelope.self, from: data)
        }

        if let string = body as? String {
            guard let data = string.data(using: .utf8) else {
                throw TimelineWebEventDecodingError.unsupportedMessageBody
            }
            return try decoder.decode(TimelineWebEventEnvelope.self, from: data)
        }

        guard JSONSerialization.isValidJSONObject(body) else {
            throw TimelineWebEventDecodingError.unsupportedMessageBody
        }

        let data = try JSONSerialization.data(withJSONObject: body)
        return try decoder.decode(TimelineWebEventEnvelope.self, from: data)
    }

    private func evaluateReceiveState(_ json: String) {
        let script = """
        (() => {
          const state = \(json);
          if (window.mailiaTimeline && typeof window.mailiaTimeline.receiveState === 'function') {
            window.mailiaTimeline.receiveState(state);
          } else {
            window.__mailiaTimelinePendingState = state;
          }
        })();
        """
        webView.evaluateJavaScript(script) { [weak self] _, error in
            guard let error else { return }
            self?.onEventDecodingError?(TimelineWebBridgeError.javaScriptEvaluationFailed(error.localizedDescription))
        }
    }

    private func configureInspectableWebView() {
        webView.isInspectable = true
        TimelineWebDebugMenuController.shared.setActiveWebView(webView)
    }

    private func configureContextMenu() {
        guard let webView = webView as? TimelineInspectableWebView else { return }
        webView.contextMenuProvider = contextMenuProvider ?? { NSMenu() }
    }

    private func configureScrollView() {
        guard let scrollView = firstScrollView(in: webView) else { return }
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let scrollView = firstScrollView(in: subview) {
                return scrollView
            }
        }
        return nil
    }

    private static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController = WKUserContentController()
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.consoleBridgeScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        return configuration
    }

    private static let consoleBridgeScript = """
    (() => {
      const post = (level, args) => {
        try {
          window.webkit.messageHandlers.mailiaTimeline.postMessage({
            type: 'log',
            payload: {
              level,
              message: Array.from(args).map((value) => {
                try {
                  return typeof value === 'string' ? value : JSON.stringify(value);
                } catch (_) {
                  return String(value);
                }
              }).join(' ')
            }
          });
        } catch (_) {}
      };
      const originalError = console.error;
      const originalWarn = console.warn;
      console.error = function() {
        post('error', arguments);
        return originalError.apply(this, arguments);
      };
      console.warn = function() {
        post('warn', arguments);
        return originalWarn.apply(this, arguments);
      };
      window.addEventListener('error', (event) => {
        post('error', [event.message, event.filename, event.lineno, event.colno]);
      });
      window.addEventListener('unhandledrejection', (event) => {
        post('error', ['Unhandled promise rejection', event.reason]);
      });
    })();
    """

    private static let placeholderHTML = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        :root {
          color-scheme: light dark;
          font: -apple-system-body;
          background: Canvas;
          color: CanvasText;
        }
        body {
          align-items: center;
          box-sizing: border-box;
          display: flex;
          justify-content: center;
          margin: 0;
          min-height: 100vh;
          padding: 24px;
        }
        main {
          max-width: 420px;
          text-align: center;
        }
        h1 {
          font: -apple-system-title3;
          margin: 0 0 8px;
        }
        p {
          color: color-mix(in srgb, CanvasText 72%, transparent);
          line-height: 1.4;
          margin: 0;
        }
      </style>
      <script>
        window.mailiaTimeline = window.mailiaTimeline || {};
        window.mailiaTimeline.receiveState = function(state) {
          window.__mailiaTimelineState = state;
        };
      </script>
    </head>
    <body>
      <main>
        <h1>Timeline web island unavailable</h1>
        <p>Build Web/Timeline/dist/index.html to enable the WKWebView-backed timeline.</p>
      </main>
    </body>
    </html>
    """
}

private final class TimelineInspectableWebView: WKWebView {
    var contextMenuProvider: (() -> NSMenu?)?

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu = contextMenuProvider?() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let scrollView = firstScrollView(in: self) else {
            super.scrollWheel(with: event)
            return
        }

        let isMostlyVertical = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
        if isMostlyVertical {
            guard canScroll(scrollView, withVerticalDelta: event.scrollingDeltaY) else { return }
        } else {
            guard canScroll(scrollView, withHorizontalDelta: event.scrollingDeltaX) else { return }
        }

        super.scrollWheel(with: event)
    }

    private func canScroll(_ scrollView: NSScrollView, withVerticalDelta deltaY: CGFloat) -> Bool {
        guard abs(deltaY) > 0.1 else { return false }
        let visibleBounds = scrollView.contentView.bounds
        let maximumY = max((scrollView.documentView?.bounds.height ?? 0) - visibleBounds.height, 0)
        if maximumY <= 1 {
            return false
        }
        let originY = min(max(visibleBounds.origin.y, 0), maximumY)
        if deltaY > 0 {
            return originY > 1
        }
        return originY < maximumY - 1
    }

    private func canScroll(_ scrollView: NSScrollView, withHorizontalDelta deltaX: CGFloat) -> Bool {
        guard abs(deltaX) > 0.1 else { return false }
        let visibleBounds = scrollView.contentView.bounds
        let maximumX = max((scrollView.documentView?.bounds.width ?? 0) - visibleBounds.width, 0)
        if maximumX <= 1 {
            return false
        }
        let originX = min(max(visibleBounds.origin.x, 0), maximumX)
        if deltaX > 0 {
            return originX > 1
        }
        return originX < maximumX - 1
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let scrollView = firstScrollView(in: subview) {
                return scrollView
            }
        }
        return nil
    }
}

@MainActor
final class TimelineWebDebugMenuController: NSObject {
    static let shared = TimelineWebDebugMenuController()

    private weak var activeWebView: WKWebView?

    private override init() {}

    func setActiveWebView(_ webView: WKWebView) {
        activeWebView = webView
    }

    @objc func openDetachedTimelineInspector(_ sender: Any?) {
        openInspector(showConsole: false)
    }

    @objc func openTimelineConsole(_ sender: Any?) {
        openInspector(showConsole: true)
    }

    private func openInspector(showConsole: Bool) {
        guard let inspector = activeInspector else {
            NSSound.beep()
            return
        }

        let showSelector = showConsole ? Self.showConsoleSelector : Self.showInspectorSelector
        guard inspector.responds(to: showSelector) else {
            NSSound.beep()
            return
        }

        _ = inspector.perform(showSelector)

        guard inspector.responds(to: Self.detachInspectorSelector) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak inspector] in
            _ = inspector?.perform(Self.detachInspectorSelector)
        }
    }

    private var activeInspector: NSObject? {
        guard let activeWebView, activeWebView.responds(to: Self.inspectorSelector) else { return nil }
        return activeWebView.perform(Self.inspectorSelector)?.takeUnretainedValue() as? NSObject
    }

    private static let inspectorSelector = NSSelectorFromString("_inspector")
    private static let showInspectorSelector = NSSelectorFromString("show")
    private static let showConsoleSelector = NSSelectorFromString("showConsole")
    private static let detachInspectorSelector = NSSelectorFromString("detach")
}

extension TimelineWebBridgeCoordinator: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        configureScrollView()
        hasFinishedInitialLoad = true
        if let pendingStateJSON {
            self.pendingStateJSON = nil
            evaluateReceiveState(pendingStateJSON)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onEventDecodingError?(TimelineWebBridgeError.navigationFailed(error.localizedDescription))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onEventDecodingError?(TimelineWebBridgeError.navigationFailed(error.localizedDescription))
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if ["http", "https", "mailto"].contains(url.scheme?.lowercased()) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}

extension TimelineWebBridgeCoordinator: WKUIDelegate {}

protocol TimelineWebAssetLocating {
    func timelineIndexURL() -> URL?
}

struct TimelineWebAssetLocator: TimelineWebAssetLocating {
    private let fileManager: FileManager
    private let additionalSearchRoots: [URL]

    init(
        fileManager: FileManager = .default,
        additionalSearchRoots: [URL] = []
    ) {
        self.fileManager = fileManager
        self.additionalSearchRoots = additionalSearchRoots
    }

    func timelineIndexURL() -> URL? {
        candidateRoots()
            .lazy
            .map { $0.appendingPathComponent("Web/Timeline/dist/index.html") }
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    private func candidateRoots() -> [URL] {
        var roots: [URL] = []
        roots.append(contentsOf: additionalSearchRoots)
        roots.append(URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true))
        roots.append(contentsOf: ancestorURLs(from: Bundle.main.bundleURL))
        roots.append(contentsOf: ancestorURLs(from: URL(fileURLWithPath: #filePath)))
        return uniqued(roots)
    }

    private func ancestorURLs(from url: URL) -> [URL] {
        var result: [URL] = []
        var current = (url.hasDirectoryPath ? url : url.deletingLastPathComponent()).standardizedFileURL
        for _ in 0..<16 {
            result.append(current)
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { break }
            current = parent.standardizedFileURL
        }
        return result
    }

    private func uniqued(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for url in urls {
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { continue }
            result.append(standardized)
        }
        return result
    }
}

enum TimelineWebBridgeError: Error, LocalizedError, Equatable {
    case unableToEncodeState
    case javaScriptEvaluationFailed(String)
    case navigationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unableToEncodeState:
            "Unable to encode timeline web state."
        case .javaScriptEvaluationFailed(let message):
            "Timeline web JavaScript evaluation failed: \(message)"
        case .navigationFailed(let message):
            "Timeline web navigation failed: \(message)"
        }
    }
}

@MainActor
private final class WeakTimelineWebScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var coordinator: TimelineWebBridgeCoordinator?

    init(coordinator: TimelineWebBridgeCoordinator) {
        self.coordinator = coordinator
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        coordinator?.receiveScriptMessage(message)
    }
}
