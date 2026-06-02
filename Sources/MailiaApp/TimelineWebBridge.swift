import Foundation
import AppKit
import WebKit

private struct TimelineWebStateDelivery {
    enum Kind: String {
        case state
        case statePatch

        var javascriptLiteral: String {
            "'\(rawValue)'"
        }

        var payloadName: String {
            switch self {
            case .state:
                "state"
            case .statePatch:
                "patch"
            }
        }
    }

    let kind: Kind
    let json: String
    let byteCount: Int

    static func state(_ state: TimelineWebState, encoder: JSONEncoder) throws -> TimelineWebStateDelivery {
        try make(kind: .state, payload: state, encoder: encoder)
    }

    static func patch(_ patch: TimelineWebStatePatch, encoder: JSONEncoder) throws -> TimelineWebStateDelivery {
        try make(kind: .statePatch, payload: patch, encoder: encoder)
    }

    private static func make<T: Encodable>(
        kind: Kind,
        payload: T,
        encoder: JSONEncoder
    ) throws -> TimelineWebStateDelivery {
        let data = try encoder.encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw TimelineWebBridgeError.unableToEncodeState
        }
        return TimelineWebStateDelivery(kind: kind, json: json, byteCount: data.count)
    }
}

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
    private var pendingDelivery: TimelineWebStateDelivery?
    private var lastDeliveredState: TimelineWebState?
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
        configureWebViewBackground()
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
        pendingDelivery = nil
        lastDeliveredState = nil

        if let indexURL = assetLocator.timelineIndexURL() {
            webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
            return
        }

        webView.loadHTMLString(Self.placeholderHTML, baseURL: nil)
    }

    func pushState(_ state: TimelineWebState) throws {
        guard let delivery = try makeDelivery(for: state) else { return }
        lastDeliveredState = state
        logPushedState(state, delivery: delivery)
        pushDelivery(delivery)
    }

    private func makeDelivery(for state: TimelineWebState) throws -> TimelineWebStateDelivery? {
        if lastDeliveredState == state {
            return nil
        }
        if hasFinishedInitialLoad,
           let previous = lastDeliveredState,
           let patch = TimelineWebStatePatch(from: previous, to: state) {
            return try .patch(patch, encoder: encoder)
        }
        return try .state(state, encoder: encoder)
    }

    private func pushDelivery(_ delivery: TimelineWebStateDelivery) {
        guard hasFinishedInitialLoad else {
            pendingDelivery = delivery
            return
        }

        evaluateReceiveDelivery(delivery)
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

    private func evaluateReceiveDelivery(_ delivery: TimelineWebStateDelivery) {
        let script = """
        (() => {
          const payload = \(delivery.json);
          if (window.mailiaTimeline) {
            if (typeof window.mailiaTimeline.receive === 'function') {
              window.mailiaTimeline.receive({ type: \(delivery.kind.javascriptLiteral), \(delivery.kind.payloadName): payload });
              return;
            }
          }
          window.__mailiaTimelinePendingEvents = window.__mailiaTimelinePendingEvents || [];
          window.__mailiaTimelinePendingEvents.push({ type: \(delivery.kind.javascriptLiteral), \(delivery.kind.payloadName): payload });
        })();
        """
        webView.evaluateJavaScript(script) { [weak self] _, error in
            guard let error else { return }
            self?.onEventDecodingError?(TimelineWebBridgeError.javaScriptEvaluationFailed(error.localizedDescription))
        }
    }

    private func logPushedState(_ state: TimelineWebState, delivery: TimelineWebStateDelivery) {
        let deliveryMode = hasFinishedInitialLoad ? "evaluate" : "pending"
        let entityID = state.entity.map { String($0.id) } ?? "nil"
        let firstID = state.items.first.map { String($0.id) } ?? "nil"
        let lastID = state.items.last.map { String($0.id) } ?? "nil"
        let anchor = state.scrollAnchor.map {
            "\($0.edge.rawValue):\($0.id)#\($0.generation)"
        } ?? "nil"
        let loadedBodyCount = state.bodyStates.values.filter { $0.debugStatus == "loaded" }.count
        MailiaScrollDebugLog(
            "[MailiaScrollDebug] pushTimelineWebState delivery=\(deliveryMode) packet=\(delivery.kind.rawValue) entityID=\(entityID) itemCount=\(state.items.count) firstID=\(firstID) lastID=\(lastID) loading=\(state.isLoadingTimeline) hasOlder=\(state.hasOlderTimeline) hasNewer=\(state.hasNewerTimeline) anchor=\(anchor) bottomInset=\(roundedDebugMetric(state.chromeInsets.bottom)) bodyStates=\(state.bodyStates.count) loadedBodies=\(loadedBodyCount) bytes=\(delivery.byteCount)"
        )
    }

    private func roundedDebugMetric(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }

    private func configureInspectableWebView() {
        #if DEBUG
        webView.isInspectable = true
        TimelineWebDebugMenuController.shared.setActiveWebView(webView)
        #endif
    }

    private func configureContextMenu() {
        guard let webView = webView as? TimelineInspectableWebView else { return }
        webView.contextMenuProvider = contextMenuProvider ?? { NSMenu() }
    }

    private func configureWebViewBackground() {
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .textBackgroundColor
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func configureScrollView() {
        guard let scrollView = firstScrollView(in: webView) else { return }
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .allowed
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
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
        configuration.setValue(false, forKey: "drawsBackground")
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        #if DEBUG
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif
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
      console.error = function() {
        post('error', arguments);
        return originalError.apply(this, arguments);
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
        <p>Build and sync Web/Timeline into the app resources to enable the WKWebView-backed timeline.</p>
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
        openInspector()
    }

    private func openInspector() {
        guard let inspector = activeInspector else {
            NSSound.beep()
            return
        }

        guard inspector.responds(to: Self.showInspectorSelector) else {
            NSSound.beep()
            return
        }

        _ = inspector.perform(Self.showInspectorSelector)

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
    private static let detachInspectorSelector = NSSelectorFromString("detach")
}

extension TimelineWebBridgeCoordinator: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        configureScrollView()
        MailiaScrollDebugLog("[MailiaScrollDebug] timelineWeb didFinish pendingState=\(pendingDelivery != nil)")
        hasFinishedInitialLoad = true
        if let pendingDelivery {
            self.pendingDelivery = nil
            evaluateReceiveDelivery(pendingDelivery)
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

        openExternalURLIfAllowed(url)
        decisionHandler(.cancel)
    }

    private func openExternalURLIfAllowed(_ url: URL) {
        if ["http", "https", "mailto"].contains(url.scheme?.lowercased()) {
            NSWorkspace.shared.open(url)
        }
    }
}

extension TimelineWebBridgeCoordinator: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil,
           let url = navigationAction.request.url {
            openExternalURLIfAllowed(url)
        }
        return nil
    }
}

protocol TimelineWebAssetLocating {
    func timelineIndexURL() -> URL?
}

struct TimelineWebAssetLocator: TimelineWebAssetLocating {
    func timelineIndexURL() -> URL? {
        MailiaAppResources.bundle.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "TimelineWeb"
        )
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

private extension TimelineWebState.BodyState {
    var debugStatus: String {
        switch self {
        case .notRequested:
            "notRequested"
        case .loading:
            "loading"
        case .loaded:
            "loaded"
        case .failed:
            "failed"
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
