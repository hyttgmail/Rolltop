import AppKit
import Foundation
import Observation
import RolltopCore

private let log = Log.logger("appearance")

/// What one display's overlay is doing, for the pane and the debug dump.
struct AppearanceDisplayState: Equatable {
    var identity: DisplayIdentity
    /// Global top-left; nil when the display shows no menu bar right now.
    var barFrame: CGRect?
    var notch: ClosedRange<CGFloat>?
    var appMenusMaxX: CGFloat?
    var statusItemsMinX: CGFloat?
    var appearance: MenuBarAppearanceProbe.Reading
    var shape: BarShape?
    var segments: [BarSegment]
    var isShown: Bool
    var hiddenReason: String?
    var windowNumber: Int?
    /// The Space whose style applies (nil: Spaces unavailable).
    var spaceID: String?
}

/// Runs the overlays. While no display gets a style (styling off, or every style is
/// "system") it holds nothing but one settings observer: no windows, timers, AX reads or
/// notification observers.
@Observable
final class AppearanceController {
    private(set) var systemSettings = MenuBarSystemSettings.read()
    private(set) var isRunning = false
    private(set) var displayStates: [AppearanceDisplayState] = []

    @ObservationIgnored private unowned let context: AppContext
    @ObservationIgnored let store: AppearanceStore
    @ObservationIgnored private var settingsObserver: ChangeObserver?
    @ObservationIgnored private var drawnObserver: ChangeObserver?
    @ObservationIgnored private var appsObserver: ChangeObserver?
    @ObservationIgnored private var allowObserver: ChangeObserver?
    @ObservationIgnored private var drawnBurst: Task<Void, Never>?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var overlays: [CGDirectDisplayID: BarOverlay] = [:]
    @ObservationIgnored private var barFrames: [CGDirectDisplayID: CGRect] = [:]
    @ObservationIgnored private var menuExtents: [CGDirectDisplayID: CGFloat] = [:]
    @ObservationIgnored private var menuTask: Task<Void, Never>?
    @ObservationIgnored private var windowTask: Task<Void, Never>?
    @ObservationIgnored private var isAsleep = false
    /// Display key → current Space id, read from the window server (empty: unavailable).
    @ObservationIgnored private(set) var currentSpaces: [String: String] = [:]
    /// Debug: display key → Space id that stands in for the current one.
    @ObservationIgnored var simulatedSpaces: [String: String] = [:] {
        didSet { reconcile() }
    }
    @ObservationIgnored private let corners = AppearanceCornerOverlays()

    init(context: AppContext, store: AppearanceStore) {
        self.context = context
        self.store = store
    }

    func start() {
        settingsObserver = ChangeObserver(track: { [weak self] in
            _ = self?.store.configuration
            _ = self?.store.spaceStyles
            _ = self?.store.corners
        }) { [weak self] in
            self?.reconcile()
        }
        reconcile()
    }

    func stop() {
        settingsObserver?.cancel()
        settingsObserver = nil
        stopEnvironment()
    }

    /// Starts or stops everything to match the stored configuration.
    func reconcile() {
        let keys = NSScreen.screens.compactMap(\.rolltopDisplayIdentity?.key)
        refreshSpaces()
        guard spaceResolver.drawsAnything(on: keys) || store.corners.drawsAny else {
            if isRunning { stopEnvironment() }
            return
        }
        if !isRunning { startEnvironment() }
        layout(animated: true)
        // Switching to the split shape needs the app-menu extents now, not at the next tick.
        if menuExtents.isEmpty { scheduleMenuRead(followUp: false) }
    }

    // MARK: Environment

