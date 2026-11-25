import AppKit
import Foundation
import Observation
import RolltopCore

/// Opens an owner's menu or panel even when it is hidden (docs/PLATFORM.md §4):
/// temporary allow → wait until MenuBarAgent draws it → press (never an undrawn item) →
/// detect the menu or panel → end the temporary allow when it closes.
@Observable
final class ItemActivator {
    enum Button: String, Sendable, CaseIterable {
        case left
        case right
    }

    enum Outcome: String, Sendable {
        /// A new window at pop-up menu level appeared for the owner.
        case menuOpened = "menu-opened"
        /// The owner became the active app (panel-style item).
        case panelOpened = "panel-opened"
        /// Pressed, but nothing visible was detected.
        case nothingDetected = "nothing-detected"
        /// The clock: handed to the clock bridge.
        case notificationCenter = "notification-center"
    }

    enum ActivationError: LocalizedError {
        case accessibilityDenied
        case notAssignable(String)
        case notRunning(OwnerID)
        case notDrawn(OwnerID)
        case noPressTarget(OwnerID)

        var errorDescription: String? {
            switch self {
            case .accessibilityDenied: String(localized: "Rolltop needs Device Control and Data Access to open menu bar items.")
            case .notAssignable(let id): String(localized: "\(id) can’t be opened by Rolltop.")
            case .notRunning(let owner): String(localized: "\(owner.description) isn’t running.")
            case .notDrawn(let owner): String(localized: "\(owner.description) didn’t appear in the menu bar in time.")
            case .noPressTarget(let owner): String(localized: "\(owner.description) has no item that can be clicked.")
            }
        }
    }

    struct Timing: Sendable {
        var drawnPoll: Duration = .milliseconds(100)
        var drawnTimeout: Duration = .milliseconds(1500)
        /// Drawn is reported a moment before MenuBarAgent accepts presses.
        var settleAfterDrawn: Duration = .milliseconds(80)
        var menuAppearTimeout: Duration = .milliseconds(800)
        var panelGrace: Duration = .seconds(2)
        var watchPoll: Duration = .milliseconds(100)
        var panelCap: Duration = .seconds(15)
        var menuCap: Duration = .seconds(600)
    }

    /// The owner whose menu/panel is being opened or watched.
    private(set) var activeOwner: OwnerID?
    private(set) var lastOutcome: String?
    var isBusy: Bool { activeOwner != nil }

    @ObservationIgnored var timing = Timing()
    @ObservationIgnored private let engine: VisibilityEngine
    @ObservationIgnored private let catalog: ItemCatalog
    @ObservationIgnored private let permissions: Permissions
    @ObservationIgnored private let clockBridge: ClockBridge
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var sessionCleanup: (() -> Void)?
    @ObservationIgnored private let log = Log.logger("activator")

    init(engine: VisibilityEngine, catalog: ItemCatalog, permissions: Permissions, clockBridge: ClockBridge) {
        self.engine = engine
        self.catalog = catalog
        self.permissions = permissions
        self.clockBridge = clockBridge
    }

