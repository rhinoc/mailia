import MailiaCore
import AppKit
import SwiftUI
import WebKit

enum MailiaPreferenceKeys {
    static let timelineBodyDisplayMode = "MailiaTimelineBodyDisplayMode"
    static let loadRemoteContent = "MailiaLoadRemoteContent"
}

private enum TimelineBodyDisplayMode: String, CaseIterable, Identifiable {
    case html
    case markdown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .html:
            "HTML"
        case .markdown:
            "Markdown"
        }
    }
}

@main
@MainActor
final class MailiaApplication: NSObject, NSApplicationDelegate {
    private let viewModel = AppViewModel()
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private static var delegateReference: MailiaApplication?
    private static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("MailiaMainWindow")
    private static let mainWindowDefaultContentSize = NSSize(width: 1180, height: 760)
    private static let mainWindowMinimumContentSize = NSSize(width: 980, height: 640)

    static func main() {
        let application = NSApplication.shared
        let delegate = MailiaApplication()
        delegateReference = delegate
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        showMainWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc private func showSettingsWindow() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mailia Settings"
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView())
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showMainWindow() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.mainWindowDefaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = Self.mainWindowIdentifier
        window.title = "Mailia"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = false
        window.isRestorable = false
        window.contentMinSize = Self.mainWindowMinimumContentSize
        window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: Self.mainWindowMinimumContentSize)).size
        window.center()
        window.contentViewController = NSHostingController(rootView: ContentView(viewModel: viewModel))
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(
            NSMenuItem(
                title: "Settings...",
                action: #selector(showSettingsWindow),
                keyEquivalent: ","
            )
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            NSMenuItem(
                title: "Quit Mailia",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)

        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(
            NSMenuItem(
                title: "Copy",
                action: #selector(NSText.copy(_:)),
                keyEquivalent: "c"
            )
        )
        editMenu.addItem(
            NSMenuItem(
                title: "Select All",
                action: #selector(NSText.selectAll(_:)),
                keyEquivalent: "a"
            )
        )

        let debugMenuItem = NSMenuItem()
        mainMenu.addItem(debugMenuItem)

        let debugMenu = NSMenu(title: "Debug")
        debugMenuItem.submenu = debugMenu

        let inspectorItem = NSMenuItem(
            title: "Open Detached Timeline Inspector",
            action: #selector(TimelineWebDebugMenuController.openDetachedTimelineInspector(_:)),
            keyEquivalent: "i"
        )
        inspectorItem.keyEquivalentModifierMask = [.command, .option]
        inspectorItem.target = TimelineWebDebugMenuController.shared
        debugMenu.addItem(inspectorItem)

        let consoleItem = NSMenuItem(
            title: "Open Timeline Console",
            action: #selector(TimelineWebDebugMenuController.openTimelineConsole(_:)),
            keyEquivalent: "j"
        )
        consoleItem.keyEquivalentModifierMask = [.command, .option]
        consoleItem.target = TimelineWebDebugMenuController.shared
        debugMenu.addItem(consoleItem)

        NSApp.mainMenu = mainMenu
    }
}

private struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility
    @State private var sidebarWasCollapsedByResize = false
    @AppStorage(MailiaPreferenceKeys.loadRemoteContent)
    private var loadRemoteContent = false

    private static let sidebarVisibilityPreferenceKey = "MailiaSidebarVisibility"
    private static let sidebarVisiblePreference = "visible"
    private static let sidebarHiddenPreference = "hidden"
    private let sidebarCollapseWidth: CGFloat = 900
    private let sidebarRestoreWidth: CGFloat = 980
    private var selectedEntity: MailiaEntitySummary? {
        viewModel.entities.first { $0.id == viewModel.selectedEntityID }
    }
    private var selectedTimeline: [MailiaTimelineItem] {
        guard let selectedEntity else { return [] }
        return viewModel.timeline.filter { $0.entityID == selectedEntity.id }
    }
    private var windowTitle: String {
        guard let selectedEntity else { return "Mailia" }
        guard let primaryEmailAddress = selectedEntity.primaryEmailAddress else {
            return selectedEntity.displayName
        }
        return "\(selectedEntity.displayName) <\(primaryEmailAddress)>"
    }

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        _columnVisibility = State(initialValue: Self.preferredSidebarVisibility())
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibilityBinding) {
            EntityListPane(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 430)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        RefreshButton(
                            isRefreshing: viewModel.isRefreshing,
                            status: viewModel.refreshStatus
                        ) {
                            Task {
                                await viewModel.refresh()
                            }
                        }
                    }
                }
        } detail: {
            TimelinePane(
                entity: selectedEntity,
                items: selectedTimeline,
                isLoadingTimeline: viewModel.isLoadingTimeline,
                isLoadingOlderTimeline: viewModel.isLoadingOlderTimeline,
                isLoadingNewerTimeline: viewModel.isLoadingNewerTimeline,
                hasOlderTimeline: viewModel.hasOlderTimeline,
                hasNewerTimeline: viewModel.hasNewerTimeline,
                bodyStates: viewModel.timelineBodyStates,
                attachmentDownloadStates: viewModel.attachmentDownloadStates,
                scrollAnchor: viewModel.timelineScrollAnchor,
                onRequestBody: viewModel.loadBodyIfNeeded,
                onRequestOlder: viewModel.loadOlderTimelineIfNeeded,
                onRequestNewer: viewModel.loadNewerTimelineIfNeeded,
                onSetMessageFlag: viewModel.setMessageFlag,
                onDownloadAttachments: viewModel.downloadAttachments,
                onEntityAction: viewModel.performEntityAction
            )
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowWidthReader())
        .background(WindowTitleUpdater(title: windowTitle))
        .onPreferenceChange(WindowWidthPreferenceKey.self) { width in
            updateSidebarVisibility(for: width)
        }
        .onChange(of: loadRemoteContent) {
            viewModel.remoteContentPreferenceDidChange()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let selectedEntity {
                    Menu {
                        EntityContextMenu(
                            entity: selectedEntity,
                            workspace: selectedEntity.workspace,
                            onAction: viewModel.performEntityAction
                        )
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .help("Entity actions")
                }
            }
        }
        .task {
            await viewModel.load()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                if !Task.isCancelled {
                    await viewModel.refresh()
                }
            }
        }
    }

    private var columnVisibilityBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { columnVisibility },
            set: { newValue in
                columnVisibility = newValue
                sidebarWasCollapsedByResize = false
                Self.saveSidebarVisibility(newValue)
            }
        )
    }

    private func updateSidebarVisibility(for width: CGFloat) {
        guard width > 0 else { return }
        let preferredVisibility = Self.preferredSidebarVisibility()
        if width < sidebarCollapseWidth, columnVisibility != .detailOnly {
            columnVisibility = .detailOnly
            sidebarWasCollapsedByResize = preferredVisibility != .detailOnly
        } else if width > sidebarRestoreWidth, sidebarWasCollapsedByResize, columnVisibility == .detailOnly {
            columnVisibility = preferredVisibility
            sidebarWasCollapsedByResize = false
        }
    }

    private static func preferredSidebarVisibility() -> NavigationSplitViewVisibility {
        let storedValue = UserDefaults.standard.string(forKey: sidebarVisibilityPreferenceKey)
        return storedValue == sidebarHiddenPreference ? .detailOnly : .all
    }

    private static func saveSidebarVisibility(_ visibility: NavigationSplitViewVisibility) {
        let value = visibility == .detailOnly ? sidebarHiddenPreference : sidebarVisiblePreference
        UserDefaults.standard.set(value, forKey: sidebarVisibilityPreferenceKey)
    }
}

private struct WindowWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct WindowWidthReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: WindowWidthPreferenceKey.self, value: proxy.size.width)
        }
    }
}

private struct WindowTitleUpdater: NSViewRepresentable {
    var title: String

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.title = title
            nsView.window?.titleVisibility = .visible
        }
    }
}

