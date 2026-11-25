import Foundation
import RolltopCore
import Testing
@testable import Rolltop

@Suite struct RehideMachineTests {
    private typealias Blockers = RehideMachine.Blockers
    private let idle = Blockers()
    private let pointerInBar = Blockers(pointerInBar: true)
    private let menuOpen = Blockers(menuOpen: true)
    private let busy = Blockers(interactionActive: true)

    private func machine(delay: TimeInterval? = 10, clickOutside: Bool = true, appSwitch: Bool = false) -> RehideHarness {
        RehideHarness(RehideMachine(config: .init(delay: delay, collapseOnClickOutside: clickOutside, collapseOnAppSwitch: appSwitch)))
    }

    @Test func collapsesAfterTheDelay() {
        let rehide = machine()
        rehide.revealed(origin: .click, at: 100)
        #expect(rehide.tick(idle, at: 105) == nil)
        #expect(rehide.deadline == 110)
        #expect(rehide.tick(idle, at: 110) == .timer)
    }

    @Test func pointerInTheBarHoldsAndRestartsTheClock() {
        let rehide = machine()
        rehide.revealed(origin: .click, at: 0)
        #expect(rehide.tick(pointerInBar, at: 9) == nil)
        #expect(rehide.tick(pointerInBar, at: 30) == nil)
        // Measured from when the pointer left.
        #expect(rehide.tick(idle, at: 31) == nil)
        #expect(rehide.tick(idle, at: 39.9) == nil)
        #expect(rehide.tick(idle, at: 40) == .timer)
    }

    @Test func openMenusAndBusyInteractionsHold() {
        let rehide = machine(delay: 5)
        rehide.revealed(origin: .other, at: 0)
        #expect(rehide.tick(menuOpen, at: 60) == nil)
        #expect(rehide.tick(busy, at: 120) == nil)
        #expect(rehide.tick(idle, at: 124) == nil)
        #expect(rehide.tick(idle, at: 125) == .timer)
    }

    @Test func neverMeansNoTimer() {
        let rehide = machine(delay: nil)
        rehide.revealed(origin: .click, at: 0)
        #expect(rehide.tick(idle, at: 10_000) == nil)
        #expect(rehide.deadline == nil)
    }

    @Test func clickOutside() {
        let rehide = machine()
        #expect(rehide.clickOutside(idle, at: 1) == nil)              // collapsed: nothing to do
        rehide.revealed(origin: .click, at: 0)
        #expect(rehide.clickOutside(menuOpen, at: 1) == nil)          // only closes the menu
        #expect(rehide.clickOutside(busy, at: 2) == nil)
        #expect(rehide.clickOutside(idle, at: 3) == .clickOutside)
        let off = machine(clickOutside: false)
        off.revealed(origin: .click, at: 0)
        #expect(off.clickOutside(idle, at: 3) == nil)
    }

    @Test func clickOutsideWhileAMenuWasOpenRestartsTheClock() {
        let rehide = machine(delay: 5)
        rehide.revealed(origin: .click, at: 0)
        #expect(rehide.clickOutside(menuOpen, at: 4) == nil)
        #expect(rehide.tick(idle, at: 8) == nil)
        #expect(rehide.tick(idle, at: 9) == .timer)
    }

    @Test func appSwitch() {
        let rehide = machine(appSwitch: true)
        rehide.revealed(origin: .click, at: 0)
        // The user clicked an item that opens its own app.
        rehide.barClicked(at: 5)
        #expect(rehide.appSwitched(idle, at: 5.5) == nil)
        #expect(rehide.appSwitched(menuOpen, at: 8) == nil)
        #expect(rehide.appSwitched(idle, at: 8) == .appSwitch)
        let off = machine(appSwitch: false)
        off.revealed(origin: .click, at: 0)
        #expect(off.appSwitched(idle, at: 8) == nil)
    }

