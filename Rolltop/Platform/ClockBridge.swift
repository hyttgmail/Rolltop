import AppKit
import CoreGraphics
import Foundation
import Observation
import RolltopCore

/// While a restriction is held, MenuBarAgent ignores clicks on the clock, so Notification
/// Center cannot open (docs/PLATFORM.md §3). The bridge watches left clicks; a click on the
/// clock lifts the restriction, waits for MenuBarAgent to apply that, replays the click
/// (tagged, so the bridge ignores it) and brings the restriction back.
@Observable
final class ClockBridge {
    enum RestoreMode: String, Sendable {
        /// Restore ~40 ms after the replayed press; the panel stays open (measured 27.2.1).
        case afterPress = "after-press"
        /// Keep the restriction lifted until the panel closes again, then restore after 1 s.
        case afterPanelCloses = "after-panel-closes"
    }

    struct Timing: Sendable {
        /// MenuBarAgent applies a release in 40–90 ms; earlier presses are dropped.
        var liftDelay: Duration = .milliseconds(90)
        var restoreAfterPress: Duration = .milliseconds(40)
        var panelAppearTimeout: Duration = .milliseconds(400)
        var holdPanelAppearTimeout: Duration = .milliseconds(1500)
        var pollInterval: Duration = .milliseconds(20)
        var closedPollInterval: Duration = .milliseconds(250)
        var restoreAfterClose: Duration = .seconds(1)
        /// Hard cap: the restriction always comes back after this.
        var cap: Duration = .seconds(120)
    }

    /// Clicks this far outside the clock's frame still hit it (measured by Hidden Bar on 27.2.1).
    nonisolated static let paddingTowardNeighbour: CGFloat = 6
    nonisolated static let paddingTowardScreenEdge: CGFloat = 24

    private(set) var isSessionActive = false
    private(set) var lastOutcome: String?
    private(set) var sessionCount = 0

    @ObservationIgnored var restoreMode: RestoreMode = .afterPress
    @ObservationIgnored var timing = Timing()

    @ObservationIgnored private let isRestricted: () -> Bool
    @ObservationIgnored private let lift: () -> VisibilityEngine.Token
    @ObservationIgnored private let restore: (VisibilityEngine.Token) -> Void
    @ObservationIgnored private let beginInteraction: (String) -> VisibilityEngine.Token
    @ObservationIgnored private let endInteraction: (VisibilityEngine.Token) -> Void
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var mouseDownCheck: Task<CGRect?, Never>?
    @ObservationIgnored private let log = Log.logger("clock")

