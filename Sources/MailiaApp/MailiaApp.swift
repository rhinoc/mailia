import MailiaCore
import AppKit
import SwiftUI
import WebKit

enum MailiaPreferenceKeys {
    static let timelineBodyDisplayMode = "MailiaTimelineBodyDisplayMode"
    static let loadRemoteContent = "MailiaLoadRemoteContent"
    static let showTimelineAvatars = "MailiaShowTimelineAvatars"
}

private enum MailiaTopChrome {
    static let controlTopPadding: CGFloat = 8
}

private enum MailiaSettingsChrome {
    static let backgroundNSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(calibratedWhite: isDark ? 0.12 : 0.94, alpha: 1)
    }

    static let fieldBackgroundNSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(calibratedWhite: isDark ? 0.18 : 1, alpha: 1)
    }

    static let fieldBorderNSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(calibratedWhite: 1, alpha: 0.14)
    }

    static let searchFieldBackgroundNSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(calibratedWhite: isDark ? 0.18 : 0.88, alpha: 1)
    }

    static var backgroundColor: Color {
        Color(nsColor: backgroundNSColor)
    }

    static var fieldBackgroundColor: Color {
        Color(nsColor: fieldBackgroundNSColor)
    }

    static var fieldBorderColor: Color {
        Color(nsColor: fieldBorderNSColor)
    }

    static var searchFieldBackgroundColor: Color {
        Color(nsColor: searchFieldBackgroundNSColor)
    }

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
        configureApplicationIcon()
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
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Mailia Settings"
        window.center()
        window.isOpaque = true
        window.backgroundColor = MailiaSettingsChrome.backgroundNSColor
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        let hostingView = NSHostingView(rootView: SettingsView(viewModel: viewModel))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = MailiaSettingsChrome.backgroundNSColor.cgColor
        window.contentView = hostingView
        window.contentView?.superview?.wantsLayer = true
        window.contentView?.superview?.layer?.backgroundColor = MailiaSettingsChrome.backgroundNSColor.cgColor
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureApplicationIcon() {
        guard let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
              let iconImage = NSImage(contentsOf: iconURL) else {
            return
        }
        NSApp.applicationIconImage = iconImage
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
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
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
        let cutItem = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        cutItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(cutItem)
        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(copyItem)
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        pasteItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(pasteItem)
        editMenu.addItem(.separator())
        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        selectAllItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(selectAllItem)
        editMenu.addItem(.separator())
        let emojiItem = NSMenuItem(
            title: "Emoji & Symbols",
            action: #selector(NSApplication.orderFrontCharacterPalette(_:)),
            keyEquivalent: " "
        )
        emojiItem.keyEquivalentModifierMask = [.control, .command]
        editMenu.addItem(emojiItem)

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
    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        _columnVisibility = State(initialValue: Self.preferredSidebarVisibility())
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibilityBinding) {
            EntityListPane(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 430)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        RefreshButton(viewModel: viewModel) {
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
                replySendState: viewModel.replySendState,
                isComposingNewMessage: viewModel.isComposingNewMessage,
                isLoadingEntityList: viewModel.isLoadingEntityList,
                hasSelectableEntities: !viewModel.entities.isEmpty,
                sendAccounts: viewModel.sendAccounts,
                selectedSendAccountKey: viewModel.selectedSendAccountKey,
                composeSuggestions: viewModel.recipientSuggestions,
                scrollAnchor: viewModel.timelineScrollAnchor,
                onRequestBody: { item, priority in
                    viewModel.loadBodyIfNeeded(for: item, priority: priority)
                },
                onRequestOlder: viewModel.loadOlderTimelineIfNeeded,
                onRequestNewer: viewModel.loadNewerTimelineIfNeeded,
                onSetMessageFlag: viewModel.setMessageFlag,
                onDownloadAttachments: viewModel.downloadAttachments,
                onSendReply: viewModel.sendReply,
                onSendNewMessage: viewModel.sendNewMessage,
                onSelectSendAccount: viewModel.selectSendAccount,
                onComposerEdited: viewModel.clearReplySendFailure,
                onEntityAction: viewModel.performEntityAction
            )
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.clear)
        .background(WindowWidthReader())
        .background(WindowTitleUpdater())
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onPreferenceChange(WindowWidthPreferenceKey.self) { width in
            updateSidebarVisibility(for: width)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if !viewModel.isComposingNewMessage {
                    Button {
                        viewModel.startComposingNewMessage()
                    } label: {
                        Label("New Message", systemImage: "square.and.pencil")
                    }
                    .help("New Message")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                if viewModel.isComposingNewMessage {
                    Button {
                        viewModel.cancelComposingNewMessage()
                    } label: {
                        Text("Cancel")
                    }
                    .help("Discard new message")
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

private struct ComposerHeightPreferenceKey: PreferenceKey {
    static let defaultValue: ComposerHeightPreference? = nil

    static func reduce(value: inout ComposerHeightPreference?, nextValue: () -> ComposerHeightPreference?) {
        value = nextValue() ?? value
    }
}

private struct ComposerHeightPreference: Equatable {
    let contextID: String
    let height: CGFloat
}

private struct WindowWidthReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: WindowWidthPreferenceKey.self, value: proxy.size.width)
        }
    }
}

private struct WindowTitleUpdater: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.title = ""
            nsView.window?.titleVisibility = .hidden
            nsView.window?.titlebarAppearsTransparent = true
            nsView.window?.titlebarSeparatorStyle = .none
            nsView.window?.isMovableByWindowBackground = true
        }
    }
}

private struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragRegionView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragRegionView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}

private enum SidebarListSelection: Hashable {
    case composeDraft
    case entity(Int64)
}

private struct EntityListPane: View {
    private static let searchOverlayTopPadding: CGFloat = MailiaTopChrome.controlTopPadding
    private static let searchOverlayBottomPadding: CGFloat = 6
    private static let searchOverlayHeight = searchOverlayTopPadding + SidebarSearchField.preferredHeight + searchOverlayBottomPadding
    private static let searchGlassHeight = searchOverlayTopPadding + SidebarSearchField.preferredHeight
    private static let topScrollAnchorID = "sidebar-top-anchor"

    @ObservedObject var viewModel: AppViewModel
    @State private var showsTopFade = false
    @State private var showsBottomFade = false

