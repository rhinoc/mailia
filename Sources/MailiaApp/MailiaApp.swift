import MailiaCore
import AppKit
import SwiftUI

enum MailiaPreferenceKeys {
    static let timelineBodyDisplayMode = "MailiaTimelineBodyDisplayMode"
    static let loadRemoteContent = "MailiaLoadRemoteContent"
    static let showTimelineAvatars = "MailiaShowTimelineAvatars"
    static let showOwnTimelineAvatars = "MailiaShowOwnTimelineAvatars"
    static let hideQuotedReplyText = "MailiaHideQuotedReplyText"
    static let hideReplySubjects = "MailiaHideReplySubjects"
    static let autoSyncEnabled = "MailiaAutoSyncEnabled"
    static let autoSyncIntervalMinutes = "MailiaAutoSyncIntervalMinutes"
    static let downloadsDirectoryPath = "MailiaDownloadsDirectoryPath"
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

@propertyWrapper
private struct TimelineDisplayOptionsStorage: DynamicProperty {
    @AppStorage(MailiaPreferenceKeys.timelineBodyDisplayMode)
    private var bodyDisplayMode = TimelineBodyDisplayMode.html.rawValue
    @AppStorage(MailiaPreferenceKeys.loadRemoteContent)
    private var loadRemoteContent = false
    @AppStorage(MailiaPreferenceKeys.showTimelineAvatars)
    private var showTimelineAvatars = true
    @AppStorage(MailiaPreferenceKeys.showOwnTimelineAvatars)
    private var showOwnTimelineAvatars = true
    @AppStorage(MailiaPreferenceKeys.hideQuotedReplyText)
    private var hideQuotedReplyText = false
    @AppStorage(MailiaPreferenceKeys.hideReplySubjects)
    private var hideReplySubjects = false

    var wrappedValue: TimelineDisplayOptions {
        get {
            TimelineDisplayOptions(
                bodyDisplayMode: bodyDisplayMode,
                loadRemoteContent: loadRemoteContent,
                showTimelineAvatars: showTimelineAvatars,
                showOwnTimelineAvatars: showOwnTimelineAvatars,
                hideQuotedReplyText: hideQuotedReplyText,
                hideReplySubjects: hideReplySubjects
            )
        }
        nonmutating set {
            bodyDisplayMode = newValue.bodyDisplayMode
            loadRemoteContent = newValue.loadRemoteContent
            showTimelineAvatars = newValue.showTimelineAvatars
            showOwnTimelineAvatars = newValue.showOwnTimelineAvatars
            hideQuotedReplyText = newValue.hideQuotedReplyText
            hideReplySubjects = newValue.hideReplySubjects
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
    @AppStorage(MailiaPreferenceKeys.autoSyncEnabled)
    private var autoSyncEnabled = true
    @AppStorage(MailiaPreferenceKeys.autoSyncIntervalMinutes)
    private var autoSyncIntervalMinutes = 10
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
                    RefreshToolbarContent(
                        isRefreshing: viewModel.isRefreshing,
                        refreshStatus: viewModel.refreshStatus,
                        refreshActivity: viewModel.refreshActivity,
                        avatarResolutionActivity: viewModel.avatarResolutionActivity,
                        onRefresh: refresh
                    )
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
                onSetMessageFlag: viewModel.setMessageFlag,
                onDownloadAttachments: viewModel.downloadAttachments,
                onSendReply: viewModel.sendReply,
                onSendNewMessage: viewModel.sendNewMessage,
                onSelectSendAccount: viewModel.selectSendAccount,
                onComposerEdited: viewModel.clearReplySendFailure,
                onEntityAction: viewModel.performEntityAction,
                onSyncEntityHistory: viewModel.syncEntityHistory
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
            ComposeToolbarContent(
                isComposingNewMessage: viewModel.isComposingNewMessage,
                onStartComposing: viewModel.startComposingNewMessage,
                onCancelComposing: viewModel.cancelComposingNewMessage
            )
        }
        .task {
            await viewModel.load()
        }
        .task(id: autoSyncTaskID) {
            guard autoSyncEnabled else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(autoSyncDelaySeconds))
                if !Task.isCancelled {
                    await viewModel.refresh()
                }
            }
        }
    }

    private var autoSyncTaskID: String {
        "\(autoSyncEnabled)-\(autoSyncDelaySeconds)"
    }

    private var autoSyncDelaySeconds: Int64 {
        Int64(max(1, autoSyncIntervalMinutes) * 60)
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

    private func refresh() {
        Task {
            await viewModel.refresh()
        }
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
    private static let topScrollAnchorID = "sidebar-top-anchor"

    @ObservedObject var viewModel: AppViewModel
    @AppStorage(MailiaPreferenceKeys.hideQuotedReplyText)
    private var hideQuotedReplyText = false
    @AppStorage(MailiaPreferenceKeys.hideReplySubjects)
    private var hideReplySubjects = false

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
                                hideQuotedReplyText: hideQuotedReplyText,
                                hideReplySubjects: hideReplySubjects,
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
                .overlay(alignment: .top) {
                    sidebarSearchOverlay
                }
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
    static var barHeight: CGFloat {
        itemSize + capsulePadding * 2
    }
    static var barWidth: CGFloat {
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
            WorkspaceTabGlassBackground()
                .equatable()

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
                .equatable()
            }
        }
    }

    private func select(_ workspace: MailiaWorkspace) {
        guard workspace != selection else { return }
        selection = workspace
    }
}

