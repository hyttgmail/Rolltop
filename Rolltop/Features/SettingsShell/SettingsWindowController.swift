import AppKit
import RolltopCore
import SwiftUI

enum SettingsShellSettings {
    /// Id of the pane shown last; restored when Settings opens without a pane.
    static let lastPane = SettingsKey<String>("rolltop.settings-shell.last-pane", default: "")
}

/// The one settings window. Registered as `services[.settingsWindow]`.
final class SettingsWindowController: NSObject, SettingsWindowPresenting, NSWindowDelegate {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("rolltop.settings")
    /// Content size: wide enough for a grouped form next to the sidebar; the height can
    /// grow for long lists, the width stays fixed.
    static let contentSize = NSSize(width: 720, height: 560)
    static let minimumHeight: CGFloat = 420

    let navigation = SettingsNavigation()
    private unowned let context: AppContext
    private var window: NSWindow?
    private var selectionObserver: ChangeObserver?
    private let log = Log.logger("settings-shell")

    init(context: AppContext) {
        self.context = context
        super.init()
        // Created before any window so the first pane shown is saved as well.
        selectionObserver = ChangeObserver(track: { [weak self] in
            _ = self?.navigation.selection
            _ = self?.context.settingsPanes.panes
        }) { [weak self] in
            self?.selectionChanged()
        }
    }

    var isWindowVisible: Bool { window?.isVisible ?? false }

    // MARK: SettingsWindowPresenting

    func showSettings(paneID: String?) {
        let available = context.settingsPanes.panes.map(\.id)
        let saved = context.settings[SettingsShellSettings.lastPane]
        if paneID != nil || navigation.selection == nil || !available.contains(navigation.selection ?? "") {
            navigation.selection = SettingsSidebar.selection(requested: paneID, saved: saved.isEmpty ? nil : saved,
                                                             available: available)
        }
        if let paneID, !available.contains(paneID) {
            log.notice("unknown settings pane \(paneID); showing \(navigation.selection ?? "none")")
        }
        let window = window ?? makeWindow()
        updateTitle()
        WindowPresentation.present(window, log: log)
        fixSidebarWidth()
    }

    /// `navigationSplitViewColumnWidth` is not applied when a `NavigationSplitView` is
    /// hosted in an `NSHostingController` (measured on 27.2.1: AppKit's default 140 pt
    /// minimum, 144 pt wide, titles truncated). Pin the sidebar item of the split view
    /// controller SwiftUI installs as the split view's delegate; if that ever changes the
    /// sidebar keeps SwiftUI's width.
    private func fixSidebarWidth() {
        guard let content = window?.contentView else { return }
        content.layoutSubtreeIfNeeded()
        func splitView(in view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            return view.subviews.lazy.compactMap(splitView(in:)).first
        }
        guard let split = splitView(in: content), let controller = split.delegate as? NSSplitViewController,
              let sidebar = controller.splitViewItems.first else {
            log.notice("settings sidebar: no split view controller found; width left to SwiftUI")
            return
        }
        let width = SettingsRootView.sidebarWidth
        sidebar.canCollapse = false
        sidebar.minimumThickness = width
        sidebar.maximumThickness = width
        if abs((split.arrangedSubviews.first?.frame.width ?? width) - width) > 0.5 {
            split.setPosition(width, ofDividerAt: 0)
        }
    }

    func close() {
        window?.performClose(nil)
    }

    #if DEBUG
    /// Debug: sets the sidebar search text (live tests cannot type).
    func setSearch(_ query: String) {
        navigation.query = query
    }

    /// Debug: forces the window's appearance without touching the system setting.
    func setAppearance(_ name: NSAppearance.Name?) {
        window?.appearance = name.flatMap(NSAppearance.init(named:))
    }
    #endif

    // MARK: Window

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsRootView(registry: context.settingsPanes, navigation: navigation))
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = [.toolbars]

        let window = NSWindow(contentViewController: hosting)
        window.identifier = Self.windowIdentifier
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(Self.contentSize)
        window.contentMinSize = NSSize(width: Self.contentSize.width, height: Self.minimumHeight)
        window.contentMaxSize = NSSize(width: Self.contentSize.width, height: 4000)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        if !window.setFrameUsingName("RolltopSettings") {
            window.center()
        }
        window.setFrameAutosaveName("RolltopSettings")
        self.window = window
        return window
    }

    private func selectionChanged() {
        updateTitle()
        if let id = navigation.selection {
            context.settings[SettingsShellSettings.lastPane] = id
        }
    }

    private func updateTitle() {
        let pane = navigation.selection.flatMap { context.settingsPanes.pane($0) }
        window?.title = pane.map { String(localized: $0.title) } ?? String(localized: "Settings", table: "SettingsShell")
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Leave search empty for the next opening, like System Settings.
        navigation.query = ""
    }
}
