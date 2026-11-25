import AppKit
import RolltopCore

/// Shows the Search panel, ranks rows as the user types and runs the chosen one.
final class PaletteController: NSObject, NSTextFieldDelegate {
    enum CloseReason: String, Codable {
        case escape
        case clickOutside = "click-outside"
        case resignedKey = "resigned-key"
        case toggled
        /// A row ran (items close first, then open).
        case ran
        /// A settings row or the shortcut link opened Rolltop's settings window.
        case openedWindow = "opened-window"
        case spaceChanged = "space-changed"
        case api
        /// Another transient surface (the Rolltop Bar, the Shelf, a group) opened.
        case yielded
    }

    /// Id of this surface in `services[.surfaces]`.
    static let surfaceID = "palette"

    let model = PaletteModel()
    let usage: PaletteUsageStore
    private(set) var isVisible = false
    /// Off in unit tests: prepare everything and take keys, but never put a window on screen.
    var presentsOnScreen = true
    /// Replaces running a row (tests).
    var runOverride: ((PaletteRow, PaletteClick) -> Void)?
    /// Forces light or dark glass (Debug look checks); nil follows the system.
    var debugAppearance: NSAppearance? {
        didSet {
            panel?.appearance = debugAppearance
            toast.appearance = debugAppearance
        }
    }

    private unowned let context: AppContext
    private let source: PaletteRowSource
    private(set) var panel: PalettePanel?
    private let toast = PaletteToast()
    private var baseRows: [PaletteRow] = []
    private var baseCandidates: [PaletteCandidate] = []
    private var monitors: [Any] = []
    private var notificationObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var contentObserver: ChangeObserver?
    private let log = Log.logger("palette")

    // Diagnostics for the Debug dump.
    private(set) var showCount = 0
    private(set) var runCount = 0
    private(set) var lastCloseReason: CloseReason?
    private(set) var lastRun: String?
    private(set) var lastRunResult: String?
    private(set) var frontmostAtShow: String?
    private(set) var frontmostAtClose: String?
    private(set) var appActiveWhileShown: Bool?
    private(set) var keyWhileShown: Bool?
    private var lastPanelTopCenter: CGPoint?
    /// The destructive command row (`CommandEffect.destructive`) that was chosen once and
    /// runs when chosen again; cleared by typing, moving the selection or closing.
    private(set) var pendingConfirmation: String?

    init(context: AppContext) {
        self.context = context
        source = PaletteRowSource(context: context)
        usage = PaletteUsageStore(settings: context.settings)
        super.init()
    }

    var toastMessage: String? { toast.message }

    // MARK: Showing and closing

    func toggle() {
        if isVisible { close(.toggled) } else { show() }
    }