    private var sidebarSelection: Binding<SidebarListSelection?> {
        Binding(
            get: {
                if viewModel.isComposingNewMessage {
                    return .composeDraft
                }
                if let selectedEntityID = viewModel.selectedEntityID {
                    return .entity(selectedEntityID)
                }
                return nil
            },
            set: { newSelection in
                switch newSelection {
                case .composeDraft:
                    viewModel.startComposingNewMessage()
                case .entity(let entityID):
                    viewModel.selectedEntityID = entityID
                case nil:
                    break
                }
            }
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                List(selection: sidebarSelection) {
                    Color.clear
                        .frame(height: Self.searchOverlayHeight)
                        .id(Self.topScrollAnchorID)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())

                    if viewModel.hasComposeDraft {
                        ComposeDraftRow(onDelete: deleteComposeDraft)
                            .tag(SidebarListSelection.composeDraft)
                            .id(SidebarListSelection.composeDraft)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                    }

                    if viewModel.entities.isEmpty, viewModel.isLoadingEntityList {
                        SidebarTransitionPlaceholderRow()
                            .listRowSeparator(.hidden)
                    } else if viewModel.entities.isEmpty {
                        EmptyEntityRow(searchQuery: viewModel.searchQuery)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(viewModel.entities) { entity in
                            EntityRow(
                                entity: entity,
                                isSelected: viewModel.selectedEntityID == entity.id,
                                onAppear: {
                                    viewModel.resolveAvatarForVisibleEntity(entity.id)
                                }
                            )
                                .tag(SidebarListSelection.entity(entity.id))
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
                .onChange(of: viewModel.workspace) { _, _ in
                    resetScrollPosition(proxy)
                }
                .listStyle(.sidebar)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear
                        .frame(height: WorkspaceTabBar.floatingReserveHeight)
                        .accessibilityHidden(true)
                }
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
                    sidebarSearchOverlay
                }
                // .overlay(alignment: .bottom) {
                //     LiquidGlassFade(edge: .bottom, height: 72, opacity: showsBottomFade ? 1 : 0)
                // }
                .onChange(of: viewModel.isComposingNewMessage) { _, isComposing in
                    guard isComposing else { return }
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(Self.topScrollAnchorID, anchor: .top)
                        }
                    }
                }
            }

            WorkspaceTabBar(selection: $viewModel.workspace)
                .padding(.horizontal, 12)
                .padding(.bottom, WorkspaceTabBar.outerBottomPadding)
                .padding(.top, WorkspaceTabBar.outerTopPadding)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .trailing) {
            Color(nsColor: .textBackgroundColor)
                .frame(width: 1)
                .ignoresSafeArea(.container, edges: .vertical)
                .allowsHitTesting(false)
        }
    }

    private var sidebarSearchOverlay: some View {
        ZStack(alignment: .top) {
            // LiquidGlassFade(edge: .top, height: Self.searchGlassHeight, opacity: showsTopFade ? 1 : 0)
            WindowDragRegion()
                .frame(height: Self.searchOverlayTopPadding)
                .frame(maxWidth: .infinity, alignment: .top)

            HStack(spacing: 8) {
                SidebarSearchField(text: $viewModel.searchQuery, placeholder: "Search")
            }
            .padding(.horizontal, 12)
            .padding(.top, Self.searchOverlayTopPadding)
            .padding(.bottom, Self.searchOverlayBottomPadding)
        }
        .frame(height: Self.searchOverlayHeight, alignment: .top)
    }

    private func deleteComposeDraft() {
        viewModel.cancelComposingNewMessage()
    }

    private func resetScrollPosition(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(Self.topScrollAnchorID, anchor: .top)
        }
    }
}

private struct WorkspaceTabBar: View {
    @Binding var selection: MailiaWorkspace
    @Namespace private var selectionNamespace
    static let itemSize: CGFloat = 36
    static let capsulePadding: CGFloat = 8
    static let itemSpacing: CGFloat = 10
    static let outerTopPadding: CGFloat = 8
    static let outerBottomPadding: CGFloat = 10
    private static var trackWidth: CGFloat {
        let itemCount = CGFloat(MailiaWorkspace.allCases.count)
        return itemSize * itemCount + itemSpacing * max(0, itemCount - 1)
    }
    private static var barHeight: CGFloat {
        itemSize + capsulePadding * 2
    }
    private static var barWidth: CGFloat {
        trackWidth + capsulePadding * 2
    }

    static var floatingReserveHeight: CGFloat {
        outerTopPadding + barHeight + outerBottomPadding
    }

    var body: some View {
        glassBar
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Mailbox")
    }

    @ViewBuilder
    private var glassBar: some View {
        ZStack(alignment: .leading) {
            GlassEffectContainer(spacing: Self.itemSize + Self.itemSpacing) {
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(.clear)
                        .frame(width: Self.barWidth, height: Self.barHeight)
                        .background {
                            OuterGlassShadow(shape: AnyShape(Capsule(style: .continuous)))
                        }
                        .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
                }
            }

            WorkspaceTabSelectionBlob(
                selection: selection,
                namespace: selectionNamespace
            )
            .padding(Self.capsulePadding)

            tabButtons
                .padding(Self.capsulePadding)
        }
        .frame(width: Self.barWidth, height: Self.barHeight)
    }

    private var tabButtons: some View {
        HStack(spacing: Self.itemSpacing) {
            ForEach(MailiaWorkspace.allCases) { workspace in
                WorkspaceTabButton(
                    workspace: workspace,
                    isSelected: workspace == selection
                ) {
                    select(workspace)
                }
            }
        }
    }

    private func select(_ workspace: MailiaWorkspace) {
        guard workspace != selection else { return }
        selection = workspace
    }
}

private struct WorkspaceTabButton: View {
    let workspace: MailiaWorkspace
    let isSelected: Bool
    let action: () -> Void
    private var itemSize: CGFloat { WorkspaceTabBar.itemSize }

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: workspace.tabSystemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .symbolVariant(isSelected ? .fill : .none)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .frame(width: itemSize, height: itemSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(workspace.tabLabel)
        .accessibilityLabel(workspace.tabLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct WorkspaceTabSelectionBlob: View {
    let selection: MailiaWorkspace
    let namespace: Namespace.ID
    private var itemSize: CGFloat { WorkspaceTabBar.itemSize }
    private var itemSpacing: CGFloat { WorkspaceTabBar.itemSpacing }
    private var trackWidth: CGFloat {
        let itemCount = CGFloat(MailiaWorkspace.allCases.count)
        return itemSize * itemCount + itemSpacing * max(0, itemCount - 1)
    }

    var body: some View {
        HStack(spacing: itemSpacing) {
            ForEach(MailiaWorkspace.allCases) { workspace in
                ZStack {
                    if workspace == selection {
                        selectionBlob
                            .matchedGeometryEffect(id: "workspace-tab-selection", in: namespace)
                            .transition(.identity)
                    }
                }
                .frame(width: itemSize, height: itemSize)
            }
        }
        .frame(width: trackWidth, height: itemSize, alignment: .leading)
        .allowsHitTesting(false)
        .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.76), value: selection)
    }

    private var selectionBlob: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(Color.accentColor.opacity(0.2))

            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.24), lineWidth: 0.7)

            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.22),
                            Color.white.opacity(0.06),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .frame(width: itemSize, height: itemSize)
    }
}