private struct EntityListPane: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var showsTopFade = false
    @State private var showsBottomFade = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                NativeSearchField(text: $viewModel.searchQuery, placeholder: "Search")
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            List(selection: $viewModel.selectedEntityID) {
                if viewModel.entities.isEmpty {
                    EmptyEntityRow(searchQuery: viewModel.searchQuery)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(viewModel.entities) { entity in
                        EntityRow(entity: entity)
                            .tag(entity.id)
                            .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                            .listRowSeparator(.hidden)
                            .contextMenu {
                                EntityContextMenu(
                                    entity: entity,
                                    workspace: viewModel.workspace,
                                    onAction: viewModel.performEntityAction
                                )
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                SidebarScrollStateObserver(
                    showsTopFade: $showsTopFade,
                    showsBottomFade: $showsBottomFade
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .overlay(alignment: .top) {
                SidebarScrollFade(edge: .top)
                    .opacity(showsTopFade ? 1 : 0)
            }
            .overlay(alignment: .bottom) {
                SidebarScrollFade(edge: .bottom)
                    .opacity(showsBottomFade ? 1 : 0)
            }

            Spacer(minLength: 0)

            VStack(spacing: 8) {
                Picker("Mailbox", selection: $viewModel.workspace) {
                    Label("Inbox", systemImage: "tray")
                        .labelStyle(.iconOnly)
                        .tag(MailiaWorkspace.main)
                    Label("Flagged", systemImage: "flag")
                        .labelStyle(.iconOnly)
                        .tag(MailiaWorkspace.flagged)
                    Label("Junk", systemImage: "nosign")
                        .labelStyle(.iconOnly)
                        .tag(MailiaWorkspace.junk)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .padding(.top, 6)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct SidebarScrollStateObserver: NSViewRepresentable {
    @Binding var showsTopFade: Bool
    @Binding var showsBottomFade: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(showsTopFade: $showsTopFade, showsBottomFade: $showsBottomFade)
    }

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.onMove = { view in
            context.coordinator.attach(from: view)
        }
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        context.coordinator.showsTopFade = $showsTopFade
        context.coordinator.showsBottomFade = $showsBottomFade
        view.onMove = { view in
            context.coordinator.attach(from: view)
        }
        DispatchQueue.main.async {
            context.coordinator.attach(from: view)
            context.coordinator.updateFadeVisibility()
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class ObserverView: NSView {
        var onMove: ((NSView) -> Void)?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onMove?(self)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onMove?(self)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var showsTopFade: Binding<Bool>
        var showsBottomFade: Binding<Bool>
        private weak var scrollView: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        private var remainingAttachAttempts = 8

        init(showsTopFade: Binding<Bool>, showsBottomFade: Binding<Bool>) {
            self.showsTopFade = showsTopFade
            self.showsBottomFade = showsBottomFade
        }

        func attach(from view: NSView) {
            guard let scrollView = firstNearbyScrollView(from: view) else {
                retryAttach(from: view)
                return
            }

            remainingAttachAttempts = 8

            guard scrollView !== self.scrollView else {
                return
            }

            detach()
            self.scrollView = scrollView

            scrollView.contentView.postsBoundsChangedNotifications = true
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: scrollView.contentView,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.updateFadeVisibility()
                    }
                }
            )

            let frameChangeViews = [scrollView.contentView, scrollView.documentView].compactMap { $0 }
            for view in frameChangeViews {
                view.postsFrameChangedNotifications = true
                observers.append(
                    NotificationCenter.default.addObserver(
                        forName: NSView.frameDidChangeNotification,
                        object: view,
                        queue: .main
                    ) { [weak self] _ in
                        Task { @MainActor in
                            self?.updateFadeVisibility()
                        }
                    }
                )
            }

            updateFadeVisibility()
        }

        private func retryAttach(from view: NSView) {
            guard remainingAttachAttempts > 0 else { return }

            remainingAttachAttempts -= 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak view] in
                guard let self, let view else { return }
                self.attach(from: view)
            }
        }

        func detach() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
            scrollView = nil
        }

        func updateFadeVisibility() {
            guard let scrollView, let documentView = scrollView.documentView else {
                setFadeVisibility(top: false, bottom: false)
                return
            }

            let visibleBounds = scrollView.contentView.bounds
            let documentHeight = documentView.bounds.height
            let isScrollable = documentHeight > visibleBounds.height + 1
            guard isScrollable else {
                setFadeVisibility(top: false, bottom: false)
                return
            }

            let tolerance: CGFloat = 1
            let atTop: Bool
            let atBottom: Bool
            if documentView.isFlipped {
                atTop = visibleBounds.minY <= tolerance
                atBottom = visibleBounds.maxY >= documentHeight - tolerance
            } else {
                atTop = visibleBounds.maxY >= documentHeight - tolerance
                atBottom = visibleBounds.minY <= tolerance
            }

            setFadeVisibility(top: !atTop, bottom: !atBottom)
        }

        private func setFadeVisibility(top: Bool, bottom: Bool) {
            if showsTopFade.wrappedValue != top {
                showsTopFade.wrappedValue = top
            }
            if showsBottomFade.wrappedValue != bottom {
                showsBottomFade.wrappedValue = bottom
            }
        }

        private func firstNearbyScrollView(from view: NSView) -> NSScrollView? {
            var currentView: NSView? = view
            var remainingAncestorChecks = 8
            while let view = currentView, remainingAncestorChecks > 0 {
                if let scrollView = firstScrollView(in: view) {
                    return scrollView
                }
                currentView = view.superview
                remainingAncestorChecks -= 1
            }
            return nil
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
}

private struct SidebarScrollFade: View {
    enum Edge {
        case top
        case bottom
    }

    let edge: Edge

    var body: some View {
        LinearGradient(
            colors: gradientColors,
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 18)
        .allowsHitTesting(false)
    }

    private var gradientColors: [Color] {
        let background = Color(nsColor: .controlBackgroundColor)
        switch edge {
        case .top:
            return [background, background.opacity(0)]
        case .bottom:
            return [background.opacity(0), background]
        }
    }
}

private struct RefreshButton: View {
    let isRefreshing: Bool
    let status: String
    let action: () -> Void
    @State private var isShowingStatus = false

    var body: some View {
        Button {
            guard !isRefreshing else { return }
            action()
        } label: {
            Image(systemName: "arrow.clockwise")
                .frame(width: 18, height: 18, alignment: .center)
                .symbolEffect(.rotate, options: .repeating.speed(0.85), value: isRefreshing)
        }
        .onHover { hovering in
            isShowingStatus = hovering
        }
        .popover(isPresented: $isShowingStatus, arrowEdge: .top) {
            RefreshStatusPopover(status: status)
        }
        .help("Refresh\n\(status)")
    }
}

private struct RefreshStatusPopover: View {
    let status: String

    var body: some View {
        Text(status)
            .font(.caption)
            .foregroundStyle(.primary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minWidth: 180, maxWidth: 280, alignment: .leading)
    }
}

private struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.placeholderString = placeholder
        searchField.controlSize = .large
        searchField.font = .systemFont(ofSize: NSFont.systemFontSize(for: .large))
        searchField.target = context.coordinator
        searchField.action = #selector(Coordinator.changed(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return searchField
    }

    func updateNSView(_ searchField: NSSearchField, context: Context) {
        if searchField.stringValue != text {
            searchField.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        @MainActor
        @objc func changed(_ sender: NSSearchField) {
            text.wrappedValue = sender.stringValue
        }
    }
}

private struct EntityRow: View {
    let entity: MailiaEntitySummary

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            EntityAvatar(entity: entity)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entity.displayName)
                            .font(.headline)
                            .lineLimit(1)
                            .layoutPriority(2)

                        if let primaryEmailAddress = entity.primaryEmailAddress {
                            Text(primaryEmailAddress)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .layoutPriority(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(2)

                    Spacer(minLength: 4)

                    HStack(alignment: .top, spacing: 5) {
                        if !entity.accountLabel.isEmpty {
                            BadgeLabel(text: entity.accountLabel)
                                .frame(maxWidth: 88, alignment: .trailing)
                        }

                        if entity.unreadCount > 0 {
                            Text("\(entity.unreadCount)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor))
                                .accessibilityLabel("\(entity.unreadCount) unread")
                                .fixedSize(horizontal: true, vertical: false)
                                .layoutPriority(10)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(0)
                }

                HStack(spacing: 6) {
                    Text(entity.latestSubject)
                        .font(.subheadline)
                        .foregroundStyle(entity.unreadCount > 0 ? .primary : .secondary)
                        .lineLimit(1)
                        .layoutPriority(0)

                    Spacer(minLength: 8)

                    if let latestDate = entity.latestDate {
                        RelativeTimeText(date: latestDate)
                    }
                }
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct EntityAvatar: View {
    let entity: MailiaEntitySummary
    var size: CGFloat = 34

    var body: some View {
        if let image = avatarImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Circle()
                .fill(Color.secondary.opacity(0.24))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    private var avatarImage: NSImage? {
        if let dataURL = entity.avatarImageDataURL,
           let image = NSImage.mailiaImage(dataURL: dataURL) {
            return image
        }

        return EntityAvatarRenderer.image(
            id: entity.id,
            displayName: entity.displayName,
            size: size
        )
    }
}

private struct EmptyEntityRow: View {
    let searchQuery: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(searchQuery.isEmpty ? "No entities in this workspace" : "No matching entities")
                .font(.headline)

            Text(searchQuery.isEmpty ? "Connect an account or refresh after repository wiring lands." : "Try a broader search term.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 16)
    }
}

private struct TimelinePane: View {
    let entity: MailiaEntitySummary?
    let items: [MailiaTimelineItem]
    let isLoadingTimeline: Bool
    let isLoadingOlderTimeline: Bool
    let isLoadingNewerTimeline: Bool
    let hasOlderTimeline: Bool
    let hasNewerTimeline: Bool
    let bodyStates: [Int64: MailiaTimelineBodyState]
    let attachmentDownloadStates: [Int64: MailiaAttachmentDownloadState]
    let scrollAnchor: MailiaTimelineScrollAnchor?
    let onRequestBody: (MailiaTimelineItem) -> Void
    let onRequestOlder: () -> Void
    let onRequestNewer: () -> Void
    let onSetMessageFlag: (MailiaTimelineItem, Bool) -> Void
    let onDownloadAttachments: (MailiaTimelineItem) -> Void
    let onEntityAction: (MailiaEntityAction, MailiaEntitySummary) -> Void

    var body: some View {
        Group {
            if let entity {
                TimelineBody(
                    entity: entity,
                    items: items,
                    isLoadingTimeline: isLoadingTimeline,
                    isLoadingOlderTimeline: isLoadingOlderTimeline,
                    isLoadingNewerTimeline: isLoadingNewerTimeline,
                    hasOlderTimeline: hasOlderTimeline,
                    hasNewerTimeline: hasNewerTimeline,
                    bodyStates: bodyStates,
                    attachmentDownloadStates: attachmentDownloadStates,
                    scrollAnchor: scrollAnchor,
                    onRequestBody: onRequestBody,
                    onRequestOlder: onRequestOlder,
                    onRequestNewer: onRequestNewer,
                    onSetMessageFlag: onSetMessageFlag,
                    onDownloadAttachments: onDownloadAttachments,
                    onEntityAction: onEntityAction
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No conversation selected")
                        .font(.title3.weight(.semibold))
                    Text("Choose a sender from the sidebar.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }
}

private struct TimelineBody: View {
    private static let maximumHTMLHeight: CGFloat = 1024

    let entity: MailiaEntitySummary
    let items: [MailiaTimelineItem]
    let isLoadingTimeline: Bool
    let isLoadingOlderTimeline: Bool
    let isLoadingNewerTimeline: Bool
    let hasOlderTimeline: Bool
    let hasNewerTimeline: Bool
    let bodyStates: [Int64: MailiaTimelineBodyState]
    let attachmentDownloadStates: [Int64: MailiaAttachmentDownloadState]
    let scrollAnchor: MailiaTimelineScrollAnchor?
    let onRequestBody: (MailiaTimelineItem) -> Void
    let onRequestOlder: () -> Void
    let onRequestNewer: () -> Void
    let onSetMessageFlag: (MailiaTimelineItem, Bool) -> Void
    let onDownloadAttachments: (MailiaTimelineItem) -> Void
    let onEntityAction: (MailiaEntityAction, MailiaEntitySummary) -> Void
    @State private var isPreparingInitialPosition = true
    @AppStorage(MailiaPreferenceKeys.timelineBodyDisplayMode)
    private var bodyDisplayMode = TimelineBodyDisplayMode.html.rawValue
    @AppStorage(MailiaPreferenceKeys.loadRemoteContent)
    private var loadRemoteContent = false

    var body: some View {
        TimelineWebView(
            state: webState,
            items: items,
            entity: entity,
            onRequestBody: onRequestBody,
            onRequestOlder: onRequestOlder,
            onRequestNewer: onRequestNewer,
            onSetMessageFlag: onSetMessageFlag,
            onDownloadAttachments: onDownloadAttachments,
            onEntityAction: onEntityAction
        )
        .background(Color(nsColor: .textBackgroundColor))
        .contextMenu {
            EntityContextMenu(
                entity: entity,
                workspace: entity.workspace,
                onAction: onEntityAction
            )
        }
        .task(id: entity.id) {
            isPreparingInitialPosition = true
            await Task.yield()
            try? await Task.sleep(nanoseconds: 100_000_000)
            if !Task.isCancelled {
                isPreparingInitialPosition = false
            }
        }
    }

    private var webState: TimelineWebState {
        TimelineWebState(
            entity: entity,
            items: items,
            isLoadingTimeline: isLoadingTimeline,
            isLoadingOlderTimeline: isLoadingOlderTimeline,
            isLoadingNewerTimeline: isLoadingNewerTimeline,
            hasOlderTimeline: !isPreparingInitialPosition && hasOlderTimeline,
            hasNewerTimeline: !isPreparingInitialPosition && hasNewerTimeline,
            bodyStates: bodyStates,
            attachmentDownloadStates: attachmentDownloadStates,
            scrollAnchor: scrollAnchor,
            bodyDisplayMode: bodyDisplayMode,
            loadRemoteContent: loadRemoteContent
        )
    }
}

private struct TimelinePageMarker: View {
    let isLoading: Bool
    var body: some View {
        HStack {
            Spacer()
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Color.clear
                    .frame(width: 1, height: 1)
            }
            Spacer()
        }
        .frame(height: 32)
    }
}

private struct TimelineCollectionView: NSViewRepresentable {
    let entityID: Int64
    let items: [MailiaTimelineItem]
    let isLoadingTimeline: Bool
    let isLoadingOlderTimeline: Bool
    let isLoadingNewerTimeline: Bool
    let hasOlderTimeline: Bool
    let hasNewerTimeline: Bool
    let bodyStates: [Int64: MailiaTimelineBodyState]
    let attachmentDownloadStates: [Int64: MailiaAttachmentDownloadState]
    let scrollAnchor: MailiaTimelineScrollAnchor?
    let canRequestTop: Bool
    let canRequestBottom: Bool
    let onRequestTop: () -> Void
    let onRequestBottom: () -> Void
    let onRequestBody: (MailiaTimelineItem) -> Void
    let onSetMessageFlag: (MailiaTimelineItem, Bool) -> Void
    let onDownloadAttachments: (MailiaTimelineItem) -> Void
    let renderedHTMLMessageIDs: Set<Int64>
    let measuredHTMLHeightsByMessageID: [Int64: CGFloat]
    let canRequestBody: Bool
    let maximumHTMLHeight: CGFloat
    let onHTMLRendered: (Int64, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 12
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 8)

        let collectionView = NSCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.textBackgroundColor]
        collectionView.register(TimelineMessageCollectionItem.self, forItemWithIdentifier: TimelineMessageCollectionItem.identifier)
        collectionView.register(TimelineMarkerCollectionItem.self, forItemWithIdentifier: TimelineMarkerCollectionItem.identifier)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .automatic
        scrollView.horizontalScrollElasticity = .none
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = collectionView

        context.coordinator.collectionView = collectionView
        context.coordinator.observe(scrollView: scrollView)
        context.coordinator.apply(view: self, to: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.apply(view: self, to: scrollView)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
        fileprivate weak var collectionView: NSCollectionView?
        private var entries: [TimelineCollectionEntry] = []
        private var entrySignature: String = ""
        private var bodyStates: [Int64: MailiaTimelineBodyState] = [:]
        private var attachmentDownloadStates: [Int64: MailiaAttachmentDownloadState] = [:]
        private var renderedHTMLMessageIDs: Set<Int64> = []
        private var measuredHTMLHeightsByMessageID: [Int64: CGFloat] = [:]
        private var measuredRowHeightsByMessageID: [Int64: CGFloat] = [:]
        private var pendingMeasuredRowHeightsByMessageID: [Int64: CGFloat] = [:]
        private var isApplyingMeasuredRowHeights = false
        private var messagesByID: [Int64: MailiaTimelineItem] = [:]
        private var onRequestTop: (() -> Void)?
        private var onRequestBottom: (() -> Void)?
        private var onRequestBody: ((MailiaTimelineItem) -> Void)?
        private var onSetMessageFlag: ((MailiaTimelineItem, Bool) -> Void)?
        private var onDownloadAttachments: ((MailiaTimelineItem) -> Void)?
        private var onHTMLRendered: ((Int64, CGFloat) -> Void)?
        private var canRequestTop = false
        private var canRequestBottom = false
        private var canRequestBody = false
        private var maximumHTMLHeight: CGFloat = 1024
        private var currentEntityID: Int64?
        private var lastAppliedAnchorGeneration: Int?
        private var applyCount = 0
        private var heightUpdateCount = 0
        private var lastRequestedTopTriggerID: Int64?
        private var lastRequestedBottomTriggerID: Int64?
        private weak var observedScrollView: NSScrollView?
        private var isAdjustingScroll = false
        private let edgeThreshold: CGFloat = 96

        fileprivate func apply(view: TimelineCollectionView, to scrollView: NSScrollView) {
            guard let collectionView else { return }
            let previousEntityID = currentEntityID
            let entityChanged = previousEntityID != view.entityID
            let previousAnchorGeneration = lastAppliedAnchorGeneration
            let anchorChanged = view.scrollAnchor?.generation != nil && view.scrollAnchor?.generation != previousAnchorGeneration
            let anchorSnapshot = captureRestoreAnchor(
                for: view.scrollAnchor,
                anchorChanged: anchorChanged,
                entityChanged: entityChanged,
                in: scrollView
            )
            let wasAtBottom = metrics(in: scrollView).wasAtBottom
            applyCount += 1
            TimelineDebugLog.log(
                "apply #\(applyCount) entity=\(view.entityID) entityChanged=\(entityChanged) items=\(view.items.count) loading=\(view.isLoadingTimeline) older=\(view.hasOlderTimeline)/\(view.isLoadingOlderTimeline) newer=\(view.hasNewerTimeline)/\(view.isLoadingNewerTimeline) anchor=\(Self.describe(view.scrollAnchor)) anchorChanged=\(anchorChanged) wasAtBottom=\(wasAtBottom) visible=\(describeVisible(in: scrollView))"
            )

            currentEntityID = view.entityID
            onRequestTop = view.onRequestTop
            onRequestBottom = view.onRequestBottom
            onRequestBody = view.onRequestBody
            onSetMessageFlag = view.onSetMessageFlag
            onDownloadAttachments = view.onDownloadAttachments
            onHTMLRendered = view.onHTMLRendered
            canRequestTop = view.canRequestTop
            canRequestBottom = view.canRequestBottom
            canRequestBody = view.canRequestBody
            maximumHTMLHeight = view.maximumHTMLHeight
            bodyStates = view.bodyStates
            attachmentDownloadStates = view.attachmentDownloadStates
            renderedHTMLMessageIDs = view.renderedHTMLMessageIDs
            measuredHTMLHeightsByMessageID = view.measuredHTMLHeightsByMessageID
            messagesByID = Dictionary(uniqueKeysWithValues: view.items.map { ($0.id, $0) })

            if entityChanged {
                measuredRowHeightsByMessageID = measuredRowHeightsByMessageID.filter { id, _ in
                    view.items.contains { $0.id == id }
                }
                lastRequestedTopTriggerID = nil
                lastRequestedBottomTriggerID = nil
            }

            let nextEntries = Self.makeEntries(
                items: view.items,
                isLoadingTimeline: view.isLoadingTimeline,
                isLoadingOlderTimeline: view.isLoadingOlderTimeline,
                isLoadingNewerTimeline: view.isLoadingNewerTimeline,
                hasOlderTimeline: view.hasOlderTimeline,
                hasNewerTimeline: view.hasNewerTimeline
            )
            let nextEntrySignature = Self.entrySignature(
                entries: nextEntries,
                bodyStates: bodyStates,
                attachmentDownloadStates: attachmentDownloadStates,
                measuredHTMLHeightsByMessageID: measuredHTMLHeightsByMessageID
            )
            let needsReload = nextEntrySignature != entrySignature
            entries = nextEntries

            if needsReload {
                entrySignature = nextEntrySignature
                collectionView.reloadData()
            } else {
                collectionView.collectionViewLayout?.invalidateLayout()
            }
            collectionView.layoutSubtreeIfNeeded()

            if anchorChanged, let scrollAnchor = view.scrollAnchor {
                lastAppliedAnchorGeneration = scrollAnchor.generation
                switch scrollAnchor.edge {
                case .top:
                    if let anchorSnapshot {
                        TimelineDebugLog.log("restore top anchor message=\(anchorSnapshot.messageID) offset=\(Int(anchorSnapshot.offsetFromVisibleTop))")
                        restore(anchorSnapshot, in: scrollView)
                    } else {
                        TimelineDebugLog.log("missing top anchor id=\(scrollAnchor.id)")
                    }
                case .bottom:
                    TimelineDebugLog.log("restore bottom anchor id=\(scrollAnchor.id)")
                    scrollToBottom(in: scrollView)
                }
            } else if entityChanged {
                TimelineDebugLog.log("entity changed, scroll to bottom")
                scrollToBottom(in: scrollView)
            } else if wasAtBottom {
                TimelineDebugLog.log("kept bottom after update")
                scrollToBottom(in: scrollView)
            } else if let anchorSnapshot {
                TimelineDebugLog.log("preserve visible anchor message=\(anchorSnapshot.messageID) offset=\(Int(anchorSnapshot.offsetFromVisibleTop))")
                restore(anchorSnapshot, in: scrollView)
            }

            requestPagesIfNeeded(in: scrollView)
        }

        fileprivate func observe(scrollView: NSScrollView) {
            observedScrollView = scrollView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
            )
        }

        fileprivate func stopObserving() {
            NotificationCenter.default.removeObserver(self)
            observedScrollView = nil
        }

        @objc private func boundsDidChange(_ notification: Notification) {
            guard let observedScrollView, !isAdjustingScroll else { return }
            requestPagesIfNeeded(in: observedScrollView)
        }

        fileprivate func numberOfSections(in collectionView: NSCollectionView) -> Int {
            1
        }

        fileprivate func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            entries.count
        }

        fileprivate func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            let entry = entries[indexPath.item]
            switch entry.kind {
            case .marker(let isLoading):
                let item = collectionView.makeItem(
                    withIdentifier: TimelineMarkerCollectionItem.identifier,
                    for: indexPath
                ) as? TimelineMarkerCollectionItem ?? TimelineMarkerCollectionItem()
                item.configure(isLoading: isLoading)
                return item
            case .message(let message):
                let item = collectionView.makeItem(
                    withIdentifier: TimelineMessageCollectionItem.identifier,
                    for: indexPath
                ) as? TimelineMessageCollectionItem ?? TimelineMessageCollectionItem()
                let row = TimelineMessageRow(
                    item: message,
                    bodyState: bodyStates[message.id] ?? .notRequested,
                    attachmentDownloadState: attachmentDownloadStates[message.id] ?? .idle,
                    maxHTMLHeight: maximumHTMLHeight,
                    canRequestBody: canRequestBody,
                    renderHTMLImmediately: renderedHTMLMessageIDs.contains(message.id),
                    cachedHTMLHeight: measuredHTMLHeightsByMessageID[message.id],
                    onRequestBody: { [weak self] item in
                        self?.onRequestBody?(item)
                    },
                    onSetMessageFlag: { [weak self] item, isFlagged in
                        self?.onSetMessageFlag?(item, isFlagged)
                    },
                    onDownloadAttachments: { [weak self] item in
                        self?.onDownloadAttachments?(item)
                    },
                    onHTMLRendered: { [weak self] messageID, height in
                        self?.onHTMLRendered?(messageID, height)
                    }
                )
                item.configure(messageID: message.id, row: row) { [weak self] messageID, height in
                    self?.recordMeasuredRowHeight(messageID: messageID, height: height)
                }
                return item
            }
        }

        fileprivate func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> NSSize {
            let horizontalInsets: CGFloat = 20
            let width = max(collectionView.enclosingScrollView?.contentView.bounds.width ?? collectionView.bounds.width, 1)
            let itemWidth = max(width - horizontalInsets, 1)
            let entry = entries[indexPath.item]
            switch entry.kind {
            case .marker:
                return NSSize(width: itemWidth, height: 32)
            case .message(let message):
                return NSSize(width: itemWidth, height: layoutHeight(for: message, itemWidth: itemWidth))
            }
        }

        private func layoutHeight(for message: MailiaTimelineItem, itemWidth: CGFloat) -> CGFloat {
            let attachmentHeight: CGFloat = message.hasAttachments ? 42 : 0
            switch bodyStates[message.id] ?? .notRequested {
            case .notRequested:
                return 106 + attachmentHeight
            case .loading:
                return 410 + attachmentHeight
            case .failed:
                return 180 + attachmentHeight
            case .loaded(let body):
                if body.html != nil || message.html != nil {
                    let htmlHeight = measuredHTMLHeightsByMessageID[message.id] ?? 320
                    return min(max(htmlHeight, 1), maximumHTMLHeight) + 90 + attachmentHeight
                }
                let text = body.text ?? message.preview
                return textRowHeight(text: text, itemWidth: itemWidth) + attachmentHeight
            }
        }

        private func textRowHeight(text: String, itemWidth: CGFloat) -> CGFloat {
            let bubbleWidth = min(max(itemWidth - 56, 240), 640)
            let textWidth = max(bubbleWidth - 24, 1)
            let font = NSFont.preferredFont(forTextStyle: .body)
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            let measured = (text as NSString).boundingRect(
                with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes
            )
            return min(max(ceil(measured.height) + 88, 106), 520)
        }

        private func recordMeasuredRowHeight(messageID: Int64, height: CGFloat) {
            guard height > 1 else { return }
            let roundedHeight = ceil(height)
            guard let message = messagesByID[messageID] else { return }
            let width = max((collectionView?.enclosingScrollView?.contentView.bounds.width ?? collectionView?.bounds.width ?? 1) - 20, 1)
            let expectedHeight = layoutHeight(for: message, itemWidth: width)
            if abs(expectedHeight - roundedHeight) > 16 {
                TimelineDebugLog.log("height mismatch message=\(messageID) formula=\(Int(expectedHeight)) fitting=\(Int(roundedHeight)) state=\(bodyStateDescription(for: messageID))")
            }
        }

        private func bodyStateDescription(for messageID: Int64) -> String {
            switch bodyStates[messageID] ?? .notRequested {
            case .notRequested:
                return "notRequested"
            case .loading:
                return "loading"
            case .failed:
                return "failed"
            case .loaded(let body):
                if body.html != nil || messagesByID[messageID]?.html != nil {
                    return "loadedHTML(\(Int(measuredHTMLHeightsByMessageID[messageID] ?? 320)))"
                }
                return "loadedText"
            }
        }

        private func applyMeasuredRowHeightUpdates() {
            isApplyingMeasuredRowHeights = false
            let pendingHeights = pendingMeasuredRowHeightsByMessageID
            pendingMeasuredRowHeightsByMessageID = [:]
            guard !pendingHeights.isEmpty else { return }

            var changedHeights = false
            for (messageID, height) in pendingHeights {
                if let currentHeight = measuredRowHeightsByMessageID[messageID],
                   abs(currentHeight - height) <= 2 {
                    continue
                }
                measuredRowHeightsByMessageID[messageID] = height
                changedHeights = true
            }
            guard changedHeights else { return }
            guard let scrollView = observedScrollView,
                  let collectionView else { return }

            heightUpdateCount += 1
            let summary = pendingHeights
                .sorted { $0.key < $1.key }
                .prefix(8)
                .map { "\($0.key):\(Int($0.value))" }
                .joined(separator: ",")
            TimelineDebugLog.log("height update #\(heightUpdateCount) count=\(pendingHeights.count) sample=[\(summary)] visible=\(describeVisible(in: scrollView))")

            let anchor = captureVisibleAnchor(in: scrollView)
            let wasAtBottom = metrics(in: scrollView).wasAtBottom
            collectionView.collectionViewLayout?.invalidateLayout()
            collectionView.layoutSubtreeIfNeeded()
            if wasAtBottom {
                scrollToBottom(in: scrollView)
            } else if let anchor {
                restore(anchor, in: scrollView)
            }
        }

        private func requestPagesIfNeeded(in scrollView: NSScrollView) {
            let metrics = metrics(in: scrollView)
            if canRequestTop,
               metrics.distanceFromTop <= edgeThreshold,
               let topTriggerID = firstMessageID,
               topTriggerID != lastRequestedTopTriggerID {
                lastRequestedTopTriggerID = topTriggerID
                TimelineDebugLog.log("request older trigger id=\(topTriggerID) metrics=\(describe(metrics))")
                onRequestTop?()
            }

            if canRequestBottom,
               metrics.distanceFromBottom <= edgeThreshold,
               let bottomTriggerID = lastMessageID,
               bottomTriggerID != lastRequestedBottomTriggerID {
                lastRequestedBottomTriggerID = bottomTriggerID
                TimelineDebugLog.log("request newer trigger id=\(bottomTriggerID) metrics=\(describe(metrics))")
                onRequestBottom?()
            }
        }

        private func metrics(in scrollView: NSScrollView) -> ScrollMetrics {
            guard let documentView = scrollView.documentView else {
                return ScrollMetrics(distanceFromTop: 0, distanceFromBottom: 0, wasAtBottom: true)
            }
            let visibleBounds = scrollView.contentView.bounds
            let maximumY = max(documentView.bounds.height - visibleBounds.height, 0)
            let originY = min(max(visibleBounds.origin.y, 0), maximumY)
            let distanceFromBottom = max(maximumY - originY, 0)
            return ScrollMetrics(
                distanceFromTop: originY,
                distanceFromBottom: distanceFromBottom,
                wasAtBottom: distanceFromBottom <= edgeThreshold
            )
        }

        private func scrollToBottom(in scrollView: NSScrollView) {
            guard let documentView = scrollView.documentView else { return }
            let maximumY = max(documentView.bounds.height - scrollView.contentView.bounds.height, 0)
            TimelineDebugLog.log("scrollToBottom targetY=\(Int(maximumY)) docH=\(Int(documentView.bounds.height)) viewH=\(Int(scrollView.contentView.bounds.height))")
            scroll(to: NSPoint(x: 0, y: maximumY), in: scrollView)
        }

        private func captureRestoreAnchor(
            for scrollAnchor: MailiaTimelineScrollAnchor?,
            anchorChanged: Bool,
            entityChanged: Bool,
            in scrollView: NSScrollView
        ) -> TimelineRestoreAnchor? {
            if anchorChanged,
               let scrollAnchor,
               scrollAnchor.edge == .top,
               let anchor = captureAnchor(for: scrollAnchor.id, in: scrollView) {
                return anchor
            }
            guard !entityChanged else { return nil }
            return captureVisibleAnchor(in: scrollView)
        }

        private func captureVisibleAnchor(in scrollView: NSScrollView) -> TimelineRestoreAnchor? {
            guard let collectionView else { return nil }
            let visibleBounds = scrollView.contentView.bounds
            let visibleIndexPaths = collectionView.indexPathsForVisibleItems().sorted { lhs, rhs in
                lhs.item < rhs.item
            }
            for indexPath in visibleIndexPaths {
                guard entries.indices.contains(indexPath.item),
                      case .message(let message) = entries[indexPath.item].kind,
                      let attributes = collectionView.layoutAttributesForItem(at: indexPath),
                      attributes.frame.maxY >= visibleBounds.minY + 1
                else {
                    continue
                }
                return TimelineRestoreAnchor(
                    messageID: message.id,
                    offsetFromVisibleTop: attributes.frame.minY - visibleBounds.minY
                )
            }
            return nil
        }

        private func captureAnchor(for messageID: Int64, in scrollView: NSScrollView) -> TimelineRestoreAnchor? {
            guard let collectionView,
                  let index = entries.firstIndex(where: { $0.messageID == messageID }),
                  let attributes = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))
            else {
                return nil
            }
            return TimelineRestoreAnchor(
                messageID: messageID,
                offsetFromVisibleTop: attributes.frame.minY - scrollView.contentView.bounds.minY
            )
        }

        private func restore(_ anchor: TimelineRestoreAnchor, in scrollView: NSScrollView) {
            guard let collectionView,
                  let index = entries.firstIndex(where: { $0.messageID == anchor.messageID }),
                  let attributes = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))
            else {
                return
            }
            let maximumY = max((scrollView.documentView?.bounds.height ?? 0) - scrollView.contentView.bounds.height, 0)
            let targetY = min(max(attributes.frame.minY - anchor.offsetFromVisibleTop, 0), maximumY)
            TimelineDebugLog.log("restore message=\(anchor.messageID) targetY=\(Int(targetY)) maxY=\(Int(maximumY)) frameY=\(Int(attributes.frame.minY))")
            scroll(to: NSPoint(x: 0, y: targetY), in: scrollView)
        }

        private func scroll(to point: NSPoint, in scrollView: NSScrollView) {
            isAdjustingScroll = true
            scrollView.contentView.scroll(to: point)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isAdjustingScroll = false
        }

        private var firstMessageID: Int64? {
            entries.compactMap(\.messageID).first
        }

        private var lastMessageID: Int64? {
            entries.compactMap(\.messageID).last
        }

        private static func makeEntries(
            items: [MailiaTimelineItem],
            isLoadingTimeline: Bool,
            isLoadingOlderTimeline: Bool,
            isLoadingNewerTimeline: Bool,
            hasOlderTimeline: Bool,
            hasNewerTimeline: Bool
        ) -> [TimelineCollectionEntry] {
            var entries: [TimelineCollectionEntry] = []
            if isLoadingTimeline {
                entries.append(TimelineCollectionEntry(id: "loading", kind: .marker(isLoading: true)))
            }
            if hasOlderTimeline || isLoadingOlderTimeline {
                entries.append(TimelineCollectionEntry(id: "older", kind: .marker(isLoading: isLoadingOlderTimeline)))
            }
            entries.append(contentsOf: items.map { item in
                TimelineCollectionEntry(id: "message-\(item.id)", kind: .message(item))
            })
            if hasNewerTimeline || isLoadingNewerTimeline {
                entries.append(TimelineCollectionEntry(id: "newer", kind: .marker(isLoading: isLoadingNewerTimeline)))
            }
            return entries
        }

        private static func entrySignature(
            entries: [TimelineCollectionEntry],
            bodyStates: [Int64: MailiaTimelineBodyState],
            attachmentDownloadStates: [Int64: MailiaAttachmentDownloadState],
            measuredHTMLHeightsByMessageID: [Int64: CGFloat]
        ) -> String {
            entries.map { entry in
                switch entry.kind {
                case .marker(let isLoading):
                    return "\(entry.id):marker:\(isLoading)"
                case .message(let message):
                    let body = bodyStateSignature(bodyStates[message.id] ?? .notRequested)
                    let attachment = attachmentStateSignature(attachmentDownloadStates[message.id] ?? .idle)
                    let htmlHeight = Int(measuredHTMLHeightsByMessageID[message.id] ?? 0)
                    return "\(message.id):\(body):\(attachment):\(htmlHeight):\(message.isFlagged):\(message.hasAttachments)"
                }
            }.joined(separator: "|")
        }

        private static func bodyStateSignature(_ state: MailiaTimelineBodyState) -> String {
            switch state {
            case .notRequested:
                return "notRequested"
            case .loading:
                return "loading"
            case .loaded(let body):
                return "loaded:\(body.html?.count ?? 0):\(body.text?.count ?? 0)"
            case .failed(let message):
                return "failed:\(message)"
            }
        }

        private static func attachmentStateSignature(_ state: MailiaAttachmentDownloadState) -> String {
            switch state {
            case .idle:
                return "idle"
            case .downloading:
                return "downloading"
            case .downloaded(let result):
                return "downloaded:\(result.fileNames.count)"
            case .failed(let message):
                return "failed:\(message)"
            }
        }

        private func describeVisible(in scrollView: NSScrollView) -> String {
            let bounds = scrollView.contentView.bounds
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            return "y=\(Int(bounds.origin.y)) h=\(Int(bounds.height)) docH=\(Int(documentHeight))"
        }

        private func describe(_ metrics: ScrollMetrics) -> String {
            "top=\(Int(metrics.distanceFromTop)) bottom=\(Int(metrics.distanceFromBottom)) atBottom=\(metrics.wasAtBottom)"
        }

        private static func describe(_ anchor: MailiaTimelineScrollAnchor?) -> String {
            guard let anchor else { return "nil" }
            return "\(anchor.edge) id=\(anchor.id) gen=\(anchor.generation)"
        }
    }

    fileprivate struct ScrollMetrics {
        let distanceFromTop: CGFloat
        let distanceFromBottom: CGFloat
        let wasAtBottom: Bool
    }

    private struct TimelineRestoreAnchor {
        let messageID: Int64
        let offsetFromVisibleTop: CGFloat
    }
}

private enum TimelineDebugLog {
    static func log(_ message: @autoclosure () -> String) {
        NSLog("[MailiaTimeline] \(message())")
    }
}

private struct TimelineCollectionEntry {
    enum Kind {
        case marker(isLoading: Bool)
        case message(MailiaTimelineItem)
    }

    let id: String
    let kind: Kind

    var messageID: Int64? {
        if case .message(let message) = kind {
            return message.id
        }
        return nil
    }
}

private final class TimelineMarkerCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("TimelineMarkerCollectionItem")
    private var hostingView: NSHostingView<AnyView>?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    func configure(isLoading: Bool) {
        let rootView = AnyView(TimelinePageMarker(isLoading: isLoading))
        if let hostingView {
            hostingView.rootView = rootView
        } else {
            let hostingView = NSHostingView(rootView: rootView)
            hostingView.autoresizingMask = [.width, .height]
            view.addSubview(hostingView)
            self.hostingView = hostingView
        }
        hostingView?.frame = view.bounds
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        hostingView?.frame = view.bounds
    }
}

private final class TimelineMessageCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("TimelineMessageCollectionItem")
    private var hostingView: NSHostingView<AnyView>?
    private var messageID: Int64?
    private var hostedMessageID: Int64?
    private var onMeasuredHeight: ((Int64, CGFloat) -> Void)?
    private var lastOverflowLogHeight: CGFloat = 0

    override func loadView() {
        view = TimelineMessageCellView()
    }

    func configure(
        messageID: Int64,
        row: TimelineMessageRow,
        onMeasuredHeight: @escaping (Int64, CGFloat) -> Void
    ) {
        self.messageID = messageID
        self.onMeasuredHeight = onMeasuredHeight
        let rootView = AnyView(row.id(messageID).fixedSize(horizontal: false, vertical: true))
        if let hostingView, hostedMessageID == messageID {
            hostingView.rootView = rootView
        } else {
            hostingView?.removeFromSuperview()
            let hostingView = NSHostingView(rootView: rootView)
            hostingView.autoresizingMask = [.width]
            view.addSubview(hostingView)
            self.hostingView = hostingView
            hostedMessageID = messageID
            lastOverflowLogHeight = 0
        }
        layoutHostingView()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutHostingView()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        messageID = nil
        hostedMessageID = nil
        onMeasuredHeight = nil
        hostingView?.removeFromSuperview()
        hostingView = nil
        lastOverflowLogHeight = 0
    }

    func remeasure() {
        layoutHostingView()
    }

    private func layoutHostingView() {
        guard let hostingView else { return }
        let width = max(view.bounds.width, 1)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: view.bounds.height)
        let measuredHeight = max(ceil(hostingView.fittingSize.height), 1)
        guard let messageID else { return }
        let allocatedHeight = view.bounds.height
        if measuredHeight > allocatedHeight + 4,
           abs(measuredHeight - lastOverflowLogHeight) > 4 {
            lastOverflowLogHeight = measuredHeight
            TimelineDebugLog.log("cell overflow message=\(messageID) measured=\(Int(measuredHeight)) allocated=\(Int(allocatedHeight))")
        }
        onMeasuredHeight?(messageID, measuredHeight)
    }
}

