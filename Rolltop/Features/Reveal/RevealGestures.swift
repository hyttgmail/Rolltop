import CoreGraphics
import Foundation

// Gesture recognition for the scroll and hover triggers. Pure: a stream of samples
// (deltas, positions, timestamps) in, a decision out.

/// Turns scroll-wheel and trackpad deltas into one decision per gesture.
///
/// Deltas are physical: positive `dx` is a movement to the right and positive `dy` a
/// movement down, whatever the natural-scrolling setting (the caller undoes the inversion).
/// Down or left reveals, up or right collapses. A gesture counts only if it starts in the
/// menu bar and stays there, never on momentum, and only past a threshold, so scrolling a
/// page past the bar does nothing.
nonisolated struct ScrollGestureRecognizer: Sendable {
    enum Phase: Sendable, Equatable {
        /// Scroll wheel or synthetic event: gestures are separated by a quiet gap.
        case none
        case began
        case changed
        case ended
        case cancelled
        /// Inertia after the fingers lifted.
        case momentum
    }

    enum Decision: String, Sendable, Equatable {
        /// Down or left.
        case reveal
        /// Up or right.
        case collapse
    }

    struct Sample: Sendable, Equatable {
        var dx: CGFloat
        var dy: CGFloat
        var time: TimeInterval
        var phase: Phase
        /// The pointer is in a menu bar strip, away from status items.
        var inBar: Bool

        init(dx: CGFloat = 0, dy: CGFloat, time: TimeInterval, phase: Phase = .none, inBar: Bool = true) {
            self.dx = dx
            self.dy = dy
            self.time = time
            self.phase = phase
            self.inBar = inBar
        }
    }

    struct Tuning: Sendable, Equatable {
        /// Travel along the dominant axis, in points, before a gesture fires.
        var threshold: CGFloat = 16
        /// The dominant axis must exceed the other one by this factor.
        var dominance: CGFloat = 1.5
        /// A pause this long ends a phase-less gesture.
        var quietGap: TimeInterval = 0.35
    }

    var tuning = Tuning()

    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var lastTime: TimeInterval?
    /// Nil before the first sample; false once the gesture is disqualified.
    private var valid: Bool?
    private var fired = false

    init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    mutating func reset() {
        accumulatedX = 0
        accumulatedY = 0
        lastTime = nil
        valid = nil
        fired = false
    }

    mutating func feed(_ sample: Sample) -> Decision? {
        if sample.phase == .momentum { return nil }
        let startsGesture: Bool = switch sample.phase {
        case .began: true
        case .none: lastTime.map { sample.time - $0 > tuning.quietGap } ?? true
        default: valid == nil
        }
        if startsGesture {
            accumulatedX = 0
            accumulatedY = 0
            fired = false
            valid = sample.inBar
        }
        lastTime = sample.time
        if sample.phase == .ended || sample.phase == .cancelled {
            valid = nil
            lastTime = nil
            return nil
        }
        // Leaving the bar disqualifies the rest of the gesture.
        if !sample.inBar { valid = false }
        guard valid == true, !fired else { return nil }

        if accumulatedX != 0, sample.dx != 0, (accumulatedX < 0) != (sample.dx < 0) { accumulatedX = 0 }
        if accumulatedY != 0, sample.dy != 0, (accumulatedY < 0) != (sample.dy < 0) { accumulatedY = 0 }
        accumulatedX += sample.dx
        accumulatedY += sample.dy

        let absX = abs(accumulatedX)
        let absY = abs(accumulatedY)
        if absY >= tuning.threshold, absY >= tuning.dominance * absX {
            fired = true
            return accumulatedY > 0 ? .reveal : .collapse
        }
        if absX >= tuning.threshold, absX >= tuning.dominance * absY {
            fired = true
            return accumulatedX < 0 ? .reveal : .collapse
        }
        return nil
    }

    /// Physical deltas from AppKit's content-relative `scrollingDelta*`: with natural
    /// scrolling the content follows the fingers, so the sign already is physical.
    /// Line-based wheels report lines; `lineHeight` converts them to points.
    static func physicalDelta(scrollingDelta: CGFloat, invertedFromDevice: Bool, precise: Bool,
                              lineHeight: CGFloat = 8) -> CGFloat {
        let points = precise ? scrollingDelta : scrollingDelta * lineHeight
        return invertedFromDevice ? points : -points
    }
}

/// Hover reveal: the pointer has to rest in the bar for `delay` before it fires; brief
/// excursions out of the bar (up to `leaveTolerance`) do not restart the wait. Fires once
/// per visit: the pointer must leave the bar before it can fire again.
nonisolated struct HoverDwell: Sendable {
    var delay: TimeInterval
    var leaveTolerance: TimeInterval

    private(set) var enteredAt: TimeInterval?
    private var lastInside: TimeInterval?
    private(set) var fired = false

    init(delay: TimeInterval, leaveTolerance: TimeInterval = 0.25) {
        self.delay = delay
        self.leaveTolerance = leaveTolerance
    }

    mutating func reset() {
        enteredAt = nil
        lastInside = nil
        fired = false
    }

    /// Feed the pointer state; true when the hover should reveal now.
    /// `suspended`: ⌘ is held (the user is rearranging items) or Rolltop is busy.
    mutating func update(inBar: Bool, suspended: Bool, at now: TimeInterval) -> Bool {
        if inBar {
            if enteredAt == nil { enteredAt = now }
            lastInside = now
        } else if let last = lastInside, now - last <= leaveTolerance {
            // A short excursion: keep the visit.
        } else {
            reset()
            return false
        }
        if suspended {
            // Holding ⌘ restarts the wait once it is released.
            enteredAt = inBar ? now : nil
            return false
        }
        guard !fired, inBar, let enteredAt, now - enteredAt >= delay else { return false }
        fired = true
        return true
    }

    /// The reveal was refused at this spot (e.g. over the app menus): allow another attempt
    /// after a further `delay` of movement in the bar.
    mutating func rearm(at now: TimeInterval) {
        guard enteredAt != nil else { return }
        fired = false
        enteredAt = now
    }

    /// When to call `update` again if the pointer does not move, nil when nothing is pending.
    var nextCheck: TimeInterval? {
        guard !fired, let enteredAt else { return nil }
        return enteredAt + delay
    }
}
