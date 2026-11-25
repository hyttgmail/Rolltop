import AppKit
import RolltopCore

/// The image of Rolltop's own status item, chosen in Settings › General
/// (`rolltop.general.status-icon`, exported with the other settings). Every choice has a
/// collapsed and a revealed image of the same width, so the bar does not shift on toggle.
enum StatusItemIcon: String, CaseIterable, Sendable {
    case slats, stack, box, dots, chevron, eye

    static let `default` = StatusItemIcon.slats
    static let setting = SettingsKey<String>("rolltop.general.status-icon", default: StatusItemIcon.default.rawValue)

    /// The stored choice; anything unknown (an older or newer value) means the default.
    init(settingValue: String) { self = StatusItemIcon(rawValue: settingValue) ?? .default }

    /// SF Symbols (collapsed, revealed), or the asset catalog's template glyphs drawn from
    /// the app icon's slats (scripts/icon/make-icon.swift) for `slats`, which Settings
    /// calls "Rolltop".
    var imageNames: (collapsed: String, revealed: String, isSymbol: Bool) {
        switch self {
        case .slats: ("StatusSlatsCollapsed", "StatusSlatsRevealed", false)
        case .stack: ("square.stack.3d.up", "square.stack.3d.up.fill", true)
        case .box: ("shippingbox", "shippingbox.fill", true)
        case .dots: ("ellipsis.circle", "ellipsis.circle.fill", true)
        case .chevron: ("chevron.left.circle", "chevron.right.circle.fill", true)
        case .eye: ("eye.slash", "eye", true)
        }
    }

    /// The template image for one state, or nil when this system lacks it.
    func image(revealed: Bool) -> NSImage? {
        let names = imageNames
        let name = revealed ? names.revealed : names.collapsed
        let image = names.isSymbol
            ? NSImage(systemSymbolName: name, accessibilityDescription: String(localized: "Rolltop"))
            : NSImage(named: name)?.copy() as? NSImage
        image?.isTemplate = true
        if !names.isSymbol { image?.accessibilityDescription = String(localized: "Rolltop") }
        return image
    }

    /// Never empty: the choice, else the bundled default glyph, else an SF Symbol.
    func resolvedImage(revealed: Bool) -> NSImage? {
        image(revealed: revealed) ?? Self.default.image(revealed: revealed) ?? Self.stack.image(revealed: revealed)
    }
}

/// Whether Rolltop's own icon is in the menu bar: Settings › General "Show Rolltop in the menu
/// bar" (`rolltop.general.show-status-item`, exported with the other settings) and the
/// `app.toggle-menu-bar-icon` command. Only the main icon follows it; custom items
/// (spacers, groups, widgets) stay as they are. The setting is the truth: the status item
/// controller applies it with `isVisible` (never removing the item, PLATFORM §7), and when
/// the user ⌘-drags the icon out of the bar the setting follows.
///
/// Ways back while it is hidden: opening Rolltop again (`applicationShouldHandleReopen`), a
/// cold start that is not a login launch (`StatusItemLaunch`), the shortcuts of
/// `app.settings` and of the toggle, and the link `rolltop://settings` (subject to the link
/// policy in Settings › Integrations).
enum StatusItemVisibility {
    static let setting = SettingsKey<Bool>("rolltop.general.show-status-item", default: true)
    static let toggleCommand: CommandID = "app.toggle-menu-bar-icon"

    /// Writes the setting as the pane and the command do. Shown is the default, so showing
    /// the icon removes the key rather than storing `true`; an unchanged value writes nothing.
    static func set(_ shown: Bool, in settings: SettingsStore) {
        if shown {
            guard settings.hasValue(for: setting) else { return }
            settings.reset(setting)
        } else {
            guard settings[setting] || !settings.hasValue(for: setting) else { return }
            settings[setting] = false
        }
    }

    /// Reveal's gesture settings (Features/Reveal/RevealSettings.swift), read by name so the
    /// General pane can tell whether hidden items can still be shown without Rolltop's icon.
    /// `StatusItemVisibilityTests` checks the names and defaults against Reveal's keys.
    static let revealGestureKeys: [(name: String, defaultValue: Bool)] = [
        ("rolltop.reveal.click-empty", true), ("rolltop.reveal.hover", false), ("rolltop.reveal.scroll", false),
    ]

