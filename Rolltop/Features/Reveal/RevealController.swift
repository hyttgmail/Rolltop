import AppKit
import Foundation
import RolltopCore

private let log = Log.logger("reveal")

/// The live side of Reveal: global event monitors for the triggers, the rehide timer,
/// "make room" and "hide everything". Decisions are delegated to the pure types
/// (`BarHitClassifier`, `ScrollGestureRecognizer`, `HoverDwell`, `RehideMachine`,
/// `RevealModes`); this class only feeds them and runs commands.
///
/// Primary actions go through the core commands (`visibility.toggle-hidden`,
/// `visibility.show-hidden`, `visibility.show-all`, `visibility.collapse`) with
/// `anchor=pointer` for pointer-driven triggers, so a presenter that reroutes them (the
/// secondary bar) works unchanged. Whether hidden items are up comes from the router
/// (`isHiddenPresented`: the Rolltop Bar counts); rehide and make room only concern the inline
/// presentation: they follow `visibility.level`, which a panel leaves at `.collapsed`.
final class RevealController {
    private unowned let context: AppContext

    // Pure state
    private var rehide = RehideMachine()
    private var scroll = ScrollGestureRecognizer()
    private var hover = HoverDwell(delay: 0.3)

    // Monitors and observers (installed only while needed)
    private var mouseMonitor: Any?
    private var moveMonitor: Any?
    private var scrollMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var settingsObserver: ChangeObserver?
    private var levelObserver: ChangeObserver?
    private var tickTask: Task<Void, Never>?
    private var hoverCheck: Task<Void, Never>?

    // Trigger bookkeeping
    private var pendingClick: PendingClick?
    private var pendingOrigin: (origin: RehideMachine.Origin, at: TimeInterval, location: CGPoint?)?
    private var lastToggleAt: TimeInterval = -.infinity
    private var lastLevel: PresentationLevel = .collapsed
    private var revealDisplayHasNotch = false
    private var strips: [RevealBarGeometry.Display] = []
    private var started = false
    private var lastHoverInBar = false
    private var lastBlockers = RehideMachine.Blockers()

    /// Recent decisions, newest last (Debug dump and logs).
    private(set) var recentEvents: [String] = []

    #if DEBUG
    /// Debug-only: replaces the rehide delay (seconds) for live tests.
    var rehideDelayOverride: TimeInterval?
    private var savedPins: [OwnerID]??
    #endif

    private struct PendingClick {
        var location: CGPoint
        var time: TimeInterval
        var allItems: Bool
        var classification: Task<BarHit, Never>
    }

    enum Tuning {
        static let tickInterval: Duration = .milliseconds(250)
        /// A click this long after the previous toggle is ignored (double clicks).
        static let toggleDebounce: TimeInterval = 0.35
        /// Mouse-up must follow mouse-down within this time and distance to count as a click.
        static let clickMaxDuration: TimeInterval = 0.8
        static let clickMaxTravel: CGFloat = 4
        /// A trigger's origin applies to a level change within this time.
        static let originWindow: TimeInterval = 1.5
        /// The pointer counts as "in the bar" this far below the strip, so resting on its
        /// bottom edge does not start the rehide timer.
        static let pointerBelowTolerance: CGFloat = 2
    }