private final class TimelineMessageCellView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }
}

private enum RelativeTimeLabel {
    static func string(from date: Date, relativeTo now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        let isFuture = seconds < 0
        let absoluteSeconds = abs(seconds)

        let value: Int
        let unit: String
        switch absoluteSeconds {
        case 0..<60:
            return "just now"
        case 60..<3_600:
            value = absoluteSeconds / 60
            unit = "minute"
        case 3_600..<86_400:
            value = absoluteSeconds / 3_600
            unit = "hour"
        case 86_400..<2_592_000:
            value = absoluteSeconds / 86_400
            unit = "day"
        case 2_592_000..<31_536_000:
            value = absoluteSeconds / 2_592_000
            unit = "month"
        default:
            value = absoluteSeconds / 31_536_000
            unit = "year"
        }

        let label = "\(value) \(unit)\(value == 1 ? "" : "s")"
        return isFuture ? "in \(label)" : "\(label) ago"
    }
}

private struct RelativeTimeText: View {
    let date: Date

    var body: some View {
        Text(RelativeTimeLabel.string(from: date))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(10)
    }
}

private struct EntityContextMenu: View {
    let entity: MailiaEntitySummary
    let workspace: MailiaWorkspace
    let onAction: (MailiaEntityAction, MailiaEntitySummary) -> Void

