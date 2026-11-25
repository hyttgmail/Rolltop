import CoreGraphics
import Foundation
import Testing
@testable import Rolltop

@Suite struct ScrollGestureRecognizerTests {
    private typealias Sample = ScrollGestureRecognizer.Sample

    @Test func downRevealsOncePerGesture() {
        let recognizer = ScrollHarness()
        #expect(recognizer.feed(Sample(dy: 6, time: 0.00)) == nil)
        #expect(recognizer.feed(Sample(dy: 6, time: 0.02)) == nil)
        #expect(recognizer.feed(Sample(dy: 6, time: 0.04)) == .reveal)
        // The same gesture keeps going: nothing more.
        #expect(recognizer.feed(Sample(dy: 30, time: 0.06)) == nil)
        // After a quiet gap a new gesture fires again (the controller turns it into "show all").
        #expect(recognizer.feed(Sample(dy: 20, time: 0.60)) == .reveal)
    }

    @Test func upCollapsesLeftRevealsRightCollapses() {
        let up = ScrollHarness()
        #expect(up.feed(Sample(dy: -20, time: 0)) == .collapse)
        let left = ScrollHarness()
        #expect(left.feed(Sample(dx: -20, dy: 0, time: 0)) == .reveal)
        let right = ScrollHarness()
        #expect(right.feed(Sample(dx: 20, dy: 0, time: 0)) == .collapse)
    }

    @Test func smallOrDiagonalScrollsDoNothing() {
        let small = ScrollHarness()
        #expect(small.feed(Sample(dy: 10, time: 0)) == nil)
        #expect(small.feed(Sample(dy: 4, time: 1.0)) == nil)   // new gesture, still below threshold
        let diagonal = ScrollHarness()
        #expect(diagonal.feed(Sample(dx: 18, dy: 18, time: 0)) == nil)
    }

    @Test func gestureThatStartsOutsideTheBarNeverCounts() {
        let recognizer = ScrollHarness()
        // Scrolling a page, the pointer drifts into the bar mid-gesture.
        #expect(recognizer.feed(Sample(dy: 10, time: 0.00, inBar: false)) == nil)
        #expect(recognizer.feed(Sample(dy: 10, time: 0.05, inBar: true)) == nil)
        #expect(recognizer.feed(Sample(dy: 30, time: 0.10, inBar: true)) == nil)
        // A deliberate new gesture in the bar works.
        #expect(recognizer.feed(Sample(dy: 20, time: 1.00, inBar: true)) == .reveal)
    }

    @Test func leavingTheBarCancelsTheGesture() {
        let recognizer = ScrollHarness()
        #expect(recognizer.feed(Sample(dy: 10, time: 0.00)) == nil)
        #expect(recognizer.feed(Sample(dy: 10, time: 0.05, inBar: false)) == nil)
        #expect(recognizer.feed(Sample(dy: 10, time: 0.10)) == nil)
    }

    @Test func momentumIsIgnored() {
        let recognizer = ScrollHarness()
        #expect(recognizer.feed(Sample(dy: 40, time: 0, phase: .momentum)) == nil)
    }

    @Test func trackpadPhasesDelimitGestures() {
        let recognizer = ScrollHarness()
        #expect(recognizer.feed(Sample(dy: 4, time: 0.00, phase: .began)) == nil)
        #expect(recognizer.feed(Sample(dy: 14, time: 0.01, phase: .changed)) == .reveal)
        #expect(recognizer.feed(Sample(dy: 14, time: 0.02, phase: .changed)) == nil)
        #expect(recognizer.feed(Sample(dy: 0, time: 0.03, phase: .ended)) == nil)
        // Inertia, then a new gesture within the quiet gap: phases, not time, separate them.
        #expect(recognizer.feed(Sample(dy: 30, time: 0.05, phase: .momentum)) == nil)
        #expect(recognizer.feed(Sample(dy: -8, time: 0.10, phase: .began)) == nil)
        #expect(recognizer.feed(Sample(dy: -10, time: 0.11, phase: .changed)) == .collapse)
    }

    @Test func reversalRestartsTheCount() {
        let recognizer = ScrollHarness()
        #expect(recognizer.feed(Sample(dy: 12, time: 0.00)) == nil)
        #expect(recognizer.feed(Sample(dy: -12, time: 0.02)) == nil)
        #expect(recognizer.feed(Sample(dy: -6, time: 0.04)) == .collapse)
    }

