import Foundation

/// The shelf's sections, in display order.
nonisolated enum ShelfSection: String, CaseIterable, Sendable, Codable {
    case clipboard
    case files
    case upNext = "up-next"
}

/// What opened the panel; decides how it closes.
nonisolated enum ShelfOpenTrigger: String, Sendable, Equatable {
    /// `shelf.toggle` / `shelf.show` (status menu, shortcut, URL, Shortcuts…).
    case command
    /// The pointer rested on the notch / top-centre hot zone.
    case hover
    /// Files were dragged to the hot zone.
    case drag
}

nonisolated enum ShelfCloseReason: String, Sendable, Equatable {
    case toggled
    case escape
    case clickOutside = "click-outside"
    case pointerLeft = "pointer-left"
    case dropCompleted = "drop-completed"
    case otherPanel = "other-panel"
    case used
    case sectionsOff = "sections-off"
    case api
}

/// Open/close rules of the panel. Pure: the controller feeds events and performs effects.
///
/// - A command opens it "sticky": only toggle, Escape, a click outside, a completed drop,
///   copying a clip or another Rolltop panel close it.
/// - Hover and drag open it "loose": it also closes when the pointer has been outside the
///   hot zone, the panel and the gap between them for `leaveTolerance`. Any interaction
///   inside (a click, typing in the search field) makes it sticky.
nonisolated struct ShelfPanelMachine: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case closed
        case open(trigger: ShelfOpenTrigger, sticky: Bool)
    }

    enum Event: Sendable, Equatable {
        case toggle
        case show
        case hoverDwelled
        case dragEnteredZone
        /// Sampled while open (~10 Hz): is the pointer inside the keep-open region?
        case pointer(inRegion: Bool, now: Date)
        case interacted
        case clickOutside
        case escape
        case dropCompleted
        case otherPanelOpened
        case used
        case sectionsOff
    }

    enum Effect: Sendable, Equatable {
        case none
        case open(ShelfOpenTrigger)
        /// Already open: bring the requested section forward.
        case refresh
        case close(ShelfCloseReason)
    }

    static let leaveTolerance: TimeInterval = 0.45

    private(set) var state: State = .closed
    private(set) var outsideSince: Date?

    var isOpen: Bool { state != .closed }

    mutating func handle(_ event: Event) -> Effect {
        switch (state, event) {
        case (.closed, .toggle), (.closed, .show):
            return open(.command, sticky: true)
        case (.closed, .hoverDwelled):
            return open(.hover, sticky: false)
        case (.closed, .dragEnteredZone):
            return open(.drag, sticky: false)
        case (.closed, _):
            return .none

        case (.open, .toggle):
            return close(.toggled)
        case (.open(let trigger, _), .show):
            state = .open(trigger: trigger, sticky: true)
            outsideSince = nil
            return .refresh
        case (.open, .hoverDwelled), (.open, .dragEnteredZone):
            return .none
        case (.open(let trigger, let sticky), .pointer(let inRegion, let now)):
            guard !sticky else { outsideSince = nil; return .none }
            if inRegion { outsideSince = nil; return .none }
            guard let since = outsideSince else { outsideSince = now; return .none }
            if now.timeIntervalSince(since) >= Self.leaveTolerance { return close(.pointerLeft) }
            state = .open(trigger: trigger, sticky: false)
            return .none
        case (.open(let trigger, _), .interacted):
            state = .open(trigger: trigger, sticky: true)
            outsideSince = nil
            return .none
        case (.open, .clickOutside): return close(.clickOutside)
        case (.open, .escape): return close(.escape)
        case (.open, .dropCompleted): return close(.dropCompleted)
        case (.open, .otherPanelOpened): return close(.otherPanel)
        case (.open, .used): return close(.used)
        case (.open, .sectionsOff): return close(.sectionsOff)
        }
    }

    /// The panel was closed from outside the machine (e.g. `stop()`).
    mutating func reset() {
        state = .closed
        outsideSince = nil
    }

    private mutating func open(_ trigger: ShelfOpenTrigger, sticky: Bool) -> Effect {
        state = .open(trigger: trigger, sticky: sticky)
        outsideSince = nil
        return .open(trigger)
    }

    private mutating func close(_ reason: ShelfCloseReason) -> Effect {
        state = .closed
        outsideSince = nil
        return .close(reason)
    }
}

/// Background work the shelf runs, derived from its settings. Pure, testable: with every
/// section off, the plan is empty.
nonisolated enum ShelfActivity: String, Sendable, CaseIterable, Comparable {
    /// Polls the pasteboard change count (clipboard history on, not paused).
    case clipboardMonitor = "clipboard-monitor"
    /// One-shot timer that ends a pause.
    case clipboardResumeTimer = "clipboard-resume-timer"
    /// Pointer-moved monitor for resting on the notch / top centre.
    case hoverMonitor = "hover-monitor"
    /// Mouse down/drag monitors for files dragged to the hot zone.
    case dragMonitor = "drag-monitor"
    /// One-shot timer at the next file expiry.
    case fileExpiryTimer = "file-expiry-timer"

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

nonisolated struct ShelfActivityInput: Sendable, Equatable {
    var clipboardEnabled = false
    var clipboardPaused = false
    var filesEnabled = false
    var upNextEnabled = false
    var openOnHover = false
    var openOnDrag = true
    var fileLifetime: TimeInterval?
    var hasFiles = false
}

nonisolated enum ShelfActivityPlan {
    static func activities(_ input: ShelfActivityInput) -> Set<ShelfActivity> {
        var result: Set<ShelfActivity> = []
        let anySection = input.clipboardEnabled || input.filesEnabled || input.upNextEnabled
        if input.clipboardEnabled {
            result.insert(input.clipboardPaused ? .clipboardResumeTimer : .clipboardMonitor)
        }
        if input.openOnHover, anySection { result.insert(.hoverMonitor) }
        if input.openOnDrag, input.filesEnabled { result.insert(.dragMonitor) }
        if input.filesEnabled, input.hasFiles, input.fileLifetime != nil { result.insert(.fileExpiryTimer) }
        return result
    }
}