    init(context: AppContext) {
        self.context = context
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        if !context.settings[RevealSettings.hideEverythingPersists], context.settings[RevealSettings.hideEverything] {
            context.settings[RevealSettings.hideEverything] = false
            note("hide everything reset at launch")
        }
        refreshStrips()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStrips() }
        }
        settingsObserver = ChangeObserver(track: { [weak self] in _ = self?.context.settings.revision }) { [weak self] in
            self?.applySettings()
        }
        levelObserver = ChangeObserver(track: { [weak self] in _ = self?.context.visibility.level }) { [weak self] in
            self?.levelChanged()
        }
        lastLevel = context.visibility.level
        applySettings()
        if lastLevel != .collapsed { levelChanged() }
    }

    func stop() {
        settingsObserver?.cancel()
        levelObserver?.cancel()
        tickTask?.cancel()
        hoverCheck?.cancel()
        removeMonitor(&mouseMonitor)
        removeMonitor(&moveMonitor)
        removeMonitor(&scrollMonitor)
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        #if DEBUG
        restoreDebugPins()
        #endif
        started = false
    }

    // MARK: Settings

    private var settings: SettingsStore { context.settings }

    /// Resolved at use time (CONTRACTS: services may be replaced).
    private var router: any RevealRouting { context.services[.revealRouting] }

    private func applySettings() {
        var config = rehide.config
        let delay = settings[RevealSettings.rehideDelay]
        config.delay = delay > 0 ? TimeInterval(delay) : nil
        #if DEBUG
        if let rehideDelayOverride { config.delay = rehideDelayOverride > 0 ? rehideDelayOverride : nil }
        #endif
        config.collapseOnClickOutside = settings[RevealSettings.rehideOnClickOutside]
        config.collapseOnAppSwitch = settings[RevealSettings.rehideOnAppSwitch]
        let delayChanged = config.delay != rehide.config.delay
        rehide.config = config
        // A new delay counts from now, not from an interaction long ago.
        if delayChanged, let origin = rehide.origin { rehide.revealed(origin: origin, at: Self.now) }
        hover.delay = min(max(settings[RevealSettings.hoverDelay], RevealSettings.hoverDelayRange.lowerBound),
                          RevealSettings.hoverDelayRange.upperBound)
        if !settings[RevealSettings.hover] { hover.reset(); hoverCheck?.cancel() }
        if !settings[RevealSettings.scroll] { scroll.reset() }
        updateMonitors()
        updateConcealShown()
    }

    // MARK: Presentation level

    private func levelChanged() {
        let level = context.visibility.level
        defer { lastLevel = level }
        let now = Self.now
        if level == .collapsed {
            if rehide.isRevealed { note("collapsed") }
            rehide.collapsed()
            tickTask?.cancel()
            tickTask = nil
        } else {
            let origin: RehideMachine.Origin
            var triggerLocation: CGPoint?
            if let pending = pendingOrigin, now - pending.at <= Tuning.originWindow {
                origin = pending.origin
                triggerLocation = pending.location
            } else if let current = rehide.origin {
                origin = current
            } else {
                origin = .other
            }
            pendingOrigin = nil
            if lastLevel == .collapsed || !rehide.isRevealed {
                revealDisplayHasNotch = display(at: triggerLocation ?? EventSynthesizer.pointerLocation)?.hasNotch ?? false
                note("revealed \(level.rawValue) by \(origin.rawValue)\(revealDisplayHasNotch ? " on a notched display" : "")")
            }
            rehide.revealed(origin: origin, at: now)
            startTicking()
        }
        updateMonitors()
        updateConcealShown()
    }

    /// The only writer of the engine's `concealShown`.
    private func updateConcealShown() {
        let scope = RevealModes.MakeRoomScope(rawValue: settings[RevealSettings.makeRoomScope]) ?? .always
        let conceal = RevealModes.concealShown(hideEverything: settings[RevealSettings.hideEverything],
                                               makeRoom: settings[RevealSettings.makeRoom],
                                               scope: scope,
                                               level: context.visibility.level,
                                               revealDisplayHasNotch: revealDisplayHasNotch)
        if conceal != context.visibility.concealShown {
            note("conceal shown \(conceal)")
            context.visibility.setConcealShown(conceal)
        }
    }

    // MARK: Monitors

    private var clickTriggerOn: Bool { settings[RevealSettings.clickEmptySpace] }
    private var hoverTriggerOn: Bool { settings[RevealSettings.hover] }
    private var scrollTriggerOn: Bool { settings[RevealSettings.scroll] }

    /// Installs exactly the monitors the current settings and state need.
    private func updateMonitors() {
        let revealed = context.visibility.level != .collapsed
        // Mouse buttons: the click trigger, click-outside and "clicked in the bar" for app switches.
        setMonitor(&mouseMonitor, wanted: clickTriggerOn || revealed,
                   mask: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.handleMouseButton(event)
        }
        setMonitor(&moveMonitor, wanted: hoverTriggerOn, mask: [.mouseMoved]) { [weak self] event in
            self?.handleMouseMoved(event)
        }
        setMonitor(&scrollMonitor, wanted: scrollTriggerOn, mask: [.scrollWheel]) { [weak self] event in
            self?.handleScroll(event)
        }
        let wantsActivation = revealed && settings[RevealSettings.rehideOnAppSwitch]
        if wantsActivation, activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated { self?.appActivated(pid: pid) }
            }
        } else if !wantsActivation, let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    private func setMonitor(_ monitor: inout Any?, wanted: Bool, mask: NSEvent.EventTypeMask,
                            handler: @escaping (NSEvent) -> Void) {
        if wanted, monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
        } else if !wanted {
            removeMonitor(&monitor)
        }
    }

    private func removeMonitor(_ monitor: inout Any?) {
        if let existing = monitor { NSEvent.removeMonitor(existing) }
        monitor = nil
    }

    var installedMonitors: [String] {
        [mouseMonitor.map { _ in "mouse" }, moveMonitor.map { _ in "move" }, scrollMonitor.map { _ in "scroll" },
         activationObserver.map { _ in "app-switch" }].compactMap { $0 }
    }

    // MARK: Geometry

    private func refreshStrips() {
        strips = NSScreen.screens.map { screen in
            let strip = ScreenGeometry.topLeftRect(fromAppKit: ScreenGeometry.menuBarFrame(of: screen))
            var notch: ClosedRange<CGFloat>?
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, left.maxX < right.minX {
                notch = left.maxX...right.minX
            }
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return RevealBarGeometry.Display(displayID: number?.uint32Value ?? 0, strip: strip, notch: notch)
        }
    }

    /// Strips plus what MenuBarAgent draws (last list B read).
    func currentGeometry() -> RevealBarGeometry {
        let drawn = context.catalog.drawn
        return RevealBarGeometry(displays: strips.map { base in
            guard let bar = drawn.displays.first(where: { $0.displayID == base.displayID }) else { return base }
            let visible = bar.slots.filter { !$0.isOverflowed }
            return RevealBarGeometry.Display(displayID: base.displayID, strip: base.strip, notch: base.notch,
                                       slots: visible.map(\.frame),
                                       slotOwnerPIDs: Set(visible.compactMap(\.ownerPID)),
                                       chevron: bar.chevronFrame)
        })
    }

    private var stripGeometry: RevealBarGeometry { RevealBarGeometry(displays: strips) }

    /// The display whose columns hold `point` (the pointer for keyboard triggers).
    private func display(at point: CGPoint?) -> RevealBarGeometry.Display? {
        guard let point else { return strips.first }
        return strips.first { $0.strip.minX <= point.x && point.x < $0.strip.maxX } ?? strips.first
    }

    /// Classifies a point: geometry first, then one Accessibility probe off the main thread.
    func classify(_ point: CGPoint) async -> BarHit {
        let geometry = currentGeometry()
        if let hit = BarHitClassifier.geometryHit(point, in: geometry) { return hit }
        guard context.permissions.accessibility else { return .unknown }
        let owner = NSWorkspace.shared.menuBarOwningApplication?.processIdentifier
        let probe = await AXInventory.onQueue { RevealHitProbe.probe(at: point, menuBarOwnerPID: owner) }
        return BarHitClassifier.classify(point, in: geometry, probe: probe)
    }

    // MARK: Blockers

    private var isBusy: Bool { context.visibility.isInteractionActive || context.clockBridge.isSessionActive }

    private func isMenuOpen() -> Bool {
        let stripRects = strips.map(\.strip)
        return WindowList.onScreen().contains { MenuWindowFilter.hangsFromBar(layer: $0.layer, bounds: $0.bounds, strips: stripRects) }
    }

    private func blockers(pointer: CGPoint? = EventSynthesizer.pointerLocation) -> RehideMachine.Blockers {
        let inBar = pointer.map { stripGeometry.isInStrip($0, belowTolerance: Tuning.pointerBelowTolerance) } ?? false
        return RehideMachine.Blockers(pointerInBar: inBar, menuOpen: isMenuOpen(), interactionActive: isBusy)
    }

    // MARK: Rehide

    private func startTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Tuning.tickInterval)
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    private func tick() {
        guard rehide.isRevealed else { return }
        // Nothing can fire by time: skip the window list read.
        guard rehide.config.delay != nil || rehide.origin == .hover else { return }
        let current = blockers()
        if current != lastBlockers {
            log.debug("rehide blockers: pointer in bar \(current.pointerInBar), menu open \(current.menuOpen), busy \(current.interactionActive)")
            lastBlockers = current
        }
        if let reason = rehide.tick(current, at: Self.now) { collapse(reason) }
    }

    private func collapse(_ reason: RehideMachine.Reason) {
        note("rehide: \(reason.rawValue)")
        rehide.collapsed()
        context.commands.runDetached(.collapse, source: .internal)
    }

    private func appActivated(pid: pid_t?) {
        guard rehide.isRevealed, pid != ProcessInfo.processInfo.processIdentifier else { return }
        if let reason = rehide.appSwitched(blockers(), at: Self.now) { collapse(reason) }
    }

    // MARK: Click trigger and click outside

    private func handleMouseButton(_ event: NSEvent) {
        guard let cgEvent = event.cgEvent, !EventSynthesizer.isSynthesized(cgEvent) else { return }
        let location = cgEvent.location
        let now = Self.now
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            pendingClick?.classification.cancel()
            pendingClick = nil
            if stripGeometry.isInStrip(location) {
                rehide.barClicked(at: now)
                if event.type == .leftMouseDown { armClick(at: location, event: event, now: now) }
            } else if rehide.isRevealed, let reason = rehide.clickOutside(blockers(pointer: location), at: now) {
                collapse(reason)
            }
        case .leftMouseUp:
            guard let click = pendingClick else { return }
            pendingClick = nil
            let travel = hypot(location.x - click.location.x, location.y - click.location.y)
            guard now - click.time <= Tuning.clickMaxDuration, travel <= Tuning.clickMaxTravel else {
                click.classification.cancel()
                return
            }
            Task { [weak self] in
                let hit = await click.classification.value
                self?.clickClassified(hit, at: click.location, allItems: click.allItems)
            }
        default:
            break
        }
    }

    private func armClick(at location: CGPoint, event: NSEvent, now: TimeInterval) {
        guard clickTriggerOn else { return }
        let modifiers = event.modifierFlags.union(NSEvent.modifierFlags)
        // ⌘-drag rearranges items; ⌃-click is a right click.
        guard modifiers.isDisjoint(with: [.command, .control]) else { return }
        guard !isBusy else { return note("click ignored: busy") }
        // A click while a menu hangs from the bar only closes that menu.
        guard !isMenuOpen() else { return note("click ignored: a menu is open") }
        pendingClick = PendingClick(location: location, time: now, allItems: modifiers.contains(.option),
                                    classification: Task { [weak self] in
                                        await self?.classify(location) ?? .unknown
                                    })
    }

    private func clickClassified(_ hit: BarHit, at location: CGPoint, allItems: Bool) {
        note("click at \(Self.describe(location)): \(hit.rawValue)")
        guard hit == .empty, clickTriggerOn, !isBusy else { return }
        let now = Self.now
        guard now - lastToggleAt >= Tuning.toggleDebounce else { return note("click ignored: debounce") }
        lastToggleAt = now
        runPointerCommand(allItems ? .toggleAll : .toggleHidden, origin: .click, at: location)
    }

    // MARK: Hover trigger

    private func handleMouseMoved(_ event: NSEvent) {
        guard let cgEvent = event.cgEvent, !EventSynthesizer.isSynthesized(cgEvent) else { return }
        evaluateHover(at: cgEvent.location)
    }

    private func evaluateHover(at location: CGPoint) {
        guard hoverTriggerOn else { return }
        let inBar = hoverZoneContains(location)
        let suspended = NSEvent.modifierFlags.contains(.command) || isBusy
        let now = Self.now
        if inBar != lastHoverInBar {
            lastHoverInBar = inBar
            log.debug("hover: pointer \(inBar ? "entered" : "left") the bar at \(Self.describe(location))\(suspended ? " (suspended)" : "")")
        }
        if hover.update(inBar: inBar, suspended: suspended, at: now) {
            hoverFired(at: location)
        }
        scheduleHoverCheck()
    }

    /// In a strip and not in the notch.
    private func hoverZoneContains(_ point: CGPoint) -> Bool {
        guard let display = stripGeometry.display(containing: point) else { return false }
        return !(display.notch?.contains(point.x) ?? false)
    }

    /// The pointer may rest without further events: re-check when the dwell would complete.
    private func scheduleHoverCheck() {
        hoverCheck?.cancel()
        guard let next = hover.nextCheck else { return }
        let wait = max(0, next - Self.now) + 0.01
        hoverCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, let pointer = EventSynthesizer.pointerLocation else { return }
            self.evaluateHover(at: pointer)
        }
    }

    private func hoverFired(at location: CGPoint) {
        log.debug("hover: dwell complete at \(Self.describe(location)), level \(context.visibility.level.rawValue)")
        guard !router.isHiddenPresented else { return }
        Task { [weak self] in
            guard let self else { return }
            let hit = await self.classify(location)
            // Resting on the app menus means the user is using them.
            guard hit != .menuTitle, hit != .notch, hit != .outside else {
                self.note("hover at \(Self.describe(location)): \(hit.rawValue), not revealing")
                // Try again after more movement, not while the pointer rests on the menus.
                self.hover.rearm(at: Self.now)
                return
            }
            guard self.hoverTriggerOn, !self.router.isHiddenPresented, !self.isBusy,
                  let pointer = EventSynthesizer.pointerLocation, self.hoverZoneContains(pointer) else { return }
            self.note("hover at \(Self.describe(location)): \(hit.rawValue)")
            self.runPointerCommand(.showHidden, origin: .hover, at: location)
        }
    }

    // MARK: Scroll trigger

    private func handleScroll(_ event: NSEvent) {
        guard let cgEvent = event.cgEvent, !EventSynthesizer.isSynthesized(cgEvent) else { return }
        guard scrollTriggerOn else { return }
        let location = cgEvent.location
        let geometry = currentGeometry()
        // Over a status item, the scroll belongs to that item.
        let inBar: Bool = switch BarHitClassifier.geometryHit(location, in: geometry) {
        case nil: true
        default: false
        }
        let phase = Self.phase(of: event)
        let precise = event.hasPreciseScrollingDeltas
        let inverted = event.isDirectionInvertedFromDevice
        let sample = ScrollGestureRecognizer.Sample(
            dx: ScrollGestureRecognizer.physicalDelta(scrollingDelta: event.scrollingDeltaX, invertedFromDevice: inverted, precise: precise),
            dy: ScrollGestureRecognizer.physicalDelta(scrollingDelta: event.scrollingDeltaY, invertedFromDevice: inverted, precise: precise),
            time: event.timestamp, phase: phase, inBar: inBar && !isBusy)
        if inBar {
            log.debug("scroll in bar: dx \(event.scrollingDeltaX) dy \(event.scrollingDeltaY) precise \(precise) inverted \(inverted) phase \(phase)")
        }
        guard let decision = scroll.feed(sample) else { return }
        let level = context.visibility.level
        note("scroll \(decision.rawValue) at \(Self.describe(location)), level \(level.rawValue)")
        switch decision {
        case .reveal:
            if !router.isHiddenPresented {
                runPointerCommand(.showHidden, origin: .scroll, at: location)
            } else if level == .hiddenRevealed, settings[RevealSettings.scrollRevealsAlwaysHidden] {
                runPointerCommand(.showAll, origin: .scroll, at: location)
            }
        case .collapse:
            runPointerCommand(.collapse, origin: nil, at: location)
        }
    }

    private static func phase(of event: NSEvent) -> ScrollGestureRecognizer.Phase {
        if !event.momentumPhase.isEmpty { return .momentum }
        let phase = event.phase
        if phase.contains(.began) || phase.contains(.mayBegin) { return .began }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.cancelled) { return .cancelled }
        if phase.contains(.changed) || phase.contains(.stationary) { return .changed }
        return .none
    }

    // MARK: Commands

    /// Runs a core visibility command for a pointer-driven trigger.
    private func runPointerCommand(_ id: CommandID, origin: RehideMachine.Origin?, at location: CGPoint) {
        if let origin { pendingOrigin = (origin, Self.now, location) }
        var arguments = ["anchor": "pointer"]
        // The gesture tells a panel presenter (the Rolltop Bar) how it should close.
        if id == .toggleHidden || id == .showHidden, let gesture = origin.flatMap(Self.gesture(for:)) {
            arguments["gesture"] = gesture.rawValue
        }
        context.commands.runDetached(id, arguments: arguments, source: .internal)
    }

    static func gesture(for origin: RehideMachine.Origin) -> RevealGesture? {
        switch origin {
        case .click: .click
        case .hover: .hover
        case .scroll: .scroll
        case .other, .keep: nil
        }
    }

    /// Shows hidden items in the menu bar until something hides them again. Always inline,
    /// also when the Rolltop Bar presents hidden items: a panel closes by itself.
    func keepRevealed() async throws {
        pendingOrigin = (.keep, Self.now, nil)
        if context.visibility.level != .collapsed {
            rehide.revealed(origin: .keep, at: Self.now)
            note("kept revealed")
            return
        }
        if router.presentsHiddenInPanel { context.services[.itemPanel].dismissPanel(opener: ItemPanelRequest.revealOpener) }
        context.visibility.show(.hiddenRevealed)
    }

    func toggleHideEverything() {
        let on = !settings[RevealSettings.hideEverything]
        settings[RevealSettings.hideEverything] = on
        note("hide everything \(on)")
        if on, context.visibility.level != .collapsed {
            context.commands.runDetached(.collapse, source: .internal)
        }
    }

    func toggleMakeRoom() {
        settings[RevealSettings.makeRoom].toggle()
        note("make room \(settings[RevealSettings.makeRoom])")
    }

    // MARK: Helpers

    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    static func describe(_ point: CGPoint) -> String { "(\(Int(point.x)), \(Int(point.y)))" }

    private func note(_ message: String) {
        log.info(message)
        recentEvents.append("\(String(format: "%.3f", Self.now)) \(message)")
        if recentEvents.count > 60 { recentEvents.removeFirst(recentEvents.count - 60) }
    }

    // MARK: Debug

    #if DEBUG
    var debugSnapshot: [String: Any] {
        [
            "level": context.visibility.level.rawValue,
            "concealShown": context.visibility.concealShown,
            "rehideOrigin": rehide.origin?.rawValue ?? "none",
            "rehideDelay": rehide.config.delay ?? -1,
            "secondsSinceActivity": rehide.isRevealed ? Self.now - rehide.lastActivity : -1,
            "monitors": installedMonitors,
            "hover": ["enteredAt": hover.enteredAt ?? -1, "fired": hover.fired, "delay": hover.delay, "now": Self.now],
            "settings": RevealSettings.allKeyNames.reduce(into: [String: Any]()) { result, key in
                result[key] = settings.defaults.object(forKey: key) ?? NSNull()
            },
            "recentEvents": recentEvents,
        ]
    }

    func setRehideDelayOverride(_ seconds: TimeInterval?) {
        rehideDelayOverride = seconds
        applySettings()
        note("rehide delay override \(seconds.map { "\($0)" } ?? "cleared")")
    }

    /// Pins every present owner except `except`, so "make room" and "hide everything" only
    /// conceal the test fixtures. The previous value comes back with `restoreDebugPins()`.
    func pinPresentOwners(except: Set<OwnerID>) {
        if savedPins == nil {
            savedPins = .some(settings.hasValue(for: CoreSettings.pinned) ? settings[CoreSettings.pinned] : nil)
        }
        let base = Set(CoreSettings.pinned.defaultValue)
        let pins = base.union(context.catalog.presentOwners).subtracting(except)
        settings[CoreSettings.pinned] = pins.sorted { $0.stringValue < $1.stringValue }
        note("debug: pinned \(pins.count) owners, \(except.count) excluded")
    }

    func restoreDebugPins() {
        guard let saved = savedPins else { return }
        if let value = saved { settings[CoreSettings.pinned] = value } else { settings.reset(CoreSettings.pinned) }
        savedPins = nil
        note("debug: pins restored")
    }
    #endif
}