    /// Opens the owner's `index`-th item with a left or right click. Returns once the menu
    /// or panel is detected (or nothing was); watching for it to close continues in the
    /// background and ends the temporary allow then. A new activation supersedes one in progress.
    @discardableResult
    func activate(_ owner: OwnerID, button: Button = .left, index: Int = 0) async throws -> Outcome {
        guard permissions.accessibility else { throw ActivationError.accessibilityDenied }
        endSession(reason: "superseded")
        session += 1
        let id = session
        activeOwner = owner

        let allow = engine.allowTemporarily([owner])
        let interaction = engine.beginInteraction("activate \(owner.stringValue)")
        var cleaned = false
        let cleanup: () -> Void = { [weak self] in
            guard !cleaned else { return }
            cleaned = true
            self?.engine.endTemporaryAllow(allow)
            self?.engine.endInteraction(interaction)
            if self?.session == id {
                self?.activeOwner = nil
                self?.sessionCleanup = nil
            }
        }
        sessionCleanup = cleanup

        do {
            let slot = try await waitUntilDrawn(owner)
            try? await Task.sleep(for: timing.settleAfterDrawn)
            guard session == id else { throw CancellationError() }

            if owner == .system(.clock) {
                // AXPress on the clock opens and closes the panel again (27.2); replay a click.
                cleanup()
                clockBridge.openNotificationCenter(at: nil)
                return finish(.notificationCenter, owner: owner)
            }

            let watchPIDs = try watchedPIDs(for: owner, slot: slot)
            let baseline = Set(WindowList.menuWindows(of: watchPIDs).map(\.windowID))
            try await press(owner, button: button, index: index, slot: slot)

            let outcome = await detect(watchPIDs: watchPIDs, baseline: baseline, owner: owner)
            guard session == id else { return outcome }
            switch outcome {
            case .menuOpened, .panelOpened:
                Task { [weak self] in
                    await self?.watchUntilClosed(outcome, watchPIDs: watchPIDs, baseline: baseline, owner: owner, session: id)
                    cleanup()
                }
            case .nothingDetected, .notificationCenter:
                cleanup()
            }
            return finish(outcome, owner: owner)
        } catch {
            cleanup()
            lastOutcome = "error: \(error.localizedDescription)"
            log.error("activate \(owner) failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Ends the current session's temporary allow now (e.g. the user collapsed the bar).
    func cancel() { endSession(reason: "cancelled") }

    // MARK: Steps

    private func endSession(reason: String) {
        guard let cleanup = sessionCleanup else { return }
        sessionCleanup = nil
        log.debug("ending activation session: \(reason)")
        session += 1
        activeOwner = nil
        cleanup()
    }

    private func finish(_ outcome: Outcome, owner: OwnerID) -> Outcome {
        lastOutcome = outcome.rawValue
        log.info("activate \(owner): \(outcome.rawValue)")
        return outcome
    }

    /// Polls list B until the owner has a visible slot.
    private func waitUntilDrawn(_ owner: OwnerID) async throws -> DrawnSlotRecord {
        let deadline = ContinuousClock.now + timing.drawnTimeout
        repeat {
            let snapshot = await catalog.refreshDrawn()
            if let slot = Self.visibleSlot(of: owner, in: snapshot, apps: catalog.runningApps) { return slot }
            try await Task.sleep(for: timing.drawnPoll)
        } while ContinuousClock.now < deadline
        throw ActivationError.notDrawn(owner)
    }

    static func visibleSlot(of owner: OwnerID, in snapshot: DrawnSnapshot, apps: [RunningAppRecord]) -> DrawnSlotRecord? {
        let visible = snapshot.displays.sorted { $0.isMain && !$1.isMain }.flatMap(\.slots).filter { !$0.isOverflowed }
        switch owner {
        case .system(let module):
            return visible.first { $0.axIdentifier == module.axIdentifier }
        case .app(let bundle):
            let pids = Set(apps.filter { $0.bundleID == bundle }.map(\.pid))
            return visible.first { $0.ownerBundleID == bundle || ($0.ownerPID.map(pids.contains) ?? false) }
        }
    }

    private func watchedPIDs(for owner: OwnerID, slot: DrawnSlotRecord) throws -> Set<pid_t> {
        switch owner {
        case .app(let bundle):
            let pids = Set(catalog.runningApps.filter { $0.bundleID == bundle }.map(\.pid))
            guard !pids.isEmpty else { throw ActivationError.notRunning(owner) }
            return pids
        case .system:
            // Module panels belong to Control Center; MenuBarAgent itself may host some.
            var pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").map(\.processIdentifier))
            if let agent = slot.ownerPID { pids.insert(agent) }
            return pids
        }
    }

    private func press(_ owner: OwnerID, button: Button, index: Int, slot: DrawnSlotRecord) async throws {
        let handle: ItemHandle?
        switch owner {
        case .app:
            guard let pid = slot.ownerPID else { throw ActivationError.notRunning(owner) }
            handle = await AXInventory.onQueue { AXInventory.appItemHandle(pid: pid, index: index) }
        case .system(let module):
            guard let agent = slot.ownerPID else { throw ActivationError.noPressTarget(owner) }
            handle = await AXInventory.onQueue { AXInventory.hostedItemHandle(agentPID: agent, identifier: module.axIdentifier) }
        }
        let center = CGPoint(x: slot.frame.midX, y: slot.frame.midY)
        switch button {
        case .left:
            guard let handle else { throw ActivationError.noPressTarget(owner) }
            let result = await AXInventory.onQueue { handle.press() }
            log.debug("AXPress \(owner): \(result.rawValue)")
            if result != .success, result != .cannotComplete {
                // Some apps ignore AXPress: fall back to a synthetic click on the drawn slot.
                _ = await AXInventory.onQueue { EventSynthesizer.click(at: center, button: .left) }
            }
        case .right:
            if let handle, handle.supportsShowMenu {
                let result = await AXInventory.onQueue { handle.showMenu() }
                log.debug("AXShowMenu \(owner): \(result.rawValue)")
                if result == .success || result == .cannotComplete { return }
            }
            _ = await AXInventory.onQueue { EventSynthesizer.click(at: center, button: .right) }
        }
    }

    private func detect(watchPIDs: Set<pid_t>, baseline: Set<CGWindowID>, owner: OwnerID) async -> Outcome {
        let menuDeadline = ContinuousClock.now + timing.menuAppearTimeout
        let panelDeadline = menuDeadline + timing.panelGrace
        while ContinuousClock.now < panelDeadline {
            if Self.hasNewMenuWindow(watchPIDs, baseline: baseline) { return .menuOpened }
            if ContinuousClock.now >= menuDeadline, Self.isActive(watchPIDs) { return .panelOpened }
            try? await Task.sleep(for: timing.watchPoll)
        }
        return .nothingDetected
    }

    private func watchUntilClosed(_ outcome: Outcome, watchPIDs: Set<pid_t>, baseline: Set<CGWindowID>,
                                  owner: OwnerID, session id: Int) async {
        let cap = outcome == .menuOpened ? timing.menuCap : timing.panelCap
        let deadline = ContinuousClock.now + cap
        while ContinuousClock.now < deadline, session == id {
            let open = outcome == .menuOpened ? Self.hasNewMenuWindow(watchPIDs, baseline: baseline) : Self.isActive(watchPIDs)
            if !open {
                log.info("activate \(owner): \(outcome == .menuOpened ? "menu" : "panel") closed")
                return
            }
            try? await Task.sleep(for: timing.watchPoll)
        }
        if session == id { log.notice("activate \(owner): watch cap reached") }
    }

    private static func hasNewMenuWindow(_ pids: Set<pid_t>, baseline: Set<CGWindowID>) -> Bool {
        WindowList.menuWindows(of: pids).contains { !baseline.contains($0.windowID) }
    }

    private static func isActive(_ pids: Set<pid_t>) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        return pids.contains(front.processIdentifier)
    }
}