    var body: some View {
        if workspace == .junk {
            Button {
                onAction(.moveToInbox, entity)
            } label: {
                Label("Inbox", systemImage: "tray.and.arrow.down")
            }
        } else {
            Button {
                onAction(.moveToJunk, entity)
            } label: {
                Label("Junk", systemImage: "nosign")
            }
        }

        if workspace == .flagged {
            Button {
                onAction(.removeFlag, entity)
            } label: {
                Label("Unflag", systemImage: "flag.slash")
            }
        } else {
            Button {
                onAction(.flagImportant, entity)
            } label: {
                Label("Flag", systemImage: "flag")
            }
        }

        Button(role: .destructive) {
            onAction(.moveToTrash, entity)
        } label: {
            Label("Trash", systemImage: "trash")
        }
    }
}

private struct TimelineMessageRow: View {
    let item: MailiaTimelineItem
    let bodyState: MailiaTimelineBodyState
    let attachmentDownloadState: MailiaAttachmentDownloadState
    let maxHTMLHeight: CGFloat
    let canRequestBody: Bool
    let renderHTMLImmediately: Bool
    let cachedHTMLHeight: CGFloat?
    let onRequestBody: (MailiaTimelineItem) -> Void
    let onSetMessageFlag: (MailiaTimelineItem, Bool) -> Void
    let onDownloadAttachments: (MailiaTimelineItem) -> Void
    let onHTMLRendered: (Int64, CGFloat) -> Void
    @State private var renderHTML: Bool
    @State private var isRenderingHTML = false
    @State private var measuredHTMLHeight: CGFloat
    @State private var bodyRequestTask: Task<Void, Never>?
    @State private var renderHTMLTask: Task<Void, Never>?