    @Test func physicalDirectionFollowsTheDevice() {
        // Natural scrolling: content follows the fingers, the delta already is physical.
        #expect(ScrollGestureRecognizer.physicalDelta(scrollingDelta: 5, invertedFromDevice: true, precise: true) == 5)
        // Classic wheel: rolling toward you scrolls down (negative delta) and moves the wheel down.
        #expect(ScrollGestureRecognizer.physicalDelta(scrollingDelta: -1, invertedFromDevice: false, precise: false) == 8)
    }
}

@Suite struct HoverDwellTests {
    @Test func firesAfterTheDelayOncePerVisit() {
        let dwell = HoverHarness(delay: 0.3)
        #expect(!dwell.update(inBar: true, suspended: false, at: 0.0))
        #expect(dwell.nextCheck == 0.3)
        #expect(!dwell.update(inBar: true, suspended: false, at: 0.2))
        #expect(dwell.update(inBar: true, suspended: false, at: 0.31))
        #expect(!dwell.update(inBar: true, suspended: false, at: 1.0))
        #expect(dwell.nextCheck == nil)
        // Leave and come back: a new visit.
        #expect(!dwell.update(inBar: false, suspended: false, at: 2.0))
        #expect(!dwell.update(inBar: true, suspended: false, at: 2.1))
        #expect(dwell.update(inBar: true, suspended: false, at: 2.45))
    }

    @Test func shortExcursionsKeepTheVisit() {
        let dwell = HoverHarness(delay: 0.5, leaveTolerance: 0.25)
        #expect(!dwell.update(inBar: true, suspended: false, at: 0.0))
        #expect(!dwell.update(inBar: false, suspended: false, at: 0.1))
        #expect(dwell.update(inBar: true, suspended: false, at: 0.5))
    }

    @Test func longExcursionRestartsTheWait() {
        let dwell = HoverHarness(delay: 0.5, leaveTolerance: 0.25)
        #expect(!dwell.update(inBar: true, suspended: false, at: 0.0))
        #expect(!dwell.update(inBar: false, suspended: false, at: 0.4))
        #expect(!dwell.update(inBar: true, suspended: false, at: 0.6))
        #expect(!dwell.update(inBar: true, suspended: false, at: 1.0))
        #expect(dwell.update(inBar: true, suspended: false, at: 1.1))
    }

    @Test func commandSuspendsAndRestartsTheWait() {
        let dwell = HoverHarness(delay: 0.3)
        #expect(!dwell.update(inBar: true, suspended: true, at: 0.0))
        #expect(!dwell.update(inBar: true, suspended: true, at: 1.0))
        #expect(!dwell.update(inBar: true, suspended: false, at: 1.2))
        #expect(dwell.update(inBar: true, suspended: false, at: 1.5))
    }

    @Test func zeroDelayFiresAtOnce() {
        let dwell = HoverHarness(delay: 0)
        #expect(dwell.update(inBar: true, suspended: false, at: 0))
    }

    @Test func rearmAllowsAnotherAttemptAfterMoreMovement() {
        let dwell = HoverHarness(delay: 0.3)
        _ = dwell.update(inBar: true, suspended: false, at: 0)
        #expect(dwell.update(inBar: true, suspended: false, at: 0.3))
        dwell.rearm(at: 0.35)
        #expect(!dwell.update(inBar: true, suspended: false, at: 0.5))
        #expect(dwell.update(inBar: true, suspended: false, at: 0.7))
    }
}

/// `#expect` cannot call mutating members; these hold the value types by reference.
final class ScrollHarness {
    private var recognizer = ScrollGestureRecognizer()
    func feed(_ sample: ScrollGestureRecognizer.Sample) -> ScrollGestureRecognizer.Decision? { recognizer.feed(sample) }
}

final class HoverHarness {
    private var dwell: HoverDwell
    init(delay: TimeInterval, leaveTolerance: TimeInterval = 0.25) { dwell = HoverDwell(delay: delay, leaveTolerance: leaveTolerance) }
    func update(inBar: Bool, suspended: Bool, at now: TimeInterval) -> Bool { dwell.update(inBar: inBar, suspended: suspended, at: now) }
    func rearm(at now: TimeInterval) { dwell.rearm(at: now) }
    var nextCheck: TimeInterval? { dwell.nextCheck }
}