    @Test func hoverRevealEndsWhenThePointerLeaves() {
        let rehide = machine(delay: 30)
        rehide.revealed(origin: .hover, at: 0)
        #expect(rehide.tick(pointerInBar, at: 1) == nil)
        #expect(rehide.tick(idle, at: 1.25) == nil)
        #expect(rehide.tick(pointerInBar, at: 1.5) == nil)   // back within the tolerance
        #expect(rehide.tick(idle, at: 1.75) == nil)
        #expect(rehide.tick(idle, at: 2.0) == nil)
        #expect(rehide.tick(idle, at: 2.4) == .pointerLeft)
    }

    @Test func hoverRevealWaitsForAnOpenMenu() {
        let rehide = machine(delay: 30)
        rehide.revealed(origin: .hover, at: 0)
        #expect(rehide.tick(menuOpen, at: 1) == nil)
        #expect(rehide.tick(menuOpen, at: 20) == nil)
        #expect(rehide.tick(idle, at: 20.25) == nil)
        #expect(rehide.tick(idle, at: 20.9) == .pointerLeft)
    }

    @Test func keepIgnoresEveryPolicy() {
        let rehide = machine(delay: 5, clickOutside: true, appSwitch: true)
        rehide.revealed(origin: .keep, at: 0)
        #expect(rehide.tick(idle, at: 1000) == nil)
        #expect(rehide.clickOutside(idle, at: 1000) == nil)
        #expect(rehide.appSwitched(idle, at: 1000) == nil)
        #expect(rehide.deadline == nil)
    }

    @Test func collapsedStopsEverything() {
        let rehide = machine(delay: 5)
        rehide.revealed(origin: .click, at: 0)
        rehide.collapsed()
        #expect(!rehide.isRevealed)
        #expect(rehide.tick(idle, at: 100) == nil)
    }
}

@Suite struct RevealModesTests {
    private func conceal(hideEverything: Bool = false, makeRoom: Bool = false, scope: RevealModes.MakeRoomScope = .always,
                         level: PresentationLevel, notch: Bool = false) -> Bool {
        RevealModes.concealShown(hideEverything: hideEverything, makeRoom: makeRoom, scope: scope,
                                 level: level, revealDisplayHasNotch: notch)
    }

    @Test func makeRoomOnlyWhileRevealed() {
        #expect(!conceal(makeRoom: true, level: .collapsed))
        #expect(conceal(makeRoom: true, level: .hiddenRevealed))
        #expect(conceal(makeRoom: true, level: .allRevealed))
        #expect(!conceal(makeRoom: false, level: .hiddenRevealed))
    }

    @Test func notchScopeFollowsTheRevealDisplay() {
        #expect(!conceal(makeRoom: true, scope: .notchedDisplays, level: .hiddenRevealed, notch: false))
        #expect(conceal(makeRoom: true, scope: .notchedDisplays, level: .hiddenRevealed, notch: true))
    }

    @Test func hideEverythingAtEveryLevel() {
        for level in PresentationLevel.allCases {
            #expect(conceal(hideEverything: true, level: level))
        }
    }
}

/// `#expect` cannot call mutating members; this holds the machine by reference.
final class RehideHarness {
    private var machine: RehideMachine
    init(_ machine: RehideMachine) { self.machine = machine }
    func revealed(origin: RehideMachine.Origin, at now: TimeInterval) { machine.revealed(origin: origin, at: now) }
    func collapsed() { machine.collapsed() }
    func barClicked(at now: TimeInterval) { machine.barClicked(at: now) }
    func tick(_ blockers: RehideMachine.Blockers, at now: TimeInterval) -> RehideMachine.Reason? { machine.tick(blockers, at: now) }
    func clickOutside(_ blockers: RehideMachine.Blockers, at now: TimeInterval) -> RehideMachine.Reason? { machine.clickOutside(blockers, at: now) }
    func appSwitched(_ blockers: RehideMachine.Blockers, at now: TimeInterval) -> RehideMachine.Reason? { machine.appSwitched(blockers, at: now) }
    var deadline: TimeInterval? { machine.deadline }
    var isRevealed: Bool { machine.isRevealed }
}