private extension MailiaWorkspace {
    var tabLabel: String {
        switch self {
        case .main:
            "Inbox"
        case .junk:
            "Junk"
        case .flagged:
            "Flagged"
        }
    }

    var tabSystemImage: String {
        switch self {
        case .main:
            "tray"
        case .junk:
            "nosign"
        case .flagged:
            "flag"
        }
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

private struct LiquidGlassFade: View {
    enum Edge {
        case top
        case bottom
    }

    let edge: Edge
    let height: CGFloat
    let opacity: Double

    var body: some View {
        glassLayer
            .frame(height: height)
            .mask {
                LinearGradient(
                    stops: gradientStops,
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .opacity(opacity)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.16), value: opacity)
    }

    @ViewBuilder
    private var glassLayer: some View {
        Rectangle()
            .fill(.clear)
            .glassEffect(.regular, in: Rectangle())
            .overlay {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.16),
                        Color.white.opacity(0.04),
                        Color.clear
                    ],
                    startPoint: edge == .top ? .top : .bottom,
                    endPoint: edge == .top ? .bottom : .top
                )
                .blendMode(.plusLighter)
            }
    }

    private var gradientStops: [Gradient.Stop] {
        switch edge {
        case .top:
            [
                .init(color: .white, location: 0),
                .init(color: .white.opacity(0.82), location: 0.36),
                .init(color: .white.opacity(0.32), location: 0.76),
                .init(color: .clear, location: 1)
            ]
        case .bottom:
            [
                .init(color: .clear, location: 0),
                .init(color: .white.opacity(0.32), location: 0.24),
                .init(color: .white.opacity(0.82), location: 0.64),
                .init(color: .white, location: 1)
            ]
        }
    }
}

private struct RotatingRefreshSymbol: View {
    let isActive: Bool
    let period: TimeInterval
    @State private var rotation = 0.0

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath.circle")
            .font(.system(size: 15, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .frame(width: 18, height: 18, alignment: .center)
            .rotationEffect(.degrees(rotation), anchor: .center)
            .onAppear {
                updateRotation(isActive)
            }
            .onChange(of: isActive) { _, active in
                updateRotation(active)
            }
    }

    private func updateRotation(_ active: Bool) {
        if active {
            rotation = 0
            withAnimation(.linear(duration: period).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        } else {
            withAnimation(.easeOut(duration: 0.12)) {
                rotation = 0
            }
        }
    }
}

private struct TimelineEdgeFade: View {
    enum Edge {
        case top
        case bottom
    }

    let edge: Edge
    let height: CGFloat

    var body: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .textBackgroundColor).opacity(0.98),
                Color(nsColor: .textBackgroundColor).opacity(0.68),
                Color(nsColor: .textBackgroundColor).opacity(0.0)
            ],
            startPoint: edge == .top ? .top : .bottom,
            endPoint: edge == .top ? .bottom : .top
        )
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .allowsHitTesting(false)
    }
}

private struct RefreshButton: View {
    @ObservedObject var viewModel: AppViewModel
    let action: () -> Void
    @State private var isHovering = false

    private var isShowingStatusPopover: Binding<Bool> {
        Binding(
            get: { isHovering },
            set: { presented in
                if !presented {
                    isHovering = false
                }
            }
        )
    }

    var body: some View {
        Button {
            guard !viewModel.isRefreshing else { return }
            action()
        } label: {
            RotatingRefreshSymbol(
                isActive: viewModel.isRefreshing,
                period: 1.1
            )
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .popover(isPresented: isShowingStatusPopover, arrowEdge: .top) {
            RefreshStatusPopover(viewModel: viewModel)
        }
        .help("Refresh\n\(viewModel.refreshStatus)")
    }
}

private struct RefreshStatusPopover: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let activity = viewModel.refreshActivity {
                RefreshProgressSection(activity: activity)
            } else {
                RefreshStatusSection(status: viewModel.refreshStatus)
            }

            if let avatarActivity = viewModel.avatarResolutionActivity {
                Divider()
                RefreshProgressSection(activity: avatarActivity)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(width: 286, alignment: .leading)
    }
}