    /// Opens the panel on the configured screen with an empty query. While it is open,
    /// showing it again only brings it forward (never a second panel).
    func show() {
        if isVisible, let panel {
            if presentsOnScreen { focus(panel) }
            return
        }
        // One transient surface at a time: whatever is up (the Rolltop Bar, the Shelf) closes.
        context.services[.surfaces].willPresent(Self.surfaceID) { [weak self] _ in self?.close(.yielded, animated: false) }
        toast.hide()
        frontmostAtShow = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        frontmostAtClose = nil

        let panel = panel ?? makePanel()
        model.query = ""
        panel.content.field.stringValue = ""
        model.message = nil
        updateShortcut()
        rebuildBaseRows()
        refreshResults(keepingSelection: false)

        let screen = targetScreen()
        let frame = PalettePlacement.frame(height: model.panelHeight, width: model.metrics.width,
                                           maxHeight: model.metrics.maxPanelHeight,
                                           visibleFrame: screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 875))
        panel.appearance = debugAppearance
        panel.setFrame(frame, display: false)
        panel.content.needsLayout = true
        isVisible = true
        showCount += 1
        observeContent()
        guard presentsOnScreen else { return }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = 0
        if !reduceMotion { panel.setFrame(frame.offsetBy(dx: 0, dy: 8), display: false) }
        focus(panel)
        NSAnimationContext.runAnimationGroup { animation in
            animation.duration = reduceMotion ? 0.08 : 0.16
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            if !reduceMotion { panel.animator().setFrame(frame, display: true) }
        }
        startMonitoring()
        appActiveWhileShown = NSApp.isActive
        keyWhileShown = panel.isKeyWindow
        log.info("shown with \(model.results.count) rows; key \(panel.isKeyWindow), app active \(NSApp.isActive), frontmost \(frontmostAtShow ?? "nil")")
    }

    private func focus(_ panel: PalettePanel) {
        // A non-activating panel becomes key without activating Rolltop: the frontmost app
        // stays frontmost and keeps its windows.
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.content.field)
    }

    func close(_ reason: CloseReason, animated: Bool = true) {
        guard isVisible, let panel else { return }
        isVisible = false
        lastCloseReason = reason
        pendingConfirmation = nil
        lastPanelTopCenter = CGPoint(x: panel.frame.midX, y: panel.frame.maxY)
        stopMonitoring()
        contentObserver?.cancel()
        contentObserver = nil
        model.hovered = nil
        model.pressed = nil
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !animated || reduceMotion || !presentsOnScreen {
            panel.orderOut(nil)
        } else {
            NSAnimationContext.runAnimationGroup({ animation in
                animation.duration = 0.1
                animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self, weak panel] in
                Task { @MainActor in
                    guard let self, !self.isVisible else { return }
                    panel?.orderOut(nil)
                }
            })
        }
        // The panel never makes Rolltop the frontmost app, but while it is key AppKit reports
        // Rolltop as active (measured on 27.2): the coordinator hands activation back to the app
        // that was frontmost so its key window takes the keyboard again (never to an open
        // Rolltop window; rows that open settings close with `.openedWindow`). A click elsewhere
        // is the user choosing another app, and a surface that takes over keeps it.
        let restore = presentsOnScreen && [.escape, .toggled, .ran, .api].contains(reason)
        context.services[.surfaces].didDismiss(Self.surfaceID, restoreFocus: restore)
        frontmostAtClose = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        log.info("closed: \(reason.rawValue)")
    }

    private func makePanel() -> PalettePanel {
        let panel = PalettePanel(model: model)
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        panel.content.field.delegate = self
        panel.content.list.onRun = { [weak self] index, click in self?.run(index, click: click) }
        panel.content.onSetShortcut = { [weak self] in self?.openShortcutSettings() }
        self.panel = panel
        return panel
    }

    private func targetScreen() -> NSScreen? {
        switch PaletteScreenChoice(setting: context.settings[PaletteSettings.screen]) {
        case .pointer:
            let mouse = NSEvent.mouseLocation
            return NSScreen.screens.first { $0.frame.insetBy(dx: 0, dy: -1).contains(mouse) } ?? NSScreen.main
        case .main:
            return NSScreen.main ?? NSScreen.screens.first
        }
    }

    // MARK: Rows

    private func rebuildBaseRows() {
        baseRows = source.rows()
        baseCandidates = baseRows.map(\.candidate)
    }

    /// Ranks the rows for the current query and resizes the panel to the result count.
    func refreshResults(keepingSelection: Bool) {
        let provided = source.providedRows(for: model.query.trimmingCharacters(in: .whitespacesAndNewlines))
        let rows = baseRows + provided
        let candidates = baseCandidates + provided.map(\.candidate)
        let query = PaletteQuery(model.query)
        let now = Date()
        if query.isEmpty {
            let indices = PaletteRanker.emptyQuery(candidates, usage: usage.usage, now: now)
            model.setResults(indices.map { rows[$0] }, tiers: indices.map { _ in nil }, keepingSelection: keepingSelection)
        } else {
            let ranked = PaletteRanker.rank(candidates, query: query, usage: usage.usage, now: now)
            model.setResults(ranked.map { rows[$0.index] }, tiers: ranked.map(\.tier), keepingSelection: keepingSelection)
        }
        resizePanel()
    }

    private func resizePanel() {
        guard isVisible, let panel else { return }
        let height = model.panelHeight
        guard abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion || !presentsOnScreen {
            panel.setFrame(frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { animation in
                animation.duration = 0.14
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        }
    }

    /// While open, rows follow the catalog, captures, profiles, commands, panes and settings.
    private func observeContent() {
        contentObserver = ChangeObserver(track: { [weak self] in
            guard let self else { return }
            _ = self.context.catalog.entries
            _ = self.context.services[.itemImages].revision
            _ = self.context.services[.profiles].activeProfileID
            _ = self.context.services[.profiles].profiles
            _ = self.context.commands.commands
            _ = self.context.settingsPanes.panes
            _ = self.context.services[.paletteResultProviders].providers
            _ = self.context.services[.hotkeyBindings].revision
            _ = self.context.settings[PaletteSettings.includeItems]
            _ = self.context.settings[PaletteSettings.includeProfiles]
            _ = self.context.settings[PaletteSettings.includeCommands]
            _ = self.context.settings[PaletteSettings.includeSettings]
        }) { [weak self] in
            guard let self, self.isVisible else { return }
            self.updateShortcut()
            self.rebuildBaseRows()
            self.refreshResults(keepingSelection: true)
        }
    }

    private func updateShortcut() {
        let hotkeys = context.services[.hotkeyBindings]
        let combo = hotkeys.shortcut(for: PaletteCommandIDs.toggle, arguments: [:])
            ?? hotkeys.shortcut(for: PaletteCommandIDs.show, arguments: [:])
        model.shortcut = combo.map { hotkeys.displayString(for: $0) }
    }

    func setQuery(_ text: String) {
        pendingConfirmation = nil
        model.query = text
        if let field = panel?.content.field, field.stringValue != text {
            field.stringValue = text
            // As after typing: the caret at the end, nothing selected.
            field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
        model.message = nil
        refreshResults(keepingSelection: false)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        pendingConfirmation = nil
        model.query = field.stringValue
        model.message = nil
        refreshResults(keepingSelection: false)
    }

    // MARK: Keys

    /// Every key down reaching the panel comes here first (`PalettePanel.sendEvent` and
    /// `performKeyEquivalent`). Returns true when the palette handled it.
    func handleKey(_ event: NSEvent) -> Bool {
        guard isVisible, let panel else { return false }
        guard let action = PaletteKeys.action(keyCode: event.keyCode, modifiers: event.modifierFlags,
                                              characters: event.charactersIgnoringModifiers,
                                              hasMarkedText: panel.hasMarkedText,
                                              pageRows: model.metrics.maxVisibleRows) else { return false }
        perform(action)
        return true
    }

    private func perform(_ action: PaletteKeys.Action) {
        switch action {
        case .move(let delta):
            if pendingConfirmation != nil {
                pendingConfirmation = nil
                model.message = nil
            }
            model.move(by: delta)
        case .runSelected(let click): if let index = model.selected { run(index, click: click) }
        case .runSelectedSecond: if let index = model.selected { run(index, click: .left, second: true) }
        case .runIndex(let index): run(index, click: .left)
        case .close: close(.escape)
        case .swallow: break
        }
    }

    // MARK: Running

    /// `second`: ⌘Return, which runs the row's second action when it has one and otherwise
    /// does what Return does.
    func run(_ index: Int, click: PaletteClick, second: Bool = false) {
        guard model.results.indices.contains(index) else { return }
        let row = model.results[index]
        if needsConfirmation(row) {
            pendingConfirmation = row.id
            model.message = String(localized: "Press Return again to run “\(row.title)”.", table: "CommandPalette",
                                   comment: "Footer note after choosing a command that deletes data or can run scripts once")
            log.info("asking to confirm a destructive command")
            return
        }
        pendingConfirmation = nil
        if let runOverride {
            runOverride(row, click)
            return
        }
        if second, let secondAction = row.secondAction {
            runSecond(secondAction, of: row)
            return
        }
        usage.record(row.id)
        runCount += 1
        lastRun = "\(row.id) (\(click.rawValue))"
        lastRunResult = nil
        log.info("run \(row.kind) row (\(click.rawValue))")
        let stays = !context.settings[PaletteSettings.closeAfterRunning]

        switch row.action {
        case .item(let owner, let itemIndex):
            // Close first: the item's menu opens under the menu bar and takes the keyboard.
            close(.ran, animated: false)
            let button: ItemActivator.Button = click == .right ? .right : .left
            Task { [weak self] in
                guard let self else { return }
                do {
                    let outcome = try await self.context.activator.activate(owner, button: button, index: itemIndex)
                    self.lastRunResult = outcome.rawValue
                } catch {
                    self.report(error, title: row.title)
                }
            }
        case .settings(let paneID):
            close(.openedWindow, animated: false)
            lastRunResult = "settings"
            context.services[.settingsWindow].showSettings(paneID: paneID)
        case .profile(let id):
            if !stays { close(.ran) }
            do {
                try context.services[.profiles].applyProfile(id: id)
                lastRunResult = "applied"
            } catch {
                report(error, title: row.title)
            }
        case .command(let invocation):
            if !stays { close(.ran) }
            runAsync(title: row.title) { [context] in
                try await context.commands.run(invocation.id, arguments: invocation.arguments, source: .palette)
            }
        case .provided(let action):
            if !stays { close(.ran) }
            runAsync(title: row.title, action)
        }
    }

    /// A row's second action (⌘Return): same usage entry and error message as the row, but it
    /// always closes the panel first, also when "close after running" is off, and waits (at
    /// most 0.5 s) until the app the user was in is active again: the action works on that
    /// app (a paste), and nothing else guarantees it is frontmost while the panel is open.
    private func runSecond(_ secondAction: PaletteAlternateAction, of row: PaletteRow) {
        usage.record(row.id)
        runCount += 1
        lastRun = "\(row.id) (second: \(secondAction.title))"
        lastRunResult = nil
        log.info("run the second action of a \(row.kind) row")
        close(.ran, animated: false)
        let waits = presentsOnScreen
        runAsync(title: row.title) {
            if waits { await Self.waitUntilRolltopIsInactive(timeout: .milliseconds(500)) }
            try await secondAction.action()
        }
    }

    /// The coordinator hands activation back to the previous app when the panel closes; that
    /// takes a moment. When Rolltop stays active (its settings window was frontmost before the
    /// panel opened), the action runs once the timeout has passed.
    private static func waitUntilRolltopIsInactive(timeout: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while NSApp.isActive, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A destructive command (`Command.effect`) runs only when chosen twice in a row.
    private func needsConfirmation(_ row: PaletteRow) -> Bool {
        guard case .command(let invocation) = row.action, pendingConfirmation != row.id else { return false }
        return context.commands.command(invocation.id)?.resolvedEffect == .destructive
    }

    private func runAsync(title: String, _ action: @escaping @MainActor () async throws -> Void) {
        Task { [weak self] in
            do {
                try await action()
                self?.lastRunResult = "done"
            } catch {
                self?.report(error, title: title)
            }
        }
    }

    /// A failed run: a note in the footer while the panel is open, else a short message
    /// where the panel was.
    private func report(_ error: Error, title: String) {
        guard let message = Self.message(for: error, title: title) else { return }
        lastRunResult = "error: \(error.localizedDescription)"
        log.error("run failed: \(error.localizedDescription)")
        if isVisible {
            model.message = message
        } else {
            let anchor = lastPanelTopCenter ?? CGPoint(x: NSScreen.main?.frame.midX ?? 720, y: NSScreen.main?.visibleFrame.maxY ?? 800)
            toast.show(message, topCenter: anchor)
        }
    }

    /// What the user reads when a row fails; nil when nothing needs saying (superseded).
    static func message(for error: Error, title: String) -> String? {
        if error is CancellationError { return nil }
        if let activation = error as? ItemActivator.ActivationError {
            switch activation {
            case .accessibilityDenied:
                return String(localized: "Rolltop needs Device Control and Data Access to open menu bar items.", table: "CommandPalette")
            case .notDrawn:
                return String(localized: "\(title) did not appear in the menu bar. There may be no room for it.", table: "CommandPalette")
            case .notRunning:
                return String(localized: "\(title) is not running.", table: "CommandPalette")
            case .notAssignable, .noPressTarget:
                return String(localized: "\(title) cannot be opened from Rolltop.", table: "CommandPalette")
            }
        }
        return String(localized: "\(title) failed: \(error.localizedDescription)", table: "CommandPalette")
    }

    private func openShortcutSettings() {
        close(.openedWindow, animated: false)
        context.services[.settingsWindow].showSettings(paneID: PaletteCommandIDs.shortcutsPaneID)
    }

    // MARK: Dismissal

    private func startMonitoring() {
        stopMonitoring()
        let mouseDowns: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDowns, handler: { [weak self] event in
            // Rolltop's own synthetic clicks are not the user clicking away (CONTRACTS.md).
            if let cgEvent = event.cgEvent, EventSynthesizer.isSynthesized(cgEvent) { return }
            self?.close(.clickOutside)
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mouseDowns, handler: { [weak self] event in
            if let self, event.window !== self.panel { self.close(.clickOutside) }
            return event
        }) { monitors.append(monitor) }
        let center = NotificationCenter.default
        let resign = center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(.resignedKey) }
        }
        notificationObservers.append((center, resign))
        let workspace = NSWorkspace.shared.notificationCenter
        let space = workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(.spaceChanged) }
        }
        notificationObservers.append((workspace, space))
    }

    private func stopMonitoring() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        for (center, observer) in notificationObservers { center.removeObserver(observer) }
        notificationObservers.removeAll()
    }

    func stop() {
        close(.api, animated: false)
        toast.hide()
    }

    // MARK: Debug

    struct Snapshot: Codable {
        struct Row: Codable {
            var id: String
            var kind: String
            var title: String
            var subtitle: String?
            var tag: String?
            var tier: String?
            /// Title of the row's ⌘Return action.
            var secondAction: String?
        }

        var writtenAt: Date
        var visible: Bool
        var isKeyWindow: Bool
        var fieldIsFirstResponder: Bool
        var appIsActive: Bool
        var appActiveWhileShown: Bool?
        var keyWhileShown: Bool?
        var frontmostAtShow: String?
        var frontmostAtClose: String?
        var frontmostNow: String?
        /// AppKit coordinates (bottom-left origin).
        var appKitFrame: CGRect?
        /// Global top-left points: `screencapture -R x,y,w,h`.
        var captureRect: CGRect?
        var screen: CGRect?
        var panelWindowNumber: Int?
        var rolltopWindowsOnScreen: Int
        var query: String
        var selected: Int?
        var hovered: Int?
        var rowCount: Int
        var rows: [Row]
        var message: String?
        var toast: String?
        var showCount: Int
        var runCount: Int
        var lastCloseReason: String?
        var lastRun: String?
        var lastRunResult: String?
        var usageEntries: Int
        var shortcut: String?
        var appearance: String?
        var pendingConfirmation: String?
    }

    func snapshot() -> Snapshot {
        let frame = isVisible ? panel?.frame : nil
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let panelNumber = panel.map { CGWindowID($0.windowNumber) }
        let rolltopWindows = WindowList.onScreen().filter { $0.ownerPID == ownPID && $0.layer == Int(NSWindow.Level.statusBar.rawValue) }
        let screen = frame.flatMap { frame in NSScreen.screens.first { $0.frame.intersects(frame) } }
        return Snapshot(
            writtenAt: Date(), visible: isVisible, isKeyWindow: panel?.isKeyWindow ?? false,
            fieldIsFirstResponder: panel?.isFieldFocused ?? false, appIsActive: NSApp.isActive,
            appActiveWhileShown: appActiveWhileShown, keyWhileShown: keyWhileShown,
            frontmostAtShow: frontmostAtShow, frontmostAtClose: frontmostAtClose,
            frontmostNow: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            appKitFrame: frame, captureRect: frame.map(ScreenGeometry.topLeftRect(fromAppKit:)), screen: screen?.frame,
            panelWindowNumber: panelNumber.map(Int.init),
            rolltopWindowsOnScreen: rolltopWindows.count,
            query: model.query, selected: model.selected, hovered: model.hovered, rowCount: model.results.count,
            rows: model.results.prefix(40).enumerated().map { index, row in
                Snapshot.Row(id: row.id, kind: "\(row.kind)", title: row.title, subtitle: row.subtitle, tag: row.tag,
                             tier: model.tiers.indices.contains(index) ? model.tiers[index].map(\.description) : nil,
                             secondAction: row.secondAction?.title)
            },
            message: model.message, toast: toast.message, showCount: showCount, runCount: runCount,
            lastCloseReason: lastCloseReason?.rawValue, lastRun: lastRun, lastRunResult: lastRunResult,
            usageEntries: usage.usage.entries.count, shortcut: model.shortcut,
            appearance: (panel?.appearance ?? debugAppearance)?.name.rawValue, pendingConfirmation: pendingConfirmation)
    }

    /// Hands a key event straight to the panel, as if typed (Debug commands, tests).
    func deliverKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], characters: String = "") {
        guard let panel else { return }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                     context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                     isARepeat: false, keyCode: keyCode)
        if let event { panel.sendEvent(event) }
    }
}

/// Command ids of this feature and the ids it refers to elsewhere.
enum PaletteCommandIDs {
    static let toggle: CommandID = "palette.toggle"
    static let show: CommandID = "palette.show"
    static let clearHistory: CommandID = "palette.clear-history"
    /// The Hotkeys feature's settings pane (where the user assigns the palette's shortcut).
    static let shortcutsPaneID = "hotkeys"
    /// This feature's settings pane.
    static let paneID = "palette"
}