    init(isRestricted: @escaping () -> Bool,
         lift: @escaping () -> VisibilityEngine.Token,
         restore: @escaping (VisibilityEngine.Token) -> Void,
         beginInteraction: @escaping (String) -> VisibilityEngine.Token,
         endInteraction: @escaping (VisibilityEngine.Token) -> Void) {
        self.isRestricted = isRestricted
        self.lift = lift
        self.restore = restore
        self.beginInteraction = beginInteraction
        self.endInteraction = endInteraction
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    // MARK: Click detection

    private func handle(_ event: NSEvent) {
        guard let cgEvent = event.cgEvent, !EventSynthesizer.isSynthesized(cgEvent) else { return }
        let location = cgEvent.location
        switch event.type {
        case .leftMouseDown:
            mouseDownCheck?.cancel()
            mouseDownCheck = nil
            // ⌘-drag rearranges the bar and ⌃-click is a right click.
            guard isRestricted(), !isSessionActive,
                  event.modifierFlags.isDisjoint(with: [.command, .control]) else { return }
            let displays = DisplayGeometry.current()
            guard Self.isInMenuBarStrip(location, displays: displays) else { return }
            // A click on the clock closes an open panel by itself; never replay then.
            mouseDownCheck = Task {
                await AXInventory.onQueue {
                    let minimumHeight = NotificationCenterPanel.minimumPanelHeight(displays: displays)
                    guard let clock = Self.clockFrames(displays: displays).first(where: { Self.isOnClock(location, frame: $0) }),
                          !NotificationCenterPanel.isOpen(minimumHeight: minimumHeight) else { return nil }
                    return clock
                }
            }
        case .leftMouseUp:
            guard let check = mouseDownCheck else { return }
            mouseDownCheck = nil
            Task { [weak self] in
                guard let frame = await check.value, Self.isOnClock(location, frame: frame) else { return }
                self?.openNotificationCenter(at: location)
            }
        default:
            break
        }
    }

    // MARK: Session

    /// Opens Notification Center by replaying a click on the clock with the restriction
    /// lifted. `location` nil clicks the clock's centre. Also used by `ItemActivator`.
    func openNotificationCenter(at location: CGPoint? = nil) {
        guard !isSessionActive else { return }
        isSessionActive = true
        sessionCount += 1
        let interaction = beginInteraction("clock")
        log.info("clock click while restricted: replaying (\(restoreMode.rawValue))")
        Task {
            let outcome = await runSession(at: location)
            lastOutcome = outcome
            log.info("clock session ended: \(outcome)")
            endInteraction(interaction)
            isSessionActive = false
        }
    }

    private func runSession(at location: CGPoint?) async -> String {
        let displays = DisplayGeometry.current()
        let minimumHeight = NotificationCenterPanel.minimumPanelHeight(displays: displays)
        let started = ContinuousClock.now
        let panelOpen: @Sendable () async -> Bool = {
            await AXInventory.onQueue { NotificationCenterPanel.isOpen(minimumHeight: minimumHeight) }
        }

        var token = lift()
        var restored = false
        func restoreOnce() {
            guard !restored else { return }
            restored = true
            restore(token)
        }
        defer { restoreOnce() }

        try? await Task.sleep(for: timing.liftDelay)
        guard await replay(at: location, displays: displays) else { return "no-clock" }

        if restoreMode == .afterPress {
            try? await Task.sleep(for: timing.restoreAfterPress)
            restoreOnce()
            if await waitFor(panelOpen, timeout: timing.panelAppearTimeout) {
                await waitWhile(panelOpen, until: started + timing.cap)
                return "panel-shown-restored-after-press"
            }
            // Nothing opened: lift again and hold until the panel shows.
            log.notice("clock replay opened nothing; retrying with the restriction held off")
            token = lift()
            restored = false
            try? await Task.sleep(for: timing.liftDelay)
            guard await replay(at: location, displays: displays) else { return "no-clock-retry" }
            let shown = await waitFor(panelOpen, timeout: timing.holdPanelAppearTimeout)
            restoreOnce()
            guard shown else { return "no-panel" }
            await waitWhile(panelOpen, until: started + timing.cap)
            return "panel-shown-after-retry"
        }

        // .afterPanelCloses
        guard await waitFor(panelOpen, timeout: timing.holdPanelAppearTimeout) else { return "no-panel" }
        let closed = await waitWhile(panelOpen, until: started + timing.cap)
        if closed { try? await Task.sleep(for: timing.restoreAfterClose) }
        return closed ? "panel-closed" : "cap"
    }

    private func replay(at location: CGPoint?, displays: [DisplayGeometry]) async -> Bool {
        await AXInventory.onQueue {
            let clocks = Self.clockFrames(displays: displays)
            let target: CGPoint
            if let location, clocks.contains(where: { Self.isOnClock(location, frame: $0) }) {
                target = location
            } else if location == nil, let clock = clocks.first {
                target = CGPoint(x: clock.midX, y: clock.midY)
            } else {
                return false
            }
            return EventSynthesizer.click(at: target, button: .left, restorePointer: true)
        }
    }

    private func waitFor(_ condition: @Sendable () async -> Bool, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: timing.pollInterval)
        }
        return await condition()
    }

    /// Waits while `condition` holds; returns false when the deadline passed first.
    @discardableResult
    private func waitWhile(_ condition: @Sendable () async -> Bool, until deadline: ContinuousClock.Instant) async -> Bool {
        while ContinuousClock.now < deadline {
            if !(await condition()) { return true }
            try? await Task.sleep(for: timing.closedPollInterval)
        }
        return false
    }

    // MARK: Geometry (any thread)

    nonisolated static func isOnClock(_ point: CGPoint, frame: CGRect) -> Bool {
        let language = Locale.preferredLanguages.first ?? "en"
        let rightToLeft = NSLocale.characterDirection(forLanguage: language) == .rightToLeft
        let left = rightToLeft ? paddingTowardScreenEdge : paddingTowardNeighbour
        let right = rightToLeft ? paddingTowardNeighbour : paddingTowardScreenEdge
        return point.x >= frame.minX - left && point.x <= frame.maxX + right
            && point.y >= frame.minY && point.y < frame.maxY
    }

    nonisolated static func isInMenuBarStrip(_ point: CGPoint, displays: [DisplayGeometry]) -> Bool {
        displays.contains { display in
            point.x >= display.bounds.minX && point.x <= display.bounds.maxX
                && point.y >= display.bounds.minY && point.y <= display.bounds.minY + 40
        }
    }

    /// The clock's drawn slot on every display (list B), global top-left coordinates.
    nonisolated static func clockFrames(displays: [DisplayGeometry]) -> [CGRect] {
        let agent = NSRunningApplication.runningApplications(withBundleIdentifier: menuBarAgentBundleID).first?.processIdentifier
        let snapshot = AXInventory.readDrawn(agentPID: agent, bundleByPID: [:], displays: displays)
        return snapshot.allSlots.filter { $0.axIdentifier == SystemModule.clock.axIdentifier }.map(\.frame)
    }
}