private struct WorkspaceTabGlassBackground: View, Equatable {
    var body: some View {
        GlassEffectContainer(spacing: WorkspaceTabBar.itemSize + WorkspaceTabBar.itemSpacing) {
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.clear)
                    .frame(width: WorkspaceTabBar.barWidth, height: WorkspaceTabBar.barHeight)
                    .background {
                        OuterGlassShadow(shape: AnyShape(Capsule(style: .continuous)))
                    }
                    .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
            }
        }
    }
}

private struct WorkspaceTabButton: View, Equatable {
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

    nonisolated static func == (lhs: WorkspaceTabButton, rhs: WorkspaceTabButton) -> Bool {
        lhs.workspace == rhs.workspace &&
            lhs.isSelected == rhs.isSelected
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

private struct RotatingRefreshSymbol: View {
    let isActive: Bool
    let period: TimeInterval
    @State private var rotation = 0.0

    var body: some View {
        Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
            .font(.system(size: 12, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .frame(width: 15, height: 15, alignment: .center)
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

private struct RefreshToolbarContent: ToolbarContent {
    let isRefreshing: Bool
    let refreshStatus: String
    let refreshActivity: MailiaRefreshProgress?
    let avatarResolutionActivity: MailiaRefreshProgress?
    let onRefresh: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            RefreshButton(
                isRefreshing: isRefreshing,
                refreshStatus: refreshStatus,
                refreshActivity: refreshActivity,
                avatarResolutionActivity: avatarResolutionActivity,
                action: onRefresh
            )
            .equatable()
        }
    }
}

private struct ComposeToolbarContent: ToolbarContent {
    let isComposingNewMessage: Bool
    let onStartComposing: () -> Void
    let onCancelComposing: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if !isComposingNewMessage {
                Button {
                    onStartComposing()
                } label: {
                    Label("New Message", systemImage: "square.and.pencil")
                }
                .help("New Message")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            if isComposingNewMessage {
                Button {
                    onCancelComposing()
                } label: {
                    Text("Cancel")
                }
                .help("Discard new message")
            }
        }
    }
}

private struct RefreshButton: View, Equatable {
    let isRefreshing: Bool
    let refreshStatus: String
    let refreshActivity: MailiaRefreshProgress?
    let avatarResolutionActivity: MailiaRefreshProgress?
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
            guard !isRefreshing else { return }
            action()
        } label: {
            RotatingRefreshSymbol(
                isActive: isRefreshing,
                period: 1.1
            )
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .popover(isPresented: isShowingStatusPopover, arrowEdge: .top) {
            RefreshStatusPopover(
                refreshStatus: refreshStatus,
                refreshActivity: refreshActivity,
                avatarResolutionActivity: avatarResolutionActivity
            )
        }
        .help("Refresh\n\(refreshStatus)")
    }

    nonisolated static func == (lhs: RefreshButton, rhs: RefreshButton) -> Bool {
        lhs.isRefreshing == rhs.isRefreshing &&
            lhs.refreshStatus == rhs.refreshStatus &&
            lhs.refreshActivity == rhs.refreshActivity &&
            lhs.avatarResolutionActivity == rhs.avatarResolutionActivity
    }
}

private struct RefreshStatusPopover: View {
    let refreshStatus: String
    let refreshActivity: MailiaRefreshProgress?
    let avatarResolutionActivity: MailiaRefreshProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let activity = refreshActivity {
                RefreshProgressSection(activity: activity)
            } else {
                RefreshStatusSection(status: refreshStatus)
            }

            if let avatarActivity = avatarResolutionActivity {
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
    let hideQuotedReplyText: Bool
    let hideReplySubjects: Bool
    let onAppear: () -> Void

    var body: some View {
        EntityRowContent(
            entity: entity,
            isSelected: isSelected,
            hideQuotedReplyText: hideQuotedReplyText,
            hideReplySubjects: hideReplySubjects
        )
        .equatable()
        .onAppear(perform: onAppear)
    }
}

private struct EntityRowContent: View, Equatable {
    let entity: MailiaEntitySummary
    let isSelected: Bool
    let hideQuotedReplyText: Bool
    let hideReplySubjects: Bool

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
    }

    private var previewText: String {
        EntitySidebarPreviewCache.shared.preview(
            for: entity,
            hideReplySubjects: hideReplySubjects,
            hideQuotedReplyText: hideQuotedReplyText
        )
    }

    nonisolated static func == (lhs: EntityRowContent, rhs: EntityRowContent) -> Bool {
        lhs.entity.id == rhs.entity.id &&
            lhs.entity.displayName == rhs.entity.displayName &&
            lhs.entity.unreadCount == rhs.entity.unreadCount &&
            lhs.entity.latestSubject == rhs.entity.latestSubject &&
            lhs.entity.latestBodyPreview == rhs.entity.latestBodyPreview &&
            lhs.entity.latestDate == rhs.entity.latestDate &&
            lhs.entity.primaryEmailAddress == rhs.entity.primaryEmailAddress &&
            lhs.entity.kind == rhs.entity.kind &&
            lhs.entity.avatarImageDataURL == rhs.entity.avatarImageDataURL &&
            lhs.isSelected == rhs.isSelected &&
            lhs.hideQuotedReplyText == rhs.hideQuotedReplyText &&
            lhs.hideReplySubjects == rhs.hideReplySubjects
    }
}

@MainActor
private final class EntitySidebarPreviewCache {
    static let shared = EntitySidebarPreviewCache()

    private let cache = NSCache<EntitySidebarPreviewCacheKey, NSString>()

    private init() {
        cache.countLimit = 1024
    }

    func preview(
        for entity: MailiaEntitySummary,
        hideReplySubjects: Bool,
        hideQuotedReplyText: Bool
    ) -> String {
        guard hideReplySubjects else {
            return entity.sidebarPreview(
                hideReplySubjects: false,
                hideQuotedReplyText: hideQuotedReplyText
            )
        }

        let key = EntitySidebarPreviewCacheKey(
            entity: entity,
            hideQuotedReplyText: hideQuotedReplyText
        )
        if let preview = cache.object(forKey: key) {
            return preview as String
        }

        let preview = entity.sidebarPreview(
            hideReplySubjects: true,
            hideQuotedReplyText: hideQuotedReplyText
        )
        cache.setObject(preview as NSString, forKey: key)
        return preview
    }
}

private final class EntitySidebarPreviewCacheKey: NSObject {
    private let entityID: Int64
    private let latestSubject: String
    private let latestBodyPreview: String?
    private let primaryEmailAddress: String?
    private let kind: EntityKind
    private let hideQuotedReplyText: Bool
    private let cachedHash: Int

    init(entity: MailiaEntitySummary, hideQuotedReplyText: Bool) {
        self.entityID = entity.id
        self.latestSubject = entity.latestSubject
        self.latestBodyPreview = entity.latestBodyPreview
        self.primaryEmailAddress = entity.primaryEmailAddress
        self.kind = entity.kind
        self.hideQuotedReplyText = hideQuotedReplyText
        var hasher = Hasher()
        hasher.combine(entityID)
        hasher.combine(latestSubject)
        hasher.combine(latestBodyPreview)
        hasher.combine(primaryEmailAddress)
        hasher.combine(kind.rawValue)
        hasher.combine(hideQuotedReplyText)
        self.cachedHash = hasher.finalize()
    }

    override var hash: Int {
        cachedHash
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? EntitySidebarPreviewCacheKey else {
            return false
        }
        return entityID == other.entityID &&
            latestSubject == other.latestSubject &&
            latestBodyPreview == other.latestBodyPreview &&
            primaryEmailAddress == other.primaryEmailAddress &&
            kind == other.kind &&
            hideQuotedReplyText == other.hideQuotedReplyText
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
        EntityAvatarImageCache.shared.image(for: entity, size: size)
    }
}

@MainActor
private final class EntityAvatarImageCache {
    static let shared = EntityAvatarImageCache()

    private let cache = NSCache<EntityAvatarImageCacheKey, NSImage>()

    private init() {
        cache.countLimit = 512
    }

    func image(for entity: MailiaEntitySummary, size: CGFloat) -> NSImage? {
        if let dataURL = entity.avatarImageDataURL {
            return cachedImage(
                for: EntityAvatarImageCacheKey(
                    kind: .remote(entityID: entity.id, dataURL: dataURL),
                    size: size
                )
            ) {
                NSImage.mailiaImage(dataURL: dataURL)
            }
        }

        return cachedImage(
            for: EntityAvatarImageCacheKey(
                kind: .fallback(entityID: entity.id, displayName: entity.displayName),
                size: size
            )
        ) {
            EntityAvatarRenderer.image(
                id: entity.id,
                displayName: entity.displayName,
                size: size
            )
        }
    }

    private func cachedImage(
        for key: EntityAvatarImageCacheKey,
        load: () -> NSImage?
    ) -> NSImage? {
        if let image = cache.object(forKey: key) {
            return image
        }

        guard let image = load() else {
            return nil
        }

        image.cacheMode = .always
        cache.setObject(image, forKey: key)
        return image
    }
}

private final class EntityAvatarImageCacheKey: NSObject {
    enum Kind: Equatable {
        case remote(entityID: Int64, dataURL: String)
        case fallback(entityID: Int64, displayName: String)
    }

    private let kind: Kind
    private let size: CGFloat
    private let cachedHash: Int

    init(kind: Kind, size: CGFloat) {
        self.kind = kind
        self.size = size
        var hasher = Hasher()
        hasher.combine(size)
        switch kind {
        case .remote(let entityID, let dataURL):
            hasher.combine("remote")
            hasher.combine(entityID)
            hasher.combine(dataURL)
        case .fallback(let entityID, let displayName):
            hasher.combine("fallback")
            hasher.combine(entityID)
            hasher.combine(displayName)
        }
        self.cachedHash = hasher.finalize()
    }

    override var hash: Int {
        cachedHash
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? EntityAvatarImageCacheKey else {
            return false
        }
        return kind == other.kind && size == other.size
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
    let onSetMessageFlag: (MailiaTimelineItem, Bool) -> Void
    let onDownloadAttachments: (MailiaTimelineItem) -> Void
    let onSendReply: (MailiaTimelineItem, String, Bool, String?) -> Void
    let onSendNewMessage: ([String], String?, String, String?) -> Void
    let onSelectSendAccount: (String) -> Void
    let onComposerEdited: () -> Void
    let onEntityAction: (MailiaEntityAction, MailiaEntitySummary) -> Void
    let onSyncEntityHistory: (MailiaEntitySummary) -> Void

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
                    onSetMessageFlag: onSetMessageFlag,
                    onDownloadAttachments: onDownloadAttachments,
                    onSendReply: onSendReply,
                    onSelectSendAccount: onSelectSendAccount,
                    onComposerEdited: onComposerEdited,
                    onEntityAction: onEntityAction,
                    onSyncEntityHistory: onSyncEntityHistory
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
    let onSyncHistory: (MailiaEntitySummary) -> Void
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
                    syncHistoryButton
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

    private var syncHistoryButton: some View {
        Button {
            onSyncHistory(entity)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 14, weight: .semibold))

                Text("Sync all history")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 8)
            }
            .foregroundStyle(emailAddresses.isEmpty ? Color.secondary : Color.primary)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(emailAddresses.isEmpty)
        .help(emailAddresses.isEmpty ? "No email address is available for this entity." : "Sync older messages matching this entity's email addresses.")
    }