    init(
        item: MailiaTimelineItem,
        bodyState: MailiaTimelineBodyState,
        attachmentDownloadState: MailiaAttachmentDownloadState,
        maxHTMLHeight: CGFloat,
        canRequestBody: Bool,
        renderHTMLImmediately: Bool,
        cachedHTMLHeight: CGFloat?,
        onRequestBody: @escaping (MailiaTimelineItem) -> Void,
        onSetMessageFlag: @escaping (MailiaTimelineItem, Bool) -> Void,
        onDownloadAttachments: @escaping (MailiaTimelineItem) -> Void,
        onHTMLRendered: @escaping (Int64, CGFloat) -> Void
    ) {
        self.item = item
        self.bodyState = bodyState
        self.attachmentDownloadState = attachmentDownloadState
        self.maxHTMLHeight = maxHTMLHeight
        self.canRequestBody = canRequestBody
        self.renderHTMLImmediately = renderHTMLImmediately
        self.cachedHTMLHeight = cachedHTMLHeight
        self.onRequestBody = onRequestBody
        self.onSetMessageFlag = onSetMessageFlag
        self.onDownloadAttachments = onDownloadAttachments
        self.onHTMLRendered = onHTMLRendered
        _renderHTML = State(initialValue: renderHTMLImmediately)
        _measuredHTMLHeight = State(initialValue: cachedHTMLHeight ?? 320)
    }