    private func startEnvironment() {
        isRunning = true
        log.info("styling on: starting overlays")
        systemSettings = MenuBarSystemSettings.read()
        barFrames = Self.barFrames(windows: WindowList.onScreen())
        refreshSpaces()

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.environmentChanged() }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { $0.scheduleMenuRead(followUp: true) }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.setAsleep(true) }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.setAsleep(true) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.setAsleep(false) }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.setAsleep(false) }
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { controller in
            controller.systemSettings = MenuBarSystemSettings.read()
            controller.layout(animated: false)
        }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { $0.environmentChanged() }
        observe(DistributedNotificationCenter.default(), Notification.Name("AppleInterfaceThemeChangedNotification")) {
            $0.layout(animated: true)
        }
        drawnObserver = ChangeObserver(track: { [weak self] in _ = self?.context.catalog.drawn }) { [weak self] in
            self?.layout(animated: true)
        }
        // Items come and go when apps launch or quit and when the allow-list changes; the
        // catalog's own refresh follows 0.3-0.7 s later, so the status pill reads sooner.
        appsObserver = ChangeObserver(track: { [weak self] in _ = self?.context.catalog.runningApps }) { [weak self] in
            // A quit app's slot lingers in list B: lay out now with it discounted.
            self?.layout(animated: true)
            self?.burstDrawnRefresh()
        }
        allowObserver = ChangeObserver(track: { [weak self] in _ = self?.context.visibility.appliedAllowList }) { [weak self] in
            self?.burstDrawnRefresh()
        }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        scheduleMenuRead(followUp: false)
    }

    private func stopEnvironment() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        drawnObserver?.cancel()
        drawnObserver = nil
        appsObserver?.cancel()
        appsObserver = nil
        allowObserver?.cancel()
        allowObserver = nil
        drawnBurst?.cancel()
        timer?.invalidate()
        timer = nil
        menuTask?.cancel()
        windowTask?.cancel()
        for overlay in overlays.values { overlay.close() }
        overlays.removeAll()
        corners.closeAll()
        menuExtents.removeAll()
        barFrames.removeAll()
        displayStates = []
        isAsleep = false
        if isRunning { log.info("styling off: overlays removed") }
        isRunning = false
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (AppearanceController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                handler(self)
            }
        }
        observers.append((center, token))
    }

    private func setAsleep(_ asleep: Bool) {
        guard isAsleep != asleep else { return }
        isAsleep = asleep
        log.info(asleep ? "displays asleep: hiding overlays" : "displays awake")
        if asleep { layout(animated: false) } else { environmentChanged() }
    }

    /// Screens, Spaces or wake: re-read where the bars are, then lay out without animation.
    private func environmentChanged() {
        barFrames = Self.barFrames(windows: WindowList.onScreen())
        refreshSpaces()
        layout(animated: false)
        scheduleMenuRead(followUp: true)
    }

    private func tick() {
        tickCount += 1
        let settings = MenuBarSystemSettings.read()
        if settings != systemSettings { systemSettings = settings }
        // A missed Space notification is caught here.
        if refreshSpaces() { layout(animated: false) }
        refreshBarFrames()
        if needsLiveExtents, tickCount % 2 == 0 {
            scheduleMenuRead(followUp: false)
            let catalog = context.catalog
            Task { await catalog.refreshDrawn() }
        }
    }

    /// Re-reads MenuBarAgent's slots a few times shortly after a change (split shape only).
    private func burstDrawnRefresh() {
        guard isRunning, needsLiveExtents else { return }
        drawnBurst?.cancel()
        let catalog = context.catalog
        drawnBurst = Task {
            for delay in [120, 200, 300, 400] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                await catalog.refreshDrawn()
            }
        }
    }

    /// Reads the window list off the main thread, then lays out (also picks up appearance changes).
    private func refreshBarFrames() {
        guard windowTask == nil else { return }
        windowTask = Task { [weak self] in
            let windows = await Task.detached(priority: .utility) { WindowList.onScreen() }.value
            guard let self else { return }
            self.windowTask = nil
            guard self.isRunning, !Task.isCancelled else { return }
            let frames = Self.barFrames(windows: windows)
            let changed = frames != self.barFrames
            self.barFrames = frames
            self.layout(animated: !changed)
        }
    }

    private static func barFrames(windows: [WindowInfo]) -> [CGDirectDisplayID: CGRect] {
        var frames: [CGDirectDisplayID: CGRect] = [:]
        for display in DisplayGeometry.current() {
            if let frame = MenuBarWindows.barFrame(displayBounds: display.bounds, windows: windows) {
                frames[display.displayID] = frame
            }
        }
        return frames
    }

    /// Whether some display uses the split shape (needs app-menu and status extents).
    private var needsLiveExtents: Bool {
        let config = spaceResolver
        return NSScreen.screens.compactMap(\.rolltopDisplayIdentity).contains { config.style(forDisplay: $0.key)?.shape == .split }
    }

    /// Reads where the app menus end on every bar. With `followUp`, reads again shortly after:
    /// some apps finish their menus after they activate.
    private func scheduleMenuRead(followUp: Bool) {
        guard isRunning, needsLiveExtents, context.permissions.accessibility else { return }
        menuTask?.cancel()
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier
        let own = ProcessInfo.processInfo.processIdentifier
        let displays = DisplayGeometry.current()
        menuTask = Task { [weak self] in
            for pass in 0..<(followUp ? 2 : 1) {
                if pass > 0 { try? await Task.sleep(for: .milliseconds(400)) }
                guard !Task.isCancelled else { return }
                let read = await AXInventory.onQueue {
                    AppMenuExtents.readAll(frontmostPID: front, finderPID: finder, ownPID: own, displays: displays)
                }
                guard !Task.isCancelled, let self, self.isRunning else { return }
                // Keep earlier values for bars this pass could not measure (Rolltop frontmost, timeout).
                var merged = self.menuExtents
                for (id, value) in read { merged[id] = value }
                if merged != self.menuExtents {
                    self.menuExtents = merged
                    self.layout(animated: true)
                }
            }
        }
    }

    // MARK: Layout

    private func layout(animated: Bool) {
        guard isRunning else { return }
        let config = spaceResolver
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var seen = Set<CGDirectDisplayID>()
        var states: [AppearanceDisplayState] = []
        for screen in NSScreen.screens {
            guard let identity = screen.rolltopDisplayIdentity else { continue }
            let id = identity.displayID
            seen.insert(id)
            let style = config.style(forDisplay: identity.key)
            let displayBounds = CGDisplayBounds(id)
            let barFrame = barFrames[id]
            let reading = MenuBarAppearanceProbe.reading(for: screen, excluding: context.services[.ownStatusItems].hiddenItemWindows)
            let notch = AppearanceBarGeometry.notchRange(screenMinX: screen.frame.minX,
                                               auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
                                               auxiliaryTopRight: screen.auxiliaryTopRightArea)
            let statusMinX = statusItemsMinX(displayID: id, displayMinX: displayBounds.minX)
            let menusMaxX = menuExtents[id]

            var hiddenReason: String?
            if style == nil {
                hiddenReason = "system style"
            } else if systemSettings.showsBackground {
                hiddenReason = "menu bar background is on"
            } else if systemSettings.hidesAutomatically {
                hiddenReason = "menu bar hides automatically"
            } else if isAsleep {
                hiddenReason = "displays asleep"
            } else if barFrame == nil {
                hiddenReason = "no menu bar on this display (full screen or hidden)"
            }

            var segments: [BarSegment] = []
            if let style, let barFrame, hiddenReason == nil {
                let input = BarLayoutInput(barSize: barFrame.size, notch: notch, appMenusMaxX: menusMaxX,
                                           statusItemsMinX: statusMinX, shape: style.shape,
                                           splitAroundNotch: style.splitAroundNotch, cornerRadius: style.cornerRadius)
                segments = AppearanceBarGeometry.segments(input)
                let overlay = overlays[id] ?? BarOverlay(displayID: id)
                overlays[id] = overlay
                overlay.update(barFrame: ScreenGeometry.appKitRect(fromTopLeft: barFrame),
                               margin: AppearanceBarGeometry.shadowMargin(style.shadow), segments: segments, style: style,
                               appearance: reading.appearance, animate: animated && !reduceMotion)
            } else if style == nil {
                overlays.removeValue(forKey: id)?.close()
            } else {
                overlays[id]?.hide()
            }
            states.append(AppearanceDisplayState(identity: identity, barFrame: barFrame, notch: notch,
                                                 appMenusMaxX: menusMaxX, statusItemsMinX: statusMinX,
                                                 appearance: reading, shape: style?.shape, segments: segments,
                                                 isShown: overlays[id]?.isShown ?? false, hiddenReason: hiddenReason,
                                                 windowNumber: overlays[id]?.windowNumber,
                                                 spaceID: config.currentSpaces[identity.key]))
        }
        layoutCorners()
        for (id, overlay) in overlays where !seen.contains(id) {
            overlay.close()
            overlays[id] = nil
        }
        if states != displayStates { displayStates = states }
    }

    private func statusItemsMinX(displayID: CGDirectDisplayID, displayMinX: CGFloat) -> CGFloat? {
        guard let bar = context.catalog.drawn.displays.first(where: { $0.displayID == displayID }) else { return nil }
        // Process liveness, not catalog.runningApps: that list skips XPC services and extensions.
        let slots = bar.slots.map { slot in
            StatusExtent.Slot(frame: slot.frame, isOverflowed: slot.isOverflowed,
                              isLive: slot.ownerPID.map { kill($0, 0) == 0 || errno == EPERM } ?? true)
        }
        return StatusExtent.minX(slots: slots, chevron: bar.chevronFrame, displayMinX: displayMinX)
    }

    // MARK: Spaces and corners

    /// The configuration with each display's current (or simulated) Space.
    private var spaceResolver: AppearanceSpaceResolver {
        AppearanceSpaceResolver(configuration: store.configuration, spaceStyles: store.spaceStyles,
                                currentSpaces: currentSpaces.merging(simulatedSpaces) { _, simulated in simulated })
    }

    /// Re-reads each display's current Space; true when it changed.
    @discardableResult
    private func refreshSpaces() -> Bool {
        var current: [String: String] = [:]
        if let lists = ManagedSpaces.read() {
            for key in NSScreen.screens.compactMap(\.rolltopDisplayIdentity?.key) {
                if let id = ManagedSpaces.spaces(forDisplay: key, in: lists)?.currentID { current[key] = id }
            }
        }
        guard current != currentSpaces else { return false }
        currentSpaces = current
        return true
    }

    private func layoutCorners() {
        let settings = store.corners
        guard settings.drawsAny, !isAsleep else {
            corners.closeAll()
            return
        }
        let placements = NSScreen.screens.flatMap { screen in
            AppearanceCornerGeometry.placements(screenFrame: screen.frame,
                                                stripHeight: screen.frame.maxY - screen.visibleFrame.maxY,
                                                corners: settings)
        }
        corners.update(placements)
    }

    var cornerPanels: [AppearanceCornerPanel] { corners.shownPanels }

    /// Window numbers of the overlays on screen (debug, tests).
    var overlayWindowNumbers: [Int] { overlays.values.filter(\.isShown).map(\.windowNumber) }
}