private struct RefreshStatusSection: View {
    let status: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Mail status")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)

            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RefreshProgressSection: View {
    let activity: MailiaRefreshProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text(activity.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            if let fraction = activity.fraction {
                ProgressView(value: min(max(fraction, 0), 1))
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            if let detail = activity.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SidebarSearchField: View {
    static let preferredHeight: CGFloat = 36
    private static let fieldShape = Capsule(style: .continuous)
    private static let fieldBackground = MailiaSettingsChrome.searchFieldBackgroundColor
    private static let focusRing = Color(nsColor: .systemBlue).opacity(0.34)
    private static let controlGlyphColor = Color(nsColor: .labelColor).opacity(0.58)

    @Binding var text: String
    var placeholder: String
    @FocusState private var isFocused: Bool

    private var showsClearButton: Bool {
        isFocused || !text.isEmpty
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Self.controlGlyphColor)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .labelsHidden()
                .focused($isFocused)

            Button {
                text = ""
                isFocused = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Self.controlGlyphColor)
            }
            .buttonStyle(.plain)
            .opacity(showsClearButton ? 1 : 0)
            .disabled(!showsClearButton)
            .accessibilityLabel("Clear search")
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: Self.preferredHeight)
        .background { fieldChrome }
        .overlay {
            if isFocused {
                Self.fieldShape
                    .stroke(Self.focusRing, lineWidth: 3)
                    .shadow(color: Self.focusRing.opacity(0.7), radius: 2, y: 0)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }

    @ViewBuilder
    private var fieldChrome: some View {
        Self.fieldShape
            .fill(Self.fieldBackground)
            .clipShape(Self.fieldShape)
    }
}

private struct EntityRow: View {
    let entity: MailiaEntitySummary
    let isSelected: Bool
    let onAppear: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            EntityAvatar(entity: entity, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entity.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(2)

                    Spacer(minLength: 6)

                    if let latestDate = entity.latestDate {
                        RelativeTimeText(date: latestDate, font: .system(size: 12))
                    }
                }

                HStack(alignment: .top, spacing: 8) {
                    Text(previewText)
                        .font(.system(size: 13))
                        .foregroundStyle(entity.unreadCount > 0 ? .primary : .secondary)
                        .lineLimit(2)
                        .layoutPriority(1)

                    Spacer(minLength: 6)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .frame(minHeight: 48)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(alignment: .leading) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
                .offset(x: -8)
                .opacity(entity.unreadCount > 0 && !isSelected ? 1 : 0)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .onAppear(perform: onAppear)
    }

    private var previewText: String {
        if !entity.latestSubject.isEmpty {
            return entity.latestSubject
        }

        return entity.primaryEmailAddress ?? entity.kind.rawValue
    }
}

private struct ComposeDraftRow: View {
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ComposeDraftAvatar(size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text("New Message")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("Draft")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if isHovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color(nsColor: .separatorColor).opacity(0.4)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Discard new message")
                .accessibilityLabel("Discard new message")
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .frame(minHeight: 48)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

private struct ComposeDraftAvatar: View {
    var size: CGFloat = 36

    @State private var avatarImage: NSImage?

    var body: some View {
        Group {
            if let avatarImage {
                Image(nsImage: avatarImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color(red: 0, green: 95 / 255, blue: 249 / 255))
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
        .task {
            guard avatarImage == nil else { return }
            let resolver = EntityBrandAvatarResolver()
            guard let dataURL = await resolver.composeDraftAvatarDataURL(),
                  let image = NSImage.mailiaImage(dataURL: dataURL)
            else {
                return
            }
            avatarImage = image
        }
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
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
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
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 52, height: 52)

                Image(systemName: isSearching ? "magnifyingglass" : "tray")
                    .font(.system(size: 22, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 4) {
                Text(isSearching ? "No matches" : "No conversations")
                    .font(.headline)

                Text(isSearching ? "Try a broader search." : "Refresh or connect an account.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
        .padding(.horizontal, 18)
        .padding(.vertical, 28)
    }

    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct SidebarTransitionPlaceholderRow: View {
    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .accessibilityHidden(true)
    }
}

private struct TimelinePane: View {
    private static let topDragRegionHeight: CGFloat = MailiaTopChrome.controlTopPadding

    let entity: MailiaEntitySummary?
    let items: [MailiaTimelineItem]
    let isLoadingTimeline: Bool
    let isLoadingOlderTimeline: Bool
    let isLoadingNewerTimeline: Bool
    let hasOlderTimeline: Bool
    let hasNewerTimeline: Bool
    let bodyStates: [Int64: MailiaTimelineBodyState]
    let attachmentDownloadStates: [Int64: MailiaAttachmentDownloadState]
    let replySendState: MailiaReplySendState
    let isComposingNewMessage: Bool
    let isLoadingEntityList: Bool
    let hasSelectableEntities: Bool
    let sendAccounts: [MailiaSendAccount]
    let selectedSendAccountKey: String?
    let composeSuggestions: [MailiaRecipientSuggestion]
    let scrollAnchor: MailiaTimelineScrollAnchor?
    let onRequestBody: (MailiaTimelineItem, Int?) -> Void
    let onRequestOlder: () -> Void
    let onRequestNewer: () -> Void
    let onSetMessageFlag: (MailiaTimelineItem, Bool) -> Void
    let onDownloadAttachments: (MailiaTimelineItem) -> Void
    let onSendReply: (MailiaTimelineItem, String, Bool, String?) -> Void
    let onSendNewMessage: ([String], String?, String, String?) -> Void
    let onSelectSendAccount: (String) -> Void
    let onComposerEdited: () -> Void
    let onEntityAction: (MailiaEntityAction, MailiaEntitySummary) -> Void

    var body: some View {
        Group {
            if isComposingNewMessage {
                NewMessageComposerView(
                    sendAccounts: sendAccounts,
                    selectedSendAccountKey: selectedSendAccountKey,
                    suggestions: composeSuggestions,
                    sendState: replySendState,
                    onSend: onSendNewMessage,
                    onSelectSendAccount: onSelectSendAccount,
                    onEdited: onComposerEdited
                )
                .padding(.top, Self.topDragRegionHeight)
                .background(Color(nsColor: .textBackgroundColor))
            } else if let entity {
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
                    replySendState: replySendState,
                    sendAccounts: sendAccounts,
                    selectedSendAccountKey: selectedSendAccountKey,
                    scrollAnchor: scrollAnchor,
                    onRequestBody: onRequestBody,
                    onRequestOlder: onRequestOlder,
                    onRequestNewer: onRequestNewer,
                    onSetMessageFlag: onSetMessageFlag,
                    onDownloadAttachments: onDownloadAttachments,
                    onSendReply: onSendReply,
                    onSelectSendAccount: onSelectSendAccount,
                    onComposerEdited: onComposerEdited,
                    onEntityAction: onEntityAction
                )
            } else if isLoadingEntityList {
                TimelineTransitionPlaceholderView()
            } else {
                EmptyTimelineSelectionView(hasSelectableEntities: hasSelectableEntities)
            }
        }
    }
}

private struct TimelineTransitionPlaceholderView: View {
    var body: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .textBackgroundColor)
            WindowDragRegion()
                .frame(height: MailiaTopChrome.controlTopPadding)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .ignoresSafeArea(.container, edges: .top)
        .accessibilityHidden(true)
    }
}

private struct EmptyTimelineSelectionView: View {
    let hasSelectableEntities: Bool

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 72, height: 72)

                Image(systemName: hasSelectableEntities ? "bubble.left.and.bubble.right" : "tray")
                    .font(.system(size: 30, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 5) {
                Text(hasSelectableEntities ? "No conversation selected" : "No conversations")
                    .font(.title3.weight(.semibold))

                Text(hasSelectableEntities ? "Choose a sender from the sidebar." : "Refresh or adjust the current view.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(32)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct TimelineEntityHeader: View {
    let entity: MailiaEntitySummary
    let onShowDetails: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Button(action: onShowDetails) {
                HStack(spacing: 5) {
                    Text(entity.displayName)
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .frame(height: 24)
                .background {
                    Capsule(style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.92))
                        .shadow(color: Color.black.opacity(0.07), radius: 9, y: 3)
                }
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(NoPressEffectButtonStyle())
            .help("Show conversation details")
            .accessibilityLabel("Show details for \(entity.displayName)")
            .padding(.top, 34)

            EntityAvatar(entity: entity, size: 40)
                .background {
                    Circle()
                        .fill(Color.black.opacity(0.24))
                        .frame(width: 38, height: 38)
                        .blur(radius: 8)
                        .offset(y: 7)
                }
                .shadow(color: Color.black.opacity(0.12), radius: 4, y: 1)
                .zIndex(1)
        }
        .frame(maxWidth: 260)
        .frame(height: 58)
        .padding(.horizontal, 18)
    }
}

private struct EntityDetailDrawer: View {
    private static let width: CGFloat = 340

    let entity: MailiaEntitySummary
    let workspace: MailiaWorkspace
    let onClose: () -> Void
    let onAction: (MailiaEntityAction, MailiaEntitySummary) -> Void
    @State private var copiedEmailAddress: String?

    private var emailAddresses: [String] {
        entityEmailAddresses(for: entity)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    drawerIdentity
                    emailSection
                }
                .padding(.horizontal, 24)
                .padding(.top, MailiaTopChrome.controlTopPadding + 22)
                .padding(.bottom, 22)
            }

            drawerActions
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .leading) {
            Color(nsColor: .separatorColor)
                .frame(width: 1)
                .ignoresSafeArea(.container, edges: .vertical)
        }
        .shadow(color: Color.black.opacity(0.10), radius: 24, x: -8, y: 0)
        .ignoresSafeArea(.container, edges: .vertical)
    }

    private var drawerIdentity: some View {
        VStack(spacing: 8) {
            EntityAvatar(entity: entity, size: 54)
                .shadow(color: Color.black.opacity(0.10), radius: 12, y: 5)

            Text(entity.displayName)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var emailSection: some View {
        if emailAddresses.isEmpty {
            Text("No email addresses")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 15)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                }
        } else {
            VStack(spacing: 8) {
                ForEach(emailAddresses, id: \.self) { emailAddress in
                    Button {
                        copyEmailAddress(emailAddress)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("email")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)

                                Text(emailAddress)
                                    .font(.system(size: 14, weight: .regular))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer(minLength: 10)

                            Image(systemName: copiedEmailAddress == emailAddress ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(copiedEmailAddress == emailAddress ? Color.green : Color.secondary)
                                .frame(width: 28, height: 28)
                                .background {
                                    Circle()
                                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.9))
                                }
                                .animation(.easeOut(duration: 0.16), value: copiedEmailAddress)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 13)
                        .background {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Copy \(emailAddress)")
                    .accessibilityLabel("Copy \(emailAddress)")
                }
            }
        }
    }

    private func copyEmailAddress(_ emailAddress: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(emailAddress, forType: .string)
        copiedEmailAddress = emailAddress

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedEmailAddress == emailAddress {
                copiedEmailAddress = nil
            }
        }
    }

    private var drawerActions: some View {
        HStack(spacing: 10) {
            EntityDrawerActionButton(
                label: workspace == .junk ? "Inbox" : "Junk",
                systemImage: workspace == .junk ? "tray.and.arrow.down" : "nosign",
                role: nil
            ) {
                onAction(workspace == .junk ? .moveToInbox : .moveToJunk, entity)
            }

            EntityDrawerActionButton(
                label: workspace == .flagged ? "Unflag" : "Flag",
                systemImage: workspace == .flagged ? "flag.slash" : "flag",
                role: nil
            ) {
                onAction(workspace == .flagged ? .removeFlag : .flagImportant, entity)
            }

            EntityDrawerActionButton(
                label: "Trash",
                systemImage: "trash",
                role: .destructive
            ) {
                onAction(.moveToTrash, entity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }
}

private struct EntityDrawerActionButton: View {
    let label: String
    let systemImage: String
    let role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 30)

                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .foregroundStyle(role == .destructive ? Color.red : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(NoPressEffectButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct NoPressEffectButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private struct TimelineBody: View {
    private static let maximumHTMLHeight: CGFloat = 1024
    private static let topDragRegionHeight: CGFloat = MailiaTopChrome.controlTopPadding
    private static let topGlassHeight: CGFloat = 56

    let entity: MailiaEntitySummary?
    let items: [MailiaTimelineItem]
    let isLoadingTimeline: Bool
    let isLoadingOlderTimeline: Bool
    let isLoadingNewerTimeline: Bool
    let hasOlderTimeline: Bool
    let hasNewerTimeline: Bool
    let bodyStates: [Int64: MailiaTimelineBodyState]
    let attachmentDownloadStates: [Int64: MailiaAttachmentDownloadState]
    let replySendState: MailiaReplySendState
    let sendAccounts: [MailiaSendAccount]
    let selectedSendAccountKey: String?
    let scrollAnchor: MailiaTimelineScrollAnchor?
    let onRequestBody: (MailiaTimelineItem, Int?) -> Void
    let onRequestOlder: () -> Void
    let onRequestNewer: () -> Void
    let onSetMessageFlag: (MailiaTimelineItem, Bool) -> Void
    let onDownloadAttachments: (MailiaTimelineItem) -> Void
    let onSendReply: (MailiaTimelineItem, String, Bool, String?) -> Void
    let onSelectSendAccount: (String) -> Void
    let onComposerEdited: () -> Void
    let onEntityAction: (MailiaEntityAction, MailiaEntitySummary) -> Void
    @State private var isPreparingInitialPosition = true
    @State private var isShowingEntityDrawer = false
    @AppStorage(MailiaPreferenceKeys.timelineBodyDisplayMode)
    private var bodyDisplayMode = TimelineBodyDisplayMode.html.rawValue
    @AppStorage(MailiaPreferenceKeys.loadRemoteContent)
    private var loadRemoteContent = false
    @AppStorage(MailiaPreferenceKeys.showTimelineAvatars)
    private var showTimelineAvatars = true

    private var showsReplyComposer: Bool {
        entity != nil
    }

    private var timelineContextID: String {
        guard let entity else { return "none" }
        return "\(entity.workspace.rawValue):\(entity.id)"
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TimelineWebView(
                state: webState,
                items: items,
                entity: entity,
                onRequestBody: onRequestBody,
                onRequestOlder: onRequestOlder,
                onRequestNewer: onRequestNewer,
                onSetMessageFlag: onSetMessageFlag,
                onDownloadAttachments: onDownloadAttachments,
                onSendReply: onSendReply,
                onSelectSendAccount: onSelectSendAccount,
                onEntityAction: onEntityAction
            )

            timelineFades

            VStack(spacing: 0) {
                // LiquidGlassFade(edge: .top, height: Self.topGlassHeight, opacity: 1)
                //     .overlay(alignment: .top) {
                //         WindowDragRegion()
                //             .frame(height: Self.topDragRegionHeight)
                //     }
                WindowDragRegion()
                    .frame(height: Self.topDragRegionHeight)

                if let entity {
                    TimelineEntityHeader(entity: entity) {
                        withAnimation(.easeOut(duration: 0.22)) {
                            isShowingEntityDrawer = true
                        }
                    }
                    .padding(.top, 4)
                }

                Spacer(minLength: 0)
            }

            if showsReplyComposer {
                ReplyComposerBar(
                    target: items.last,
                    sendAccounts: sendAccounts,
                    selectedSendAccountKey: replySendAccountKey,
                    sendState: replySendState,
                    onSend: { body, accountKey in
                        guard let target = items.last else { return }
                        onSendReply(target, body, false, accountKey)
                    },
                    onSelectSendAccount: onSelectSendAccount,
                    onEdited: onComposerEdited
                )
                .id(timelineContextID)
            }

            if let entity, isShowingEntityDrawer {
                Color.black.opacity(0.001)
                    .ignoresSafeArea(.container, edges: .all)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.22)) {
                            isShowingEntityDrawer = false
                        }
                    }
                    .zIndex(3)

                EntityDetailDrawer(
                    entity: entity,
                    workspace: entity.workspace,
                    onClose: {
                        withAnimation(.easeOut(duration: 0.22)) {
                            isShowingEntityDrawer = false
                        }
                    },
                    onAction: onEntityAction
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
        }
        .onChange(of: timelineContextID) { _, _ in
            isShowingEntityDrawer = false
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(Color(nsColor: .textBackgroundColor))
        .contextMenu {
            if let entity {
                EntityContextMenu(
                    entity: entity,
                    workspace: entity.workspace,
                    onAction: onEntityAction
                )
            }
        }
        .task(id: timelineContextID) {
            isPreparingInitialPosition = true
            await Task.yield()
            try? await Task.sleep(nanoseconds: 100_000_000)
            if !Task.isCancelled {
                isPreparingInitialPosition = false
            }
        }
    }

    private var timelineFades: some View {
        VStack(spacing: 0) {
            TimelineEdgeFade(edge: .top, height: Self.topGlassHeight)

            Spacer(minLength: 0)
        }
        .ignoresSafeArea(.container, edges: .vertical)
        .allowsHitTesting(false)
    }

    private var replySendAccountKey: String? {
        let validAccountKeys = Set(sendAccounts.map(\.id))

        if let selectedSendAccountKey, validAccountKeys.contains(selectedSendAccountKey) {
            return selectedSendAccountKey
        }

        if let latestOutgoing = items.reversed().first(where: {
            $0.direction == .outgoing && validAccountKeys.contains($0.accountLabel)
        }) {
            return latestOutgoing.accountLabel
        }

        if let latestMessage = items.reversed().first(where: {
            validAccountKeys.contains($0.accountLabel)
        }) {
            return latestMessage.accountLabel
        }

        return nil
    }

    private var webState: TimelineWebState {
        TimelineWebState(
            entity: entity,
            items: items,
            isLoadingTimeline: isLoadingTimeline,
            isLoadingOlderTimeline: isLoadingOlderTimeline,
            isLoadingNewerTimeline: isLoadingNewerTimeline,
            hasOlderTimeline: hasOlderTimeline,
            hasNewerTimeline: hasNewerTimeline,
            bodyStates: bodyStates,
            attachmentDownloadStates: attachmentDownloadStates,
            replySendState: replySendState,
            sendAccounts: sendAccounts,
            selectedSendAccountKey: selectedSendAccountKey,
            scrollAnchor: scrollAnchor,
            bodyDisplayMode: bodyDisplayMode,
            loadRemoteContent: loadRemoteContent,
            showTimelineAvatars: showTimelineAvatars
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
    var font: Font = .caption

    var body: some View {
        Text(RelativeTimeLabel.string(from: date))
            .font(font)
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
    var showsEmailAddresses = true
    let onAction: (MailiaEntityAction, MailiaEntitySummary) -> Void

    var body: some View {
        let emailAddresses = entityEmailAddresses(for: entity)

        if showsEmailAddresses && !emailAddresses.isEmpty {
            Section("Email Addresses") {
                ForEach(emailAddresses, id: \.self) { emailAddress in
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(emailAddress, forType: .string)
                    } label: {
                        Label(emailAddress, systemImage: "envelope")
                    }
                }
            }

            Divider()
        }

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

private func entityEmailAddresses(for entity: MailiaEntitySummary) -> [String] {
    let addresses = entity.emailAddresses.isEmpty
        ? [entity.primaryEmailAddress].compactMap(normalizedEmailAddress)
        : entity.emailAddresses.compactMap(normalizedEmailAddress)

    return Array(Set(addresses)).sorted {
        $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
}

private func normalizedEmailAddress(_ emailAddress: String?) -> String? {
    let value = emailAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
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
                    AccountBadgeLabel(emoji: item.accountEmoji, accountKey: item.accountLabel)
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
            .mailia-remote-image-placeholder { align-items: center !important; justify-content: center !important; overflow: hidden !important; max-width: 100% !important; border: 0 !important; border-radius: 0 !important; background: #f2f2f2 !important; color: inherit !important; font: 12px/1.2 -apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, Arial, sans-serif !important; text-align: center !important; white-space: nowrap !important; text-decoration: none !important; outline: 0 !important; }
            a { color: -apple-system-link; }
            table { max-width: 100% !important; width: auto !important; table-layout: auto; }
            pre, code { white-space: pre-wrap; overflow-wrap: anywhere; }
          </style>
        </head>
        <body><main id="mailia-html-root">\(displayHTML)</main></body>
        </html>
        """
    }

    private var displayHTML: String {
        guard !loadRemoteContent else {
            return html
        }

        return (try? HTMLSanitizer().blockRemoteImages(in: html).content) ?? html
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
        while views.count > maxViewCount {
            var removedView = false

            for (index, cacheID) in accessOrder.enumerated() {
                guard let view = views[cacheID] else {
                    accessOrder.remove(at: index)
                    removedView = true
                    break
                }

                guard view.superview == nil else { continue }

                accessOrder.remove(at: index)
                views.removeValue(forKey: cacheID)?.cleanup()
                removedView = true
                break
            }

            guard removedView else { return }
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

    deinit {
        MainActor.assumeIsolated {
            cleanup()
        }
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

    func cleanup() {
        pendingFitWorkItem?.cancel()
        pendingFitWorkItem = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        onLoadingChange = nil
        onContentHeightChange = nil
        contextMenu = nil
        webView.contextMenuProvider = nil
        currentHTML = ""
        isLoading = false
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
        return min(1, availableWidth / contentWidth)
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

private struct AccountBadgeLabel: View {
    let emoji: String?
    let accountKey: String

    var body: some View {
        if let emoji = MailiaSendAccount.normalizedEmoji(emoji) {
            BadgeLabel(text: emoji)
                .help(accountKey)
        } else {
            BadgeLabel(text: accountKey)
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @AppStorage(MailiaPreferenceKeys.timelineBodyDisplayMode)
    private var bodyDisplayMode = TimelineBodyDisplayMode.html.rawValue
    @AppStorage(MailiaPreferenceKeys.loadRemoteContent)
    private var loadRemoteContent = false
    @AppStorage(MailiaPreferenceKeys.showTimelineAvatars)
    private var showTimelineAvatars = true
    @State private var appearanceDraft: AppearanceSettingsDraft
    @State private var accountDrafts: [String: AccountSettingsDraft] = [:]

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        _appearanceDraft = State(initialValue: AppearanceSettingsDraft.saved())
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Form {
                Section("Accounts") {
                    if viewModel.sendAccounts.isEmpty {
                        ContentUnavailableView {
                            Label("No Accounts", systemImage: "tray")
                        } description: {
                            Text("Configured Himalaya accounts will appear here after the first refresh.")
                        } actions: {
                            Button("Refresh Accounts") {
                                Task { await viewModel.refreshConfiguredAccounts() }
                            }
                        }
                    } else {
                        HStack(spacing: 12) {
                            Text("Account")
                                .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
                            Text("Alias")
                                .frame(width: 170, alignment: .leading)
                            Text("Default")
                                .frame(width: 76, alignment: .center)
                            Text("Emoji")
                                .frame(width: 76, alignment: .center)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                        ForEach(viewModel.sendAccounts) { account in
                            AccountSettingsRow(
                                account: account,
                                draft: binding(for: account),
                                fallbackEmoji: AccountEmojiFallback.emoji(
                                    for: account.id,
                                    in: viewModel.sendAccounts
                                ),
                                onDefaultChange: {
                                    setDraftDefault(accountID: account.id)
                                }
                            )
                        }
                    }
                }

                Section("Appearance") {
                    Picker("Message body rendering", selection: $appearanceDraft.bodyDisplayMode) {
                        ForEach(TimelineBodyDisplayMode.allCases) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle("Show avatars in timeline", isOn: $appearanceDraft.showTimelineAvatars)
                }

                Section("Privacy") {
                    Toggle("Load remote content", isOn: $appearanceDraft.loadRemoteContent)
                }

                Section("Diagnostics") {
                    LabeledContent("Core version", value: MailiaCore.version)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(MailiaSettingsChrome.backgroundColor)
            .padding()
            .padding(.bottom, 58)

            settingsSaveBar
        }
        .frame(width: 700, height: 560)
        .background(MailiaSettingsChrome.backgroundColor)
        .task {
            syncAppearanceDraft()
            syncAccountDrafts(with: viewModel.sendAccounts)
            await viewModel.refreshConfiguredAccounts()
        }
        .onChange(of: viewModel.sendAccounts) { _, accounts in
            syncDrafts(with: accounts)
        }
    }

    private var settingsSaveBar: some View {
        HStack {
            Spacer()
            Button("Reset") {
                resetSettingsDrafts()
            }
            .disabled(!hasUnsavedSettingsChanges)
            Button("Save") {
                saveSettingsDrafts()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasUnsavedSettingsChanges)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(MailiaSettingsChrome.backgroundColor)
    }

    private var savedAppearanceDraft: AppearanceSettingsDraft {
        AppearanceSettingsDraft(
            bodyDisplayMode: bodyDisplayMode,
            loadRemoteContent: loadRemoteContent,
            showTimelineAvatars: showTimelineAvatars
        )
    }

    private var hasUnsavedSettingsChanges: Bool {
        hasUnsavedAppearanceChanges || hasUnsavedAccountChanges
    }

    private var hasUnsavedAppearanceChanges: Bool {
        appearanceDraft != savedAppearanceDraft
    }

    private var hasUnsavedAccountChanges: Bool {
        viewModel.sendAccounts.contains { account in
            let saved = AccountSettingsDraft(account: account)
            return (accountDrafts[account.id] ?? saved) != saved
        }
    }

    private func binding(for account: MailiaSendAccount) -> Binding<AccountSettingsDraft> {
        Binding(
            get: {
                accountDrafts[account.id] ?? AccountSettingsDraft(account: account)
            },
            set: { draft in
                accountDrafts[account.id] = draft
            }
        )
    }

    private func syncDrafts(with accounts: [MailiaSendAccount]) {
        guard !hasUnsavedAccountChanges else { return }
        syncAccountDrafts(with: accounts)
    }

    private func syncAccountDrafts(with accounts: [MailiaSendAccount]) {
        accountDrafts = Dictionary(uniqueKeysWithValues: accounts.map { account in
            (account.id, AccountSettingsDraft(account: account))
        })
    }

    private func syncAppearanceDraft() {
        appearanceDraft = savedAppearanceDraft
    }

    private func resetSettingsDrafts() {
        syncAppearanceDraft()
        syncAccountDrafts(with: viewModel.sendAccounts)
    }

    private func saveSettingsDrafts() {
        guard hasUnsavedSettingsChanges else { return }
        saveAppearanceDraft()
        saveAccountDrafts()
    }

    private func saveAppearanceDraft() {
        bodyDisplayMode = appearanceDraft.bodyDisplayMode
        loadRemoteContent = appearanceDraft.loadRemoteContent
        showTimelineAvatars = appearanceDraft.showTimelineAvatars
    }

    private func saveAccountDrafts() {
        let accounts = viewModel.sendAccounts
        let drafts = accountDrafts
        Task {
            var updates: [MailiaAccountSettingsUpdate] = []

            for account in accounts {
                let saved = AccountSettingsDraft(account: account)
                guard let draft = drafts[account.id], draft != saved else { continue }

                updates.append(MailiaAccountSettingsUpdate(
                    accountKey: account.id,
                    displayName: draft.alias != saved.alias ? draft.alias : nil,
                    emoji: draft.emoji != saved.emoji ? draft.emoji : nil,
                    isDefault: nil
                ))
            }

            if let defaultAccountID = accounts.first(where: { account in
                drafts[account.id]?.isDefault == true
            })?.id,
               accounts.first(where: { $0.id == defaultAccountID })?.isDefault != true {
                updates.append(MailiaAccountSettingsUpdate(
                    accountKey: defaultAccountID,
                    displayName: nil,
                    emoji: nil,
                    isDefault: true
                ))
            }

            if !updates.isEmpty {
                await viewModel.saveAccountSettings(updates)
            }
        }
    }

    private func setDraftDefault(accountID: String) {
        for account in viewModel.sendAccounts {
            var draft = accountDrafts[account.id] ?? AccountSettingsDraft(account: account)
            draft.isDefault = account.id == accountID
            accountDrafts[account.id] = draft
        }
    }
}

private struct AccountSettingsRow: View {
    let account: MailiaSendAccount
    @Binding var draft: AccountSettingsDraft
    let fallbackEmoji: String
    let onDefaultChange: () -> Void

    init(
        account: MailiaSendAccount,
        draft: Binding<AccountSettingsDraft>,
        fallbackEmoji: String,
        onDefaultChange: @escaping () -> Void
    ) {
        self.account = account
        _draft = draft
        self.fallbackEmoji = fallbackEmoji
        self.onDefaultChange = onDefaultChange
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(primaryTitle)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)

            SettingsTextField(
                text: $draft.alias,
                placeholder: "",
                alignment: .left,
                font: .systemFont(ofSize: 13),
                normalize: { $0 }
            )
                .settingsFieldChrome()
                .frame(width: 170, height: 30)
                .help("Set this account's Himalaya display-name.")

            Toggle("", isOn: Binding(
                get: { draft.isDefault },
                set: { isDefault in
                    guard isDefault, !draft.isDefault else { return }
                    onDefaultChange()
                }
            ))
                .labelsHidden()
                .toggleStyle(.switch)
                .frame(width: 76, alignment: .center)
            .help(draft.isDefault ? "Default sending account" : "Not the default sending account")

            SettingsTextField(
                text: $draft.emoji,
                placeholder: fallbackEmoji,
                alignment: .center,
                font: .systemFont(ofSize: 16),
                normalize: { MailiaSendAccount.normalizedEmoji($0) ?? "" }
            )
                .settingsFieldChrome()
                .frame(width: 76, height: 30)
                .help("Set an emoji to identify this mailbox in the timeline and composer.")
        }
    }

    private var primaryTitle: String {
        account.emailAddress ?? account.id
    }

}

private struct AppearanceSettingsDraft: Equatable {
    var bodyDisplayMode: String
    var loadRemoteContent: Bool
    var showTimelineAvatars: Bool

    init(
        bodyDisplayMode: String = TimelineBodyDisplayMode.html.rawValue,
        loadRemoteContent: Bool = false,
        showTimelineAvatars: Bool = true
    ) {
        self.bodyDisplayMode = bodyDisplayMode
        self.loadRemoteContent = loadRemoteContent
        self.showTimelineAvatars = showTimelineAvatars
    }

    static func saved(defaults: UserDefaults = .standard) -> AppearanceSettingsDraft {
        let bodyDisplayMode = defaults.string(
            forKey: MailiaPreferenceKeys.timelineBodyDisplayMode
        ) ?? TimelineBodyDisplayMode.html.rawValue
        let loadRemoteContent = defaults.object(forKey: MailiaPreferenceKeys.loadRemoteContent) as? Bool ?? false
        let showTimelineAvatars = defaults.object(forKey: MailiaPreferenceKeys.showTimelineAvatars) as? Bool ?? true
        return AppearanceSettingsDraft(
            bodyDisplayMode: bodyDisplayMode,
            loadRemoteContent: loadRemoteContent,
            showTimelineAvatars: showTimelineAvatars
        )
    }
}

private struct AccountSettingsDraft: Equatable {
    var alias: String
    var emoji: String
    var isDefault: Bool

    init(alias: String, emoji: String, isDefault: Bool) {
        self.alias = alias
        self.emoji = emoji
        self.isDefault = isDefault
    }

    init(account: MailiaSendAccount) {
        self.alias = AccountAliasDisplay.effectiveAlias(for: account)
        self.emoji = account.emoji ?? ""
        self.isDefault = account.isDefault
    }
}

private enum AccountAliasDisplay {
    static func effectiveAlias(for account: MailiaSendAccount) -> String {
        guard let displayName = account.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !displayName.isEmpty else {
            return account.id
        }

        if let localPart = account.emailAddress?.split(separator: "@").first.map(String.init),
           displayName.localizedCaseInsensitiveCompare(localPart) == .orderedSame {
            return account.id
        }

        return displayName
    }
}

private struct SettingsFieldChromeModifier: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 7)
            .background {
                shape.fill(MailiaSettingsChrome.fieldBackgroundColor)
            }
            .overlay {
                shape.stroke(MailiaSettingsChrome.fieldBorderColor, lineWidth: 1)
            }
            .clipShape(shape)
    }
}

private extension View {
    func settingsFieldChrome() -> some View {
        modifier(SettingsFieldChromeModifier())
    }
}

private struct SettingsTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let alignment: NSTextAlignment
    let font: NSFont
    let normalize: (String) -> String

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField(string: text)
        textField.delegate = context.coordinator
        textField.placeholderString = placeholder
        textField.alignment = alignment
        textField.font = font
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .default
        textField.lineBreakMode = .byClipping
        textField.cell?.alignment = alignment
        textField.cell?.lineBreakMode = .byClipping
        textField.textColor = .labelColor
        textField.backgroundColor = .clear
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.normalize = normalize
        textField.font = font
        if textField.stringValue != text {
            textField.stringValue = text
        }
        if textField.placeholderString != placeholder {
            textField.placeholderString = placeholder
        }
        textField.alignment = alignment
        textField.cell?.alignment = alignment
        textField.textColor = .labelColor
        textField.backgroundColor = .clear
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, normalize: normalize)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding private var text: String
        var normalize: (String) -> String

        init(text: Binding<String>, normalize: @escaping (String) -> String) {
            _text = text
            self.normalize = normalize
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text = textField.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            let normalized = normalize(textField.stringValue)
            text = normalized
            if textField.stringValue != normalized {
                textField.stringValue = normalized
            }
        }
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