    private var drawerActions: some View {
        HStack(spacing: 10) {
            ForEach(EntityActionPolicy.visibleActions(for: workspace.coreWorkspace), id: \.self) { action in
                EntityDrawerActionButton(
                    label: action.label,
                    systemImage: action.systemImage,
                    role: action.buttonRole
                ) {
                    onAction(action, entity)
                }
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
    let onSetMessageFlag: (MailiaTimelineItem, Bool) -> Void
    let onDownloadAttachments: (MailiaTimelineItem) -> Void
    let onSendReply: (MailiaTimelineItem, String, Bool, String?) -> Void
    let onSelectSendAccount: (String) -> Void
    let onComposerEdited: () -> Void
    let onEntityAction: (MailiaEntityAction, MailiaEntitySummary) -> Void
    let onSyncEntityHistory: (MailiaEntitySummary) -> Void
    @State private var isPreparingInitialPosition = true
    @State private var isShowingEntityDrawer = false
    @State private var replyComposerHeight: CGFloat = 0
    @TimelineDisplayOptionsStorage
    private var displayOptions

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
                onSetMessageFlag: onSetMessageFlag,
                onDownloadAttachments: onDownloadAttachments,
                onSendReply: onSendReply,
                onSelectSendAccount: onSelectSendAccount,
                onEntityAction: onEntityAction
            )

            timelineFades

            VStack(spacing: 0) {
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
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ComposerHeightPreferenceKey.self,
                            value: ComposerHeightPreference(
                                contextID: timelineContextID,
                                height: proxy.size.height
                            )
                        )
                    }
                }
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
                    onAction: onEntityAction,
                    onSyncHistory: onSyncEntityHistory
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
        }
        .onChange(of: timelineContextID) { _, _ in
            isShowingEntityDrawer = false
            replyComposerHeight = 0
        }
        .onPreferenceChange(ComposerHeightPreferenceKey.self) { preference in
            guard let preference,
                  preference.contextID == timelineContextID,
                  abs(replyComposerHeight - preference.height) > 1 else {
                return
            }
            replyComposerHeight = preference.height
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
            displayOptions: displayOptions,
            windowState: TimelineWindowState(
                bottomOverlayHeight: showsReplyComposer ? replyComposerHeight : 0
            )
        )
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

        ForEach(EntityActionPolicy.visibleActions(for: workspace.coreWorkspace), id: \.self) { action in
            Button(role: action.buttonRole) {
                onAction(action, entity)
            } label: {
                Label(action.label, systemImage: action.systemImage)
            }
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

private struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @TimelineDisplayOptionsStorage
    private var displayOptions
    @AppStorage(MailiaPreferenceKeys.autoSyncEnabled)
    private var autoSyncEnabled = true
    @AppStorage(MailiaPreferenceKeys.autoSyncIntervalMinutes)
    private var autoSyncIntervalMinutes = 10
    @AppStorage(MailiaPreferenceKeys.downloadsDirectoryPath)
    private var downloadsDirectoryPath = ""
    @State private var appearanceDraft: TimelineDisplayOptions
    @State private var syncDraft: SyncSettingsDraft
    @State private var downloadsDraft: DownloadsSettingsDraft
    @State private var accountDrafts: [String: AccountSettingsDraft] = [:]

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        _appearanceDraft = State(initialValue: TimelineDisplayOptions.saved())
        _syncDraft = State(initialValue: SyncSettingsDraft.saved())
        _downloadsDraft = State(initialValue: DownloadsSettingsDraft.saved())
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Form {
                Section("Sync") {
                    LabeledContent("Status") {
                        Text(viewModel.refreshStatus)
                            .foregroundStyle(.secondary)
                    }

                    if let activity = viewModel.refreshActivity {
                        if let fraction = activity.fraction {
                            ProgressView(value: fraction)
                                .help(activity.detail ?? activity.title)
                        } else {
                            ProgressView()
                                .help(activity.detail ?? activity.title)
                        }
                    }

                    Picker("Sync mode", selection: Binding(
                        get: { syncDraft.autoSyncEnabled ? SettingsSyncMode.automatic : .manual },
                        set: { mode in syncDraft.autoSyncEnabled = mode == .automatic }
                    )) {
                        ForEach(SettingsSyncMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Automatic interval", selection: $syncDraft.intervalMinutes) {
                        ForEach(SyncSettingsDraft.allowedIntervals, id: \.self) { minutes in
                            Text(SyncSettingsDraft.intervalLabel(minutes)).tag(minutes)
                        }
                    }
                    .disabled(!syncDraft.autoSyncEnabled)

                    HStack {
                        Spacer()

                        Button("Sync Now") {
                            Task { await viewModel.refresh() }
                        }
                        .disabled(viewModel.isRefreshing)

                        Button("Sync All History Once") {
                            Task { await viewModel.refreshFullHistory() }
                        }
                        .disabled(viewModel.isRefreshing)
                    }
                }

                Section("Downloads") {
                    LabeledContent("Attachment location") {
                        HStack {
                            Text(downloadsDraft.effectivePath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Button("Choose...") {
                                chooseDownloadsDirectory()
                            }
                            Button("Use Downloads") {
                                downloadsDraft.path = ""
                            }
                        }
                    }
                }

                Section("Cache Management") {
                    CacheSettingsTable(
                        summaries: viewModel.cacheSummaries,
                        status: viewModel.cacheOperationStatus,
                        onClear: { kind in
                            viewModel.clearCache(kind)
                        }
                    )
                }

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

                    Toggle("Show sender avatars", isOn: $appearanceDraft.showTimelineAvatars)

                    Toggle("Show my account avatars", isOn: $appearanceDraft.showOwnTimelineAvatars)

                    Toggle("Hide quoted reply history", isOn: $appearanceDraft.hideQuotedReplyText)

                    Toggle("Hide reply subjects", isOn: $appearanceDraft.hideReplySubjects)
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
            syncSettingsDraft()
            syncAppearanceDraft()
            syncDownloadsDraft()
            syncAccountDrafts(with: viewModel.sendAccounts)
            await viewModel.refreshConfiguredAccounts()
            await viewModel.refreshCacheSummaries()
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

    private var savedAppearanceDraft: TimelineDisplayOptions {
        displayOptions
    }

    private var savedSyncDraft: SyncSettingsDraft {
        SyncSettingsDraft(
            autoSyncEnabled: autoSyncEnabled,
            intervalMinutes: autoSyncIntervalMinutes
        )
    }

    private var savedDownloadsDraft: DownloadsSettingsDraft {
        DownloadsSettingsDraft(path: downloadsDirectoryPath)
    }

    private var hasUnsavedSettingsChanges: Bool {
        hasUnsavedSyncChanges || hasUnsavedDownloadsChanges || hasUnsavedAppearanceChanges || hasUnsavedAccountChanges
    }

    private var hasUnsavedSyncChanges: Bool {
        syncDraft != savedSyncDraft
    }

    private var hasUnsavedDownloadsChanges: Bool {
        downloadsDraft != savedDownloadsDraft
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

    private func syncSettingsDraft() {
        syncDraft = savedSyncDraft
    }

    private func syncDownloadsDraft() {
        downloadsDraft = savedDownloadsDraft
    }

    private func resetSettingsDrafts() {
        syncSettingsDraft()
        syncAppearanceDraft()
        syncDownloadsDraft()
        syncAccountDrafts(with: viewModel.sendAccounts)
    }

    private func saveSettingsDrafts() {
        guard hasUnsavedSettingsChanges else { return }
        saveSyncDraft()
        saveAppearanceDraft()
        saveDownloadsDraft()
        saveAccountDrafts()
    }

    private func saveSyncDraft() {
        autoSyncEnabled = syncDraft.autoSyncEnabled
        autoSyncIntervalMinutes = syncDraft.normalizedIntervalMinutes
    }

    private func saveAppearanceDraft() {
        displayOptions = appearanceDraft
    }

    private func saveDownloadsDraft() {
        downloadsDirectoryPath = downloadsDraft.normalizedPath
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

    private func chooseDownloadsDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: downloadsDraft.effectivePath, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        downloadsDraft.path = url.path
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

private enum SettingsSyncMode: String, CaseIterable, Identifiable {
    case manual
    case automatic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .manual:
            "Manual"
        case .automatic:
            "Automatic"
        }
    }
}

private struct SyncSettingsDraft: Equatable {
    static let allowedIntervals = [5, 10, 15, 30, 60]

    var autoSyncEnabled: Bool
    var intervalMinutes: Int

    var normalizedIntervalMinutes: Int {
        Self.allowedIntervals.contains(intervalMinutes) ? intervalMinutes : 10
    }

    static func saved(defaults: UserDefaults = .standard) -> SyncSettingsDraft {
        let autoSyncEnabled = defaults.object(forKey: MailiaPreferenceKeys.autoSyncEnabled) as? Bool ?? true
        let intervalMinutes = defaults.object(forKey: MailiaPreferenceKeys.autoSyncIntervalMinutes) as? Int ?? 10
        return SyncSettingsDraft(
            autoSyncEnabled: autoSyncEnabled,
            intervalMinutes: Self.allowedIntervals.contains(intervalMinutes) ? intervalMinutes : 10
        )
    }

    static func intervalLabel(_ minutes: Int) -> String {
        minutes == 60 ? "1 hour" : "\(minutes) minutes"
    }
}

private struct DownloadsSettingsDraft: Equatable {
    var path: String

    var normalizedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var effectivePath: String {
        normalizedPath.nilIfBlank ?? Self.defaultDownloadsPath()
    }

    static func saved(defaults: UserDefaults = .standard) -> DownloadsSettingsDraft {
        DownloadsSettingsDraft(
            path: defaults.string(forKey: MailiaPreferenceKeys.downloadsDirectoryPath) ?? ""
        )
    }

    private static func defaultDownloadsPath(fileManager: FileManager = .default) -> String {
        (try? fileManager.url(
            for: .downloadsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).path) ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
    }
}

private struct CacheSettingsTable: View {
    let summaries: [MailiaCacheSummary]
    let status: String?
    let onClear: (MailiaCacheKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Cache")
                    .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                Text("Items")
                    .frame(width: 70, alignment: .trailing)
                Text("Size")
                    .frame(width: 90, alignment: .trailing)
                Text("Folder")
                    .frame(width: 54, alignment: .center)
                Text("")
                    .frame(width: 70)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            ForEach(MailiaCacheKind.allCases) { kind in
                let summary = summaries.first { $0.kind == kind }
                HStack(spacing: 12) {
                    Text(kind.displayName)
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)

                    Text(summary.map { "\($0.itemCount)" } ?? "-")
                        .monospacedDigit()
                        .frame(width: 70, alignment: .trailing)

                    Text(summary.map { Self.formattedBytes($0.byteSize) } ?? "-")
                        .monospacedDigit()
                        .frame(width: 90, alignment: .trailing)

                    Button {
                        Self.openFolder(for: kind)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 54, alignment: .center)
                    .help("Open \(kind.displayName) folder")
                    .disabled(Self.folderURL(for: kind) == nil)

                    Button("Clear") {
                        onClear(kind)
                    }
                    .frame(width: 70, alignment: .trailing)
                    .disabled((summary?.itemCount ?? 0) == 0)
                }
            }

            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func folderURL(for kind: MailiaCacheKind) -> URL? {
        switch kind {
        case .avatars:
            EntityBrandAvatarResolver.defaultDiskCacheDirectory()
        case .messageBodies:
            try? MailiaEnvironment.live().applicationSupportDirectory
        }
    }

    private static func openFolder(for kind: MailiaCacheKind) {
        guard let folderURL = folderURL(for: kind) else { return }
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folderURL)
    }
}

private extension TimelineDisplayOptions {
    static func saved(defaults: UserDefaults = .standard) -> TimelineDisplayOptions {
        let bodyDisplayMode = defaults.string(
            forKey: MailiaPreferenceKeys.timelineBodyDisplayMode
        ) ?? TimelineBodyDisplayMode.html.rawValue
        let loadRemoteContent = defaults.object(forKey: MailiaPreferenceKeys.loadRemoteContent) as? Bool ?? false
        let showTimelineAvatars = defaults.object(forKey: MailiaPreferenceKeys.showTimelineAvatars) as? Bool ?? true
        let showOwnTimelineAvatars = defaults.object(
            forKey: MailiaPreferenceKeys.showOwnTimelineAvatars
        ) as? Bool ?? showTimelineAvatars
        let hideQuotedReplyText = defaults.object(forKey: MailiaPreferenceKeys.hideQuotedReplyText) as? Bool ?? false
        let hideReplySubjects = defaults.object(forKey: MailiaPreferenceKeys.hideReplySubjects) as? Bool ?? false
        return TimelineDisplayOptions(
            bodyDisplayMode: bodyDisplayMode,
            loadRemoteContent: loadRemoteContent,
            showTimelineAvatars: showTimelineAvatars,
            showOwnTimelineAvatars: showOwnTimelineAvatars,
            hideQuotedReplyText: hideQuotedReplyText,
            hideReplySubjects: hideReplySubjects
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

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