    private var isOutgoing: Bool {
        item.direction == .outgoing
    }

    private var htmlHeight: CGFloat {
        min(max(measuredHTMLHeight, 1), maxHTMLHeight)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if isOutgoing {
                Spacer(minLength: 56)
            }

            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 6) {
                HStack(spacing: 6) {
                    BadgeLabel(text: item.accountLabel)
                    if !item.folderLabel.isEmpty {
                        BadgeLabel(text: item.folderLabel)
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text(item.subject)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)

                    bodyContent

                    if item.hasAttachments {
                        AttachmentDownloadRow(state: attachmentDownloadState) {
                            onDownloadAttachments(item)
                        }
                    }

                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        Spacer(minLength: 8)

                        if let date = item.date {
                            RelativeTimeText(date: date)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: 640, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isOutgoing ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isOutgoing ? Color.accentColor.opacity(0.24) : Color.secondary.opacity(0.16), lineWidth: 1)
                )
            }

            if !isOutgoing {
                Spacer(minLength: 56)
            }
        }
        .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
        .onAppear {
            requestBodyIfAllowed()
        }
        .onChange(of: item.id) {
            measuredHTMLHeight = cachedHTMLHeight ?? 320
            renderHTML = renderHTMLImmediately
            cancelDeferredWork()
        }
        .onChange(of: renderHTMLImmediately) {
            if renderHTMLImmediately {
                measuredHTMLHeight = cachedHTMLHeight ?? measuredHTMLHeight
                renderHTML = true
            }
        }
        .onChange(of: canRequestBody) {
            requestBodyIfAllowed()
        }
        .onDisappear {
            cancelDeferredWork()
        }
        .contextMenu {
            if item.isFlagged {
                Button {
                    onSetMessageFlag(item, false)
                } label: {
                    Label("Unflag", systemImage: "flag.slash")
                }
            } else {
                Button {
                    onSetMessageFlag(item, true)
                } label: {
                    Label("Flag", systemImage: "flag")
                }
            }
        }
    }

    private func requestBodyIfAllowed() {
        guard canRequestBody else { return }
        bodyRequestTask?.cancel()
        bodyRequestTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            onRequestBody(item)
        }
    }

    private func cancelDeferredWork() {
        bodyRequestTask?.cancel()
        bodyRequestTask = nil
        renderHTMLTask?.cancel()
        renderHTMLTask = nil
    }

    @ViewBuilder
    private var bodyContent: some View {
        switch bodyState {
        case .notRequested:
            placeholderBody
        case .loading:
            loadingBody
        case .loaded(let body):
            if let html = body.html ?? item.html {
                htmlBody(html)
            } else if let text = body.text {
                Text(text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(item.preview)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed:
            VStack(alignment: .leading, spacing: 6) {
                Text(item.preview)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Label("Body unavailable", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var placeholderBody: some View {
        Text(item.preview)
            .font(.body)
            .foregroundStyle(.primary)
            .lineLimit(6)
            .fixedSize(horizontal: false, vertical: true)
            .redacted(reason: .placeholder)
    }

    private var loadingBody: some View {
        ZStack(alignment: .topLeading) {
            placeholderBody
            ProgressView()
                .controlSize(.small)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: min(320, maxHTMLHeight), alignment: .topLeading)
    }

    private func htmlBody(_ html: String) -> some View {
        ZStack(alignment: .topTrailing) {
            if renderHTML {
                MailHTMLView(
                    cacheID: item.id,
                    html: html,
                    maximumExpandedHeight: maxHTMLHeight,
                    isFlagged: item.isFlagged,
                    onLoadingChange: { isLoading in
                        if isRenderingHTML != isLoading {
                            isRenderingHTML = isLoading
                        }
                    },
                    onContentHeightChange: { height in
                        let clampedHeight = min(max(height, 1), maxHTMLHeight)
                        if abs(measuredHTMLHeight - clampedHeight) > 2 {
                            measuredHTMLHeight = clampedHeight
                        }
                        onHTMLRendered(item.id, clampedHeight)
                    },
                    onSetMessageFlag: { isFlagged in
                        onSetMessageFlag(item, isFlagged)
                    }
                )
                .frame(maxWidth: .infinity)
                .frame(height: htmlHeight)
            } else {
                placeholderBody
            }

            if isRenderingHTML {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onAppear {
            if renderHTMLImmediately {
                renderHTML = true
                return
            }
            renderHTMLTask?.cancel()
            renderHTMLTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                renderHTML = true
            }
        }
        .onDisappear {
            renderHTMLTask?.cancel()
            renderHTMLTask = nil
            isRenderingHTML = false
        }
    }
}

private struct AttachmentDownloadRow: View {
    let state: MailiaAttachmentDownloadState
    let onDownload: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "paperclip")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .padding(.top, 2)

            content
            .layoutPriority(1)

            Spacer(minLength: 8)

            Button {
                onDownload()
            } label: {
                buttonLabel
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(isButtonDisabled)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            Text("Attachment files")
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        case .downloading:
            Text("Attachment files")
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        case .downloaded(let result):
            VStack(alignment: .leading, spacing: 2) {
                if result.fileNames.isEmpty {
                    Text("Files saved")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                } else {
                    ForEach(Array(result.fileNames.prefix(4)), id: \.self) { fileName in
                        Text(fileName)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if result.fileNames.count > 4 {
                        Text("+\(result.fileNames.count - 4) more")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text(result.directoryPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 2) {
                Text("Attachment files")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var buttonLabel: some View {
        switch state {
        case .idle, .failed:
            Label("Download", systemImage: "arrow.down.circle")
                .labelStyle(.titleAndIcon)
        case .downloading:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.small)
                Text("Downloading...")
            }
        case .downloaded:
            Label("Downloaded", systemImage: "checkmark.circle")
                .labelStyle(.titleAndIcon)
        }
    }

    private var isButtonDisabled: Bool {
        switch state {
        case .downloading, .downloaded:
            true
        case .idle, .failed:
            false
        }
    }
}

private struct MailHTMLView: NSViewRepresentable {
    let cacheID: Int64
    let html: String
    let maximumExpandedHeight: CGFloat
    let isFlagged: Bool
    let onLoadingChange: (Bool) -> Void
    let onContentHeightChange: (CGFloat) -> Void
    let onSetMessageFlag: (Bool) -> Void
    @AppStorage(MailiaPreferenceKeys.loadRemoteContent)
    private var loadRemoteContent = false

    init(
        cacheID: Int64,
        html: String,
        maximumExpandedHeight: CGFloat,
        isFlagged: Bool,
        onLoadingChange: @escaping (Bool) -> Void = { _ in },
        onContentHeightChange: @escaping (CGFloat) -> Void = { _ in },
        onSetMessageFlag: @escaping (Bool) -> Void = { _ in }
    ) {
        self.cacheID = cacheID
        self.html = html
        self.maximumExpandedHeight = maximumExpandedHeight
        self.isFlagged = isFlagged
        self.onLoadingChange = onLoadingChange
        self.onContentHeightChange = onContentHeightChange
        self.onSetMessageFlag = onSetMessageFlag
    }

    func makeNSView(context: Context) -> MailHTMLContainerView {
        MailHTMLContainerViewPool.shared.view(for: cacheID)
    }

    func updateNSView(_ containerView: MailHTMLContainerView, context: Context) {
        containerView.onLoadingChange = onLoadingChange
        containerView.onContentHeightChange = onContentHeightChange
        containerView.maximumExpandedHeight = maximumExpandedHeight
        containerView.contextMenu = makeMessageMenu()
        containerView.loadHTML(wrappedHTML)
    }

    static func dismantleNSView(_ nsView: MailHTMLContainerView, coordinator: ()) {
        nsView.onLoadingChange = nil
        nsView.onContentHeightChange = nil
        nsView.maximumExpandedHeight = .greatestFiniteMagnitude
        nsView.contextMenu = nil
    }

    private func makeMessageMenu() -> NSMenu {
        let menu = NSMenu()
        if isFlagged {
            let handler = MessageMenuActionHandler(action: {
                onSetMessageFlag(false)
            })
            let item = NSMenuItem(title: "Unflag", action: #selector(MessageMenuActionHandler.removeFlag), keyEquivalent: "")
            item.target = handler
            item.representedObject = handler
            menu.addItem(item)
        } else {
            let handler = MessageMenuActionHandler(action: {
                onSetMessageFlag(true)
            })
            let item = NSMenuItem(title: "Flag", action: #selector(MessageMenuActionHandler.addFlag), keyEquivalent: "")
            item.target = handler
            item.representedObject = handler
            menu.addItem(item)
        }
        return menu
    }

    private var wrappedHTML: String {
        """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src \(imageSourcePolicy); style-src 'unsafe-inline';">
          <style>
            * { box-sizing: border-box; }
            html, body { width: 100%; min-width: 0; margin: 0; padding: 0; background: transparent; color: -apple-system-label; font: -apple-system-body; overflow-x: hidden; overflow-y: hidden; overflow-wrap: anywhere; -webkit-text-size-adjust: 100%; -webkit-user-select: text; user-select: text; cursor: text; }
            body { width: 100%; max-width: none; }
            #mailia-html-root { display: block; width: 100%; min-width: 0; margin: 0; padding: 0; }
            img, svg, canvas { max-width: 100% !important; height: auto; }
            a { color: -apple-system-link; }
            table { max-width: 100% !important; width: auto !important; table-layout: auto; }
            pre, code { white-space: pre-wrap; overflow-wrap: anywhere; }
          </style>
        </head>
        <body><main id="mailia-html-root">\(html)</main></body>
        </html>
        """
    }

    private var imageSourcePolicy: String {
        loadRemoteContent ? "data: cid: http: https:" : "data: cid:"
    }
}

@MainActor
private final class MailHTMLContainerViewPool {
    static let shared = MailHTMLContainerViewPool()

    private var views: [Int64: MailHTMLContainerView] = [:]
    private var accessOrder: [Int64] = []
    private let maxViewCount = 48

    func view(for cacheID: Int64) -> MailHTMLContainerView {
        if let cached = views[cacheID] {
            cached.removeFromSuperview()
            remember(cacheID)
            return cached
        }

        let view = MailHTMLContainerView()
        views[cacheID] = view
        remember(cacheID)
        trimIfNeeded()
        return view
    }

    private func remember(_ cacheID: Int64) {
        accessOrder.removeAll { $0 == cacheID }
        accessOrder.append(cacheID)
    }

    private func trimIfNeeded() {
        while views.count > maxViewCount, let oldestID = accessOrder.first {
            guard views[oldestID]?.superview == nil else { return }
            views[oldestID] = nil
            accessOrder.removeFirst()
        }
    }
}

private final class MailHTMLContainerView: NSView, WKNavigationDelegate, WKUIDelegate {
    private let webView: MailHTMLWebView
    private var currentHTML = ""
    private var pendingFitWorkItem: DispatchWorkItem?
    private var lastMeasuredWidth: CGFloat = 0
    private var lastContentWidth: CGFloat = 0
    private var lastContentHeight: CGFloat = 0
    private var lastPageZoom: CGFloat = 1
    private var isLoading = false
    var maximumExpandedHeight: CGFloat = .greatestFiniteMagnitude {
        didSet {
            if abs(maximumExpandedHeight - oldValue) > 1 {
                publishDisplayHeightForCurrentContent()
                updateScrollersForCurrentBounds()
            }
        }
    }
    var onLoadingChange: ((Bool) -> Void)?
    var onContentHeightChange: ((CGFloat) -> Void)?
    var contextMenu: NSMenu? {
        didSet {
            webView.contextMenuProvider = { [weak self] in
                self?.makeContextMenu()
            }
        }
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        self.webView = MailHTMLWebView(frame: .zero, configuration: configuration)
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.masksToBounds = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        webView.wantsLayer = true
        webView.layer?.masksToBounds = true

        addSubview(webView)
        setScrollers(horizontal: false, vertical: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let previousSize = webView.frame.size
        webView.frame = bounds
        if abs(previousSize.width - bounds.width) > 1 {
            scheduleFit(force: true)
        } else if abs(previousSize.height - bounds.height) > 1 {
            scheduleFit(force: true)
        }
    }

    func loadHTML(_ html: String) {
        guard html != currentHTML else { return }

        currentHTML = html
        lastMeasuredWidth = 0
        lastContentWidth = 0
        lastContentHeight = 0
        lastPageZoom = 1
        webView.pageZoom = 1
        setScrollers(horizontal: false, vertical: false)
        setLoading(true)
        webView.loadHTMLString(html, baseURL: nil)
    }

    func refreshLayoutForCurrentBounds() {
        if lastContentHeight > 0 {
            publishDisplayHeightForCurrentContent()
            updateScrollersForCurrentBounds()
        }
        scheduleFit(force: true)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        setLoading(false)
        scheduleFit(force: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.scheduleFit(force: true)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        setLoading(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        setLoading(false)
    }

    @MainActor
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

        if ["http", "https"].contains(url.scheme?.lowercased()) {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    private func scheduleFit(force: Bool = false, delay: TimeInterval = 0.05) {
        let measuredWidth = bounds.width
        guard measuredWidth > 1, !currentHTML.isEmpty else { return }
        if !force, abs(lastMeasuredWidth - measuredWidth) <= 1, lastContentHeight > 0 {
            updateScrollersForCurrentBounds()
            return
        }

        pendingFitWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.measureContentForVisibleBounds()
        }
        pendingFitWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func measureContentForVisibleBounds() {
        guard bounds.width > 1, bounds.height > 1, !currentHTML.isEmpty else { return }

        let script = """
        (() => {
          const root = document.getElementById('mailia-html-root') || document.body;
          if (!root) return { width: 1, height: 1 };
          const elements = [root, ...Array.from(root.querySelectorAll('*'))];
          let width = 0;
          let top = Number.POSITIVE_INFINITY;
          let bottom = 0;
          const rootRect = root.getBoundingClientRect();
          for (const element of elements) {
            const style = window.getComputedStyle(element);
            if (style.display === 'none' || style.visibility === 'hidden') continue;
            const rect = element.getBoundingClientRect();
            if (rect.width <= 0 || rect.height <= 0) continue;
            width = Math.max(width, rect.right - rootRect.left);
            top = Math.min(top, rect.top);
            bottom = Math.max(bottom, rect.bottom);
          }
          if (!Number.isFinite(top)) top = rootRect.top;
          const height = Math.max(
            bottom - top,
            root.scrollHeight,
            root.offsetHeight,
            rootRect.height,
            1
          );
          width = Math.max(
            width,
            root.scrollWidth,
            root.offsetWidth,
            1
          );
          return { width, height };
        })();
        """

        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self,
                  let dimensions = result as? [String: Any],
                  let contentWidth = Self.cgFloatValue(dimensions["width"]),
                  let contentHeight = Self.cgFloatValue(dimensions["height"]),
                  contentWidth > 1,
                  contentHeight > 1
            else {
                return
            }

            let availableWidth = max(self.bounds.width - 2, 1)
            let zoom = self.fitZoom(contentWidth: contentWidth, availableWidth: availableWidth)
            let renderedWidth = ceil(contentWidth * zoom)
            let renderedHeight = ceil(contentHeight * zoom)

            if abs(self.lastPageZoom - zoom) > 0.01 {
                self.lastPageZoom = zoom
                self.webView.pageZoom = zoom
            }

            self.lastMeasuredWidth = self.bounds.width
            self.lastContentWidth = renderedWidth
            self.lastContentHeight = renderedHeight
            self.publishDisplayHeightForCurrentContent()
            self.updateScrollersForCurrentBounds(availableWidth: availableWidth)
        }
    }

    private func publishDisplayHeightForCurrentContent() {
        guard lastContentHeight > 0 else { return }
        onContentHeightChange?(lastContentHeight)
    }

    private func updateScrollersForCurrentBounds(availableWidth: CGFloat? = nil) {
        guard lastContentWidth > 0, lastContentHeight > 0 else { return }
        let width = availableWidth ?? max(bounds.width - 2, 1)
        let needsVerticalScroller = lastContentHeight > maximumExpandedHeight + 1
        setScrollers(
            horizontal: lastContentWidth > width + 1,
            vertical: needsVerticalScroller
        )
    }

    private func fitZoom(contentWidth: CGFloat, availableWidth: CGFloat) -> CGFloat {
        guard contentWidth > availableWidth + 1 else { return 1 }
        return max(0.72, min(1, availableWidth / contentWidth))
    }

    private func setScrollers(horizontal: Bool, vertical: Bool) {
        webView.allowsHorizontalWheelScrolling = horizontal
        webView.allowsVerticalWheelScrolling = vertical
        setDOMVerticalScrollingEnabled(vertical)

        guard let scrollView = firstScrollView(in: webView) else { return }
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = horizontal
        scrollView.hasVerticalScroller = vertical
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.scrollerStyle = .overlay
    }

    private func setDOMVerticalScrollingEnabled(_ isEnabled: Bool) {
        guard !currentHTML.isEmpty else { return }
        let overflow = isEnabled ? "auto" : "hidden"
        let resetScroll = isEnabled ? "" : "scroller.scrollTop = 0;"
        let script = """
        (() => {
          const scroller = document.scrollingElement || document.documentElement || document.body;
          if (!scroller) return;
          document.documentElement.style.overflowY = '\(overflow)';
          document.documentElement.style.height = 'auto';
          if (document.body) document.body.style.overflowY = '\(overflow)';
          if (document.body) document.body.style.height = 'auto';
          \(resetScroll)
        })();
        """
        webView.evaluateJavaScript(script)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: "Copy", action: #selector(MailHTMLWebView.copy(_:)), keyEquivalent: "")
        copyItem.target = webView
        menu.addItem(copyItem)

        if let contextMenu, !contextMenu.items.isEmpty {
            menu.addItem(.separator())
            for item in contextMenu.items {
                if let copy = item.copy() as? NSMenuItem {
                    menu.addItem(copy)
                }
            }
        }

        return menu
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

    private func setLoading(_ loading: Bool) {
        guard isLoading != loading else { return }
        isLoading = loading
        onLoadingChange?(loading)
    }

    private static func cgFloatValue(_ value: Any?) -> CGFloat? {
        if let number = value as? NSNumber {
            return CGFloat(truncating: number)
        }
        if let double = value as? Double {
            return CGFloat(double)
        }
        return nil
    }

}

private final class MailHTMLWebView: WKWebView {
    var allowsHorizontalWheelScrolling = false
    var allowsVerticalWheelScrolling = false
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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            copySelectedTextToPasteboard()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func copy(_ sender: Any?) {
        copySelectedTextToPasteboard()
    }

    override func scrollWheel(with event: NSEvent) {
        let isMostlyVertical = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
        let hasScrollDelta = !event.scrollingDeltaY.isZero || !event.scrollingDeltaX.isZero
        let canHandleEvent = isMostlyVertical
            ? allowsVerticalWheelScrolling
            : allowsHorizontalWheelScrolling
        guard hasScrollDelta, canHandleEvent else {
            nextResponder?.scrollWheel(with: event)
            return
        }

        if isMostlyVertical,
           let scrollView = firstScrollView(in: self),
           !canScroll(scrollView, withVerticalDelta: event.scrollingDeltaY) {
            nextResponder?.scrollWheel(with: event)
            return
        }

        super.scrollWheel(with: event)
    }

    private func copySelectedTextToPasteboard() {
        let script = """
        (() => {
          const selection = window.getSelection();
          return selection ? selection.toString() : "";
        })();
        """

        evaluateJavaScript(script) { result, _ in
            guard let selectedText = result as? String,
                  !selectedText.isEmpty else {
                return
            }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(selectedText, forType: .string)
        }
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

private final class MessageMenuActionHandler: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func addFlag() {
        action()
    }

    @objc func removeFlag() {
        action()
    }
}

private struct BadgeLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.secondary.opacity(0.11))
            )
    }
}

private struct SettingsView: View {
    @AppStorage(MailiaPreferenceKeys.timelineBodyDisplayMode)
    private var bodyDisplayMode = TimelineBodyDisplayMode.html.rawValue
    @AppStorage(MailiaPreferenceKeys.loadRemoteContent)
    private var loadRemoteContent = false

    var body: some View {
        Form {
            Section("Accounts") {
                LabeledContent("Connected accounts", value: "Repository wiring pending")
                LabeledContent("Authentication", value: "Not configured")
                Button("Add Account...") {}
                    .disabled(true)
            }

            Section("Sync") {
                LabeledContent("Schedule", value: "Manual refresh")
                LabeledContent("Window", value: "Core policy pending")
                Toggle("Sync automatically", isOn: .constant(false))
                    .disabled(true)
            }

            Section("Downloads") {
                LabeledContent("Attachments", value: "Ask before downloading")
                LabeledContent("Message bodies", value: "On demand")
                Button("Choose Download Folder...") {}
                    .disabled(true)
            }

            Section("Reading") {
                Picker("Message body rendering", selection: $bodyDisplayMode) {
                    ForEach(TimelineBodyDisplayMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Privacy") {
                Toggle("Load remote content", isOn: $loadRemoteContent)
                Toggle("Index message body text", isOn: .constant(false))
                    .disabled(true)
            }

            Section("Diagnostics") {
                LabeledContent("Core version", value: MailiaCore.version)
                LabeledContent("Activity log", value: "Not connected")
                Button("Export Diagnostics...") {}
                    .disabled(true)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 560, height: 560)
    }
}

private extension EntityKind {
    var displayName: String {
        switch self {
        case .person:
            "Person"
        case .organization:
            "Organization"
        case .service:
            "Service"
        case .newsletter:
            "Newsletter"
        case .unknown:
            "Unknown"
        }
    }
}