    /// The commands that show hidden items; a shortcut on any of them is a way to show them.
    static let showHiddenCommands: [CommandID] = [.toggleHidden, .showHidden, .toggleAll, .showAll]

    /// Whether any enabled gesture or shortcut still shows hidden items when the icon is
    /// hidden. `gestures`: Reveal's click-on-empty-bar, hover and scroll switches.
    static func hasWayToShowHiddenItems(gestures: [Bool], shortcutCount: Int) -> Bool {
        gestures.contains(true) || shortcutCount > 0
    }

    /// Reads `revealGestureKeys` from Rolltop's defaults (tracked through `settings.revision`).
    static func revealGestures(in settings: SettingsStore) -> [Bool] {
        _ = settings.revision
        return revealGestureKeys.map { settings.defaults.object(forKey: $0.name) as? Bool ?? $0.defaultValue }
    }
}

/// What `StatusItemVisibilitySync` needs from an `NSStatusItem` (a fake in tests).
protocol StatusItemVisibilityTarget: AnyObject {
    var isVisible: Bool { get set }
}

extension NSStatusItem: StatusItemVisibilityTarget {}

/// Keeps `StatusItemVisibility.setting` and the main item's `isVisible` in step. The setting
/// wins at launch and whenever it changes (the pane, the command, Reset, an import, a
/// profile); when macOS hides the item itself (the user ⌘-dragged it out of the bar, which
/// `.removalAllowed` permits and which sets `isVisible` to false through KVO), the setting
/// follows, so Settings always shows the truth. Stops before quitting, so nothing AppKit
/// does to the item during teardown is written back.
final class StatusItemVisibilitySync {
    private let settings: SettingsStore
    private weak var item: (any StatusItemVisibilityTarget)?
    private var isApplying = false
    private(set) var isStopped = false
    private let log = Log.logger("status-item")

    init(settings: SettingsStore, item: any StatusItemVisibilityTarget) {
        self.settings = settings
        self.item = item
    }

    /// Shows or hides the item as the setting says.
    func applySetting() {
        guard !isStopped, let item else { return }
        let shown = settings[StatusItemVisibility.setting]
        guard item.isVisible != shown else { return }
        log.notice("menu bar icon \(shown ? "shown" : "hidden") by the setting")
        isApplying = true
        item.isVisible = shown
        isApplying = false
    }

    /// The item's `isVisible` changed (KVO). Our own writes and changes after `stop()` are ignored.
    func itemVisibilityChanged(to visible: Bool) {
        guard !isStopped, !isApplying, settings[StatusItemVisibility.setting] != visible else { return }
        log.notice("menu bar icon \(visible ? "shown" : "removed") outside Rolltop; the setting follows")
        StatusItemVisibility.set(visible, in: settings)
    }

    func stop() { isStopped = true }
}

