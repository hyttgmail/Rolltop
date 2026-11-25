import Foundation
import RolltopCore

/// When revealed items hide again (inline presentation only). Pure: the controller feeds it
/// reveal/collapse transitions, periodic ticks with the current blockers, clicks outside
/// the bar and app switches, and runs the collapse it returns.
///
/// Rules:
/// - The delay is measured from the last interaction. While the pointer is in the bar, a
///   menu or panel hangs from the bar, or Rolltop is busy (an activated item, the clock
///   bridge), the clock stands still and restarts when they end.
/// - A click outside the bar collapses, except while a menu is open: that click only closes
///   the menu, and the timer takes over.
/// - An app switch collapses unless the user just clicked in the bar (an item that opens a
///   panel activates its app) or is still interacting.
/// - Hover reveals also end when the pointer has been out of the bar for `hoverLeaveTolerance`.
/// - `keep` reveals (the "keep revealed" command) only end by an explicit collapse.
nonisolated struct RehideMachine: Sendable {
    enum Origin: String, Sendable {
        case click
        case hover
        case scroll
        /// Status item, hotkey, URL, menu…
        case other
        /// Revealed until the user hides the items.
        case keep
    }

    enum Reason: String, Sendable {
        case timer
        case clickOutside = "click-outside"
        case appSwitch = "app-switch"
        case pointerLeft = "pointer-left"
    }

    struct Config: Sendable, Equatable {
        /// Nil: never by time.
        var delay: TimeInterval? = 10
        var collapseOnClickOutside = true
        var collapseOnAppSwitch = false
        var hoverLeaveTolerance: TimeInterval = 0.6
        /// App switches this soon after a click in the bar were caused by that click.
        var barClickGrace: TimeInterval = 1.5
    }

    struct Blockers: Sendable, Equatable {
        var pointerInBar = false
        var menuOpen = false
        var interactionActive = false

        var isBlocking: Bool { pointerInBar || menuOpen || interactionActive }
    }

    var config: Config

    /// Nil while collapsed.
    private(set) var origin: Origin?
    private(set) var lastActivity: TimeInterval = 0
    private(set) var pointerOutSince: TimeInterval?
    private(set) var lastBarClick: TimeInterval?

    init(config: Config = Config()) {
        self.config = config
    }

    var isRevealed: Bool { origin != nil }

    mutating func revealed(origin newOrigin: Origin, at now: TimeInterval) {
        origin = newOrigin
        lastActivity = now
        pointerOutSince = nil
    }

    mutating func collapsed() {
        origin = nil
        pointerOutSince = nil
    }

    mutating func barClicked(at now: TimeInterval) {
        lastBarClick = now
        if origin != nil { lastActivity = now }
    }

    /// Periodic check while revealed.
    mutating func tick(_ blockers: Blockers, at now: TimeInterval) -> Reason? {
        guard let origin, origin != .keep else { return nil }
        if blockers.isBlocking { lastActivity = now }

        if origin == .hover {
            if blockers.isBlocking {
                pointerOutSince = nil
            } else {
                let since = pointerOutSince ?? now
                pointerOutSince = since
                if now - since >= config.hoverLeaveTolerance { return .pointerLeft }
            }
        }

        guard let delay = config.delay, !blockers.isBlocking else { return nil }
        return now - lastActivity >= delay ? .timer : nil
    }

    mutating func clickOutside(_ blockers: Blockers, at now: TimeInterval) -> Reason? {
        guard let origin, origin != .keep, config.collapseOnClickOutside else { return nil }
        if blockers.menuOpen || blockers.interactionActive {
            lastActivity = now
            return nil
        }
        return .clickOutside
    }

    mutating func appSwitched(_ blockers: Blockers, at now: TimeInterval) -> Reason? {
        guard let origin, origin != .keep, config.collapseOnAppSwitch else { return nil }
        if blockers.isBlocking { return nil }
        if let lastBarClick, now - lastBarClick < config.barClickGrace { return nil }
        return .appSwitch
    }

    /// When the timer would fire if nothing changes (for scheduling), nil when it cannot.
    var deadline: TimeInterval? {
        guard let origin, origin != .keep, let delay = config.delay else { return nil }
        return lastActivity + delay
    }
}

/// "Make room" and "hide everything" both conceal the shown section (except the pinned
/// owners) through the engine's single `concealShown` flag; this decides its value.
nonisolated enum RevealModes {
    enum MakeRoomScope: String, Sendable, CaseIterable, Codable {
        case always
        /// Only when the reveal happens on a display with a notch, where the bar is shortest.
        case notchedDisplays = "notch"
    }

    /// - `hideEverything`: on until toggled off, at every level (revealing then shows the
    ///   hidden section in place of the shown one).
    /// - Make room: only while hidden items are revealed, and with `.notchedDisplays` only
    ///   when the display the reveal happened on has a notch. Concealment is global (one
    ///   allow-list for every display), so "the display the reveal happened on" stands for
    ///   the whole reveal.
    static func concealShown(hideEverything: Bool, makeRoom: Bool, scope: MakeRoomScope,
                             level: PresentationLevel, revealDisplayHasNotch: Bool) -> Bool {
        if hideEverything { return true }
        guard makeRoom, level != .collapsed else { return false }
        switch scope {
        case .always: return true
        case .notchedDisplays: return revealDisplayHasNotch
        }
    }
}