/// Whether a cold start opens Settings because Rolltop's icon is hidden. A start by the user
/// (Finder, Spotlight, `open`, a shell) does; a start as a login item and a start by a link
/// (the link does what it asks) do not.
///
/// Telling a login launch apart: macOS marks the `oapp` Apple event of a login item with
/// `keyAEPropData = keyAELaunchedAsLogInItem` (what `SMAppService` login items are known to
/// carry; not measured on 27, it needs a logout). As a fallback, a LaunchServices start
/// within `loginGracePeriod` of the console login counts as a login launch too, so when in
/// doubt Settings stays closed (opening Rolltop again still shows it).
nonisolated enum StatusItemLaunch {
    enum Trigger: String, Sendable {
        /// Started from a shell (inherits the terminal; developer runs and live tests).
        case shell
        /// Started through LaunchServices by the user: Finder, Spotlight, `open`.
        case user
        /// A login item, or a LaunchServices start right after login.
        case login
        /// A `rolltop://` link started Rolltop.
        case link
    }

    static let loginGracePeriod: TimeInterval = 120

    static func trigger(launchedByLaunchServices: Bool, loginItemMarker: Bool, linkQueued: Bool,
                                    secondsSinceLogin: TimeInterval?) -> Trigger {
        if linkQueued { return .link }
        if loginItemMarker { return .login }
        guard launchedByLaunchServices else { return .shell }
        if let age = secondsSinceLogin, age >= 0, age < loginGracePeriod { return .login }
        return .user
    }

    static func opensSettings(iconShown: Bool, trigger: Trigger) -> Bool {
        !iconShown && (trigger == .user || trigger == .shell)
    }

    /// The `oapp` event of a login item carries `keyAEPropData = keyAELaunchedAsLogInItem`.
    static func isLoginItemEvent(eventClass: UInt32?, eventID: UInt32?, propData: UInt32?) -> Bool {
        eventClass == UInt32(kCoreEventClass) && eventID == UInt32(kAEOpenApplication)
            && propData == UInt32(keyAELaunchedAsLogInItem)
    }

    /// When the current user last logged in at the console (utmpx), nil when unknown.
    static func consoleLoginDate(user: String = NSUserName()) -> Date? {
        setutxent()
        defer { endutxent() }
        var latest: Date?
        while let pointer = getutxent() {
            let entry = pointer.pointee
            guard entry.ut_type == USER_PROCESS else { continue }
            let line = withUnsafeBytes(of: entry.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let name = withUnsafeBytes(of: entry.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard line == "console", name == user else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(entry.ut_tv.tv_sec) + TimeInterval(entry.ut_tv.tv_usec) / 1_000_000)
            latest = max(latest ?? date, date)
        }
        return latest
    }
}

/// Rolltop's own status item. Left click toggles hidden items, Option-click toggles all
/// items, right click (or Control-click) shows the menu. The icon and the "Show Hidden
/// Items" checkmark follow the reveal router (`isHiddenPresented`: the Rolltop Bar counts).
/// Whether it is in the menu bar follows `StatusItemVisibility.setting`.
final class StatusItemController: NSObject, NSMenuDelegate {
    /// Fixed so macOS keeps the item's position and visibility across launches.
    static let autosaveName = "rolltop.main"

    private let visibility: VisibilityEngine
    private let commands: CommandRegistry
    private let catalog: ItemCatalog
    private let services: ServiceLocator
    private let settings: SettingsStore
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var stateObserver: ChangeObserver?
    private var visibilitySync: StatusItemVisibilitySync?
    private var visibilityTarget: NSObject?
    private let log = Log.logger("status-item")
    nonisolated private static let visibleKeyPath = "visible"

    init(visibility: VisibilityEngine, commands: CommandRegistry, catalog: ItemCatalog, services: ServiceLocator,
         settings: SettingsStore) {
        self.visibility = visibility
        self.commands = commands
        self.catalog = catalog
        self.services = services
        self.settings = settings
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    /// Call after the run loop started (applicationDidFinishLaunching).
    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.autosaveName
        item.behavior = [.removalAllowed]
        if let button = item.button {
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel(String(localized: "Rolltop"))
        }
        statusItem = item
        services[.ownStatusItems].register(item, id: OwnStatusItemRegistry.mainID)
        // AppKit restored `isVisible` from the autosave name above; the setting wins, then
        // removals by the user (⌘-drag) flow back into it.
        attachVisibility(to: item)
        log.info("menu bar icon \(item.isVisible ? "shown" : "hidden") at launch")
        updateIcon()
        registerDebugCommands()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.log.debug("status item frame: AppKit \(self.appKitButtonFrame.map { "\($0)" } ?? "nil"), resolved \(self.buttonFrame.map { "\($0)" } ?? "nil")")
        }
    }

    /// Follows the reveal router. Call once every feature has registered its services: the
    /// router is resolved inside the tracking closure, so a replacement registered later
    /// would otherwise go unobserved until the next level change.
    func observeState() {
        stateObserver = ChangeObserver(track: { [weak self] in
            guard let self else { return }
            _ = self.visibility.level
            _ = self.services[.revealRouting].isHiddenPresented
            _ = self.settings[StatusItemIcon.setting]
            _ = self.settings[StatusItemVisibility.setting]
        }) { [weak self] in
            self?.visibilitySync?.applySetting()
            self?.updateIcon()
        }
        visibilitySync?.applySetting()
        updateIcon()
    }

    /// Applies the setting to `target` (the main item; a fake in tests) and follows its
    /// KVO-observable `visible` back into the setting.
    func attachVisibility(to target: NSObject & StatusItemVisibilityTarget) {
        let sync = StatusItemVisibilitySync(settings: settings, item: target)
        visibilitySync = sync
        sync.applySetting()
        target.addObserver(self, forKeyPath: Self.visibleKeyPath, options: [.new], context: nil)
        visibilityTarget = target
    }

    /// Before quitting: nothing AppKit does to the item during teardown reaches the setting.
    func stopObserving() {
        visibilitySync?.stop()
        stateObserver = nil
        visibilityTarget?.removeObserver(self, forKeyPath: Self.visibleKeyPath)
        visibilityTarget = nil
    }

    /// KVO on the item's `visible`: AppKit sets it to false when the user ⌘-drags the icon out.
    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == Self.visibleKeyPath else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        let visible = (change?[.newKey] as? Bool) ?? true
        if Thread.isMainThread {
            MainActor.assumeIsolated { self.visibilitySync?.itemVisibilityChanged(to: visible) }
        } else {
            Task { @MainActor in self.visibilitySync?.itemVisibilityChanged(to: visible) }
        }
    }

    private var isHiddenPresented: Bool { services[.revealRouting].isHiddenPresented }

    /// Whether the main icon is in the menu bar (the setting, and not removed by the user).
    var isShown: Bool { statusItem?.isVisible == true }

    /// The main icon's frame in global AppKit coordinates: AppKit's button window when it
    /// sits in a menu bar, else Rolltop's slot in MenuBarAgent's list B that is not one of
    /// Rolltop's other items (custom items); nil rather than another own item, and nil while
    /// the icon is hidden (callers fall back to the pointer or the bar's trailing end).
    var buttonFrame: CGRect? {
        let own = Bundle.main.bundleIdentifier
        let slots = catalog.drawn.displays.sorted { $0.isMain && !$1.isMain }.flatMap(\.slots)
            .filter { $0.ownerBundleID == own && !$0.isOverflowed }
            .map { ScreenGeometry.appKitRect(fromTopLeft: $0.frame) }
        return OwnStatusItemRegistry.mainFrame(appKit: statusItem.flatMap(OwnStatusItemRegistry.frame(of:)), ownSlots: slots,
                                               otherFrames: services[.ownStatusItems].otherItemFrames, mainVisible: isShown)
    }

    /// Where AppKit itself places the button (diagnostics).
    var appKitButtonFrame: CGRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func updateIcon() {
        let revealed = isHiddenPresented || visibility.level != .collapsed
        let choice = StatusItemIcon(settingValue: settings[StatusItemIcon.setting])
        var image = choice.image(revealed: revealed)
        if image == nil {
            log.error("menu bar icon \(choice.rawValue) has no \(revealed ? "revealed" : "collapsed") image here; using a fallback")
            image = choice.resolvedImage(revealed: revealed)
        }
        statusItem?.button?.image = image
    }

    /// `debug.set-status-icon icon=<stack|shelf|…>`: live tests switch the icon through the
    /// setting, as the General pane does (the default resets the key).
    private func registerDebugCommands() {
        #if DEBUG
        let settings = settings
        commands.register(Command(id: "debug.set-status-icon", title: "Set Menu Bar Icon", symbol: "menubar.rectangle",
                                  arguments: [CommandArgument(name: "icon", title: "Icon",
                                                              allowedValues: StatusItemIcon.allCases.map(\.rawValue))],
                                  allowedFromURL: true) { invocation in
            let raw = try invocation.require("icon")
            guard let icon = StatusItemIcon(rawValue: raw) else { throw CommandError.invalidArgument("icon", raw) }
            if icon == .default { settings.reset(StatusItemIcon.setting) } else { settings[StatusItemIcon.setting] = icon.rawValue }
        })
        // `debug.set-status-item visible=0|1 [direct=1]`: idempotent, through the setting (1
        // removes the key). `direct=1` writes the item's `isVisible` instead, as AppKit does
        // when the user ⌘-drags the icon out, so the KVO path has to carry it to the setting.
        commands.register(Command(id: "debug.set-status-item", title: "Show or Hide Menu Bar Icon", symbol: "menubar.rectangle",
                                  arguments: [CommandArgument(name: "visible", title: "Visible", allowedValues: ["0", "1"]),
                                              CommandArgument(name: "direct", title: "Direct", isRequired: false)],
                                  allowedFromURL: true) { [weak self] invocation in
            let visible = try invocation.require("visible") == "1"
            if invocation.string("direct") == "1" {
                self?.statusItem?.isVisible = visible
            } else {
                StatusItemVisibility.set(visible, in: settings)
            }
        })
        // `debug.dump-status-item [name=<file>.json]`: the icon's state and every frame user
        // (statusItemFrame, registry images, status bar windows) to DebugFiles.directory.
        commands.register(Command(id: "debug.dump-status-item", title: "Dump Menu Bar Icon", symbol: "ladybug",
                                  arguments: [CommandArgument(name: "name", title: "File", isRequired: false)],
                                  allowedFromURL: true) { [weak self] invocation in
            guard let self else { return }
            let name = invocation.string("name").flatMap { $0.isEmpty ? nil : $0 } ?? "status-item.json"
            guard name.hasSuffix(".json"), !name.contains("/") else { throw CommandError.invalidArgument("name", name) }
            try DebugFiles.writeJSON(self.debugDump(), name: name)
        })
        // `debug.nudge-layout [hold-ms=<n>] [length=<pt>]`: runs `OwnStatusItemRegistry.nudgeLayout()`
        // (optionally holding the nudged length longer so a probe can see it, or applying an
        // explicit length to calibrate) and writes `nudge-layout.json` with the result, the
        // items' lengths and frames before, during and after, and their button widths.
        commands.register(Command(id: "debug.nudge-layout", title: "Nudge Menu Bar Layout", symbol: "ladybug",
                                  arguments: [CommandArgument(name: "hold-ms", title: "Hold", isRequired: false),
                                              CommandArgument(name: "length", title: "Length", isRequired: false)],
                                  allowedFromURL: true) { [weak self] invocation in
            guard let self else { return }
            let hold = invocation.string("hold-ms").flatMap(Int.init).map { Duration.milliseconds(max(0, min($0, 3000))) }
                ?? OwnStatusItemRegistry.nudgeDuration
            let length = invocation.string("length").flatMap(Double.init).map { CGFloat($0) }
            let registry = self.services[.ownStatusItems]
            let items = registry.visibleItems
            @MainActor func frames() -> [DebugRect?] { items.map { OwnStatusItemRegistry.frame(of: $0).map(DebugRect.init) } }
            @MainActor func lengths() -> [Double] { items.map { Double($0.length) } }
            let before = frames(), lengthsBefore = lengths()
            let buttons = items.map { item in
                ButtonDump(frameWidth: Double(item.button?.frame.width ?? 0),
                           intrinsicWidth: Double(item.button?.intrinsicContentSize.width ?? 0),
                           fittingWidth: Double(item.button?.fittingSize.width ?? 0),
                           windowWidth: Double(item.button?.window?.frame.width ?? 0))
            }
            let nudged = registry.nudgeLayout(holdingFor: hold, length: length)
            let during = lengths()
            try? await Task.sleep(for: hold / 2)
            let framesDuring = frames()
            try? await Task.sleep(for: hold / 2 + .milliseconds(300))
            try DebugFiles.writeJSON(NudgeDump(nudged: nudged, buttons: buttons, framesBefore: before, lengthsBefore: lengthsBefore,
                                               lengthsDuringNudge: during, framesDuringNudge: framesDuring,
                                               framesAfter: frames(), lengthsAfter: lengths()),
                                     name: "nudge-layout.json")
        })
        #endif
    }

    #if DEBUG
    private struct DebugRect: Encodable {
        let x, y, width, height: Double
        init(_ rect: CGRect) { (x, y, width, height) = (rect.minX, rect.minY, rect.width, rect.height) }
    }

    private struct WindowDump: Encodable {
        let className: String
        let isVisible: Bool
        let isOnActiveSpace: Bool
        let occlusionVisible: Bool
        let frame: DebugRect
        let screen: String?
        let appearance: String
        let isMainItemWindow: Bool
    }

    private struct StatusItemDump: Encodable {
        let setting: Bool
        let settingStored: Bool
        let itemIsVisible: Bool?
        let statusItemFrame: DebugRect?
        let appKitButtonFrame: DebugRect?
        let registryItemCount: Int
        let registryMainVisible: Bool
        let mainImageWidth: Double?
        let statusBarWindows: [WindowDump]
        let ownSlots: [DebugRect]
    }

    private struct ButtonDump: Encodable {
        let frameWidth, intrinsicWidth, fittingWidth, windowWidth: Double
    }

    private struct NudgeDump: Encodable {
        let nudged: Bool
        let buttons: [ButtonDump]
        let framesBefore: [DebugRect?]
        let lengthsBefore: [Double]
        let lengthsDuringNudge: [Double]
        let framesDuringNudge: [DebugRect?]
        let framesAfter: [DebugRect?]
        let lengthsAfter: [Double]
    }

    private func debugDump() -> StatusItemDump {
        let registry = services[.ownStatusItems]
        let mainWindow = statusItem?.button?.window
        let windows = NSApp.windows.filter { NSStringFromClass(type(of: $0)).contains("StatusBarWindow") }.map { window in
            WindowDump(className: NSStringFromClass(type(of: window)), isVisible: window.isVisible,
                       isOnActiveSpace: window.isOnActiveSpace, occlusionVisible: window.occlusionState.contains(.visible),
                       frame: DebugRect(window.frame), screen: window.screen?.localizedName,
                       appearance: window.effectiveAppearance.name.rawValue, isMainItemWindow: window === mainWindow)
        }
        let own = Bundle.main.bundleIdentifier
        let slots = catalog.drawn.displays.flatMap(\.slots).filter { $0.ownerBundleID == own }.map { DebugRect($0.frame) }
        return StatusItemDump(setting: settings[StatusItemVisibility.setting], settingStored: settings.hasValue(for: StatusItemVisibility.setting),
                              itemIsVisible: statusItem?.isVisible, statusItemFrame: buttonFrame.map(DebugRect.init),
                              appKitButtonFrame: appKitButtonFrame.map(DebugRect.init), registryItemCount: registry.itemCount,
                              registryMainVisible: registry.mainItem?.isVisible == true,
                              mainImageWidth: registry.image(at: 0, height: 18).map { Double($0.size.width) },
                              statusBarWindows: windows, ownSlots: slots)
    }
    #endif

    @objc private func buttonClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        // MenuBarAgent forwards the click; read the live modifier state as well.
        let modifiers = (event?.modifierFlags ?? []).union(NSEvent.modifierFlags)
        log.debug("status item click: type \(event?.type.rawValue ?? 0), event modifiers \(event?.modifierFlags.rawValue ?? 0), live modifiers \(NSEvent.modifierFlags.rawValue)")
        if event?.type == .rightMouseUp || modifiers.contains(.control) {
            showMenu()
        } else if modifiers.contains(.option) {
            commands.runDetached(.toggleAll, source: .statusMenu)
        } else {
            commands.runDetached(.toggleHidden, source: .statusMenu)
        }
    }

    private func showMenu() {
        guard let statusItem else { return }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let hidden = NSMenuItem(title: String(localized: "Show Hidden Items"), action: #selector(toggleHidden), keyEquivalent: "")
        hidden.state = isHiddenPresented ? .on : .off
        let all = NSMenuItem(title: String(localized: "Show All Items"), action: #selector(toggleAll), keyEquivalent: "")
        all.state = visibility.level == .allRevealed ? .on : .off
        for item in [hidden, all] {
            item.target = self
            menu.addItem(item)
        }

        // One group per contributing feature, in registration order (StatusMenuGrouping).
        let available = commands.statusMenuCommands
        let groups = StatusMenuGrouping.groups(available.map {
            .init(feature: String($0.featurePrefix), id: $0.id.rawValue, showsIcon: $0.showsSymbolInMenu)
        }).map { group in group.compactMap { entry in available.first { $0.id.rawValue == entry.id } } }
        for group in groups {
            menu.addItem(.separator())
            for command in group {
                let item = NSMenuItem(title: command.localizedTitle, action: #selector(runCommand(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = command.id.rawValue
                item.state = (command.isOn?() ?? false) ? .on : .off
                if command.showsSymbolInMenu, let image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil) {
                    image.isTemplate = true
                    item.image = image
                    item.preferredImageVisibility = .visible
                } else {
                    item.preferredImageVisibility = .hidden
                }
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: String(localized: "Quit Rolltop"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        // macOS 27 adds its own symbols to standard items such as Settings…; only items that
        // identify an object show one here (DESIGN.md, Menus).
        for item in [hidden, all, settings, quit] { item.preferredImageVisibility = .hidden }
    }

    @objc private func toggleHidden() { commands.runDetached(.toggleHidden, source: .statusMenu) }
    @objc private func toggleAll() { commands.runDetached(.toggleAll, source: .statusMenu) }
    @objc private func openSettings() { commands.runDetached(.openSettings, source: .statusMenu) }
    @objc private func quit() { commands.runDetached(.quit, source: .statusMenu) }

    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        commands.runDetached(CommandID(raw), source: .statusMenu)
    }
}
