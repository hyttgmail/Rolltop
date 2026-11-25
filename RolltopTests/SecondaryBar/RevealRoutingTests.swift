import Foundation
import RolltopCore
import Testing
@testable import Rolltop

@Suite struct RevealAnchorArgumentTests {
    private let pointer = CGPoint(x: 100, y: 200)

    private func anchor(_ arguments: [String: String], source: CommandSource) throws -> PanelAnchor {
        try RevealAnchorArgument.anchor(for: CommandInvocation(arguments: arguments, source: source),
                                        pointerLocation: { pointer })
    }

    @Test func defaultsDependOnSource() throws {
        guard case .statusItem = try anchor([:], source: .statusMenu) else { Issue.record("status menu"); return }
        guard case .point(let p) = try anchor([:], source: .url) else { Issue.record("url"); return }
        #expect(p == pointer)
        guard case .point = try anchor([:], source: .hotkey) else { Issue.record("hotkey"); return }
    }

    @Test func explicitValuesWin() throws {
        guard case .statusItem = try anchor(["anchor": "status-item"], source: .url) else { Issue.record("status-item"); return }
        guard case .point = try anchor(["anchor": "pointer"], source: .statusMenu) else { Issue.record("pointer"); return }
        #expect(throws: CommandError.invalidArgument("anchor", "nowhere")) {
            try anchor(["anchor": "nowhere"], source: .url)
        }
    }
}

@Suite struct RevealRoutePlannerTests {
    typealias P = RevealRoutePlanner

    /// Notch-only and when-full refine the main switch per display.
    @Test func rolltopBarPerDisplay() {
        func uses(_ enabled: Bool, notchOnly: Bool, full: Bool, notch: Bool, overflows: Bool) -> Bool {
            P.usesRolltopBar(enabled: enabled, onlyWithNotch: notchOnly, whenFull: full, hasNotch: notch, overflows: overflows)
        }
        #expect(uses(true, notchOnly: false, full: false, notch: false, overflows: false))
        #expect(!uses(false, notchOnly: false, full: false, notch: true, overflows: true))
        // Notch-only: inline on a display without a notch, the panel on one with it.
        #expect(!uses(true, notchOnly: true, full: false, notch: false, overflows: false))
        #expect(uses(true, notchOnly: true, full: false, notch: true, overflows: false))
        // When full: the chevron wins over notch-only and over the main switch.
        #expect(uses(true, notchOnly: true, full: true, notch: false, overflows: true))
        #expect(uses(false, notchOnly: false, full: true, notch: false, overflows: true))
        #expect(!uses(false, notchOnly: false, full: true, notch: true, overflows: false))
    }

    /// "When full", second case: watch an inline hidden reveal, switch once the chevron shows
    /// up while it is still up; never for Show All Items or a reveal that already ended.
    @Test func inlineRevealSwitchesAfterOverflow() {
        #expect(P.watchesForOverflow(whenFull: true, request: .toggle, usedRolltopBar: false, level: .hiddenRevealed))
        #expect(!P.watchesForOverflow(whenFull: false, request: .toggle, usedRolltopBar: false, level: .hiddenRevealed))
        #expect(!P.watchesForOverflow(whenFull: true, request: .show, usedRolltopBar: true, level: .collapsed))
        #expect(!P.watchesForOverflow(whenFull: true, request: .toggle, usedRolltopBar: false, level: .collapsed))
        #expect(P.switchesAfterOverflow(whenFull: true, level: .hiddenRevealed, chevron: true))
        #expect(!P.switchesAfterOverflow(whenFull: true, level: .hiddenRevealed, chevron: false))
        #expect(!P.switchesAfterOverflow(whenFull: true, level: .allRevealed, chevron: true))
        #expect(!P.switchesAfterOverflow(whenFull: true, level: .collapsed, chevron: true))
    }

    /// A remembered display counts as overflowing until the switch goes off or its key changes.
    @Test func rememberedOverflowIsForgottenOnChange() {
        #expect(P.remembered(1, whenFull: true, current: 1) == 1)
        #expect(P.remembered(1, whenFull: true, current: 2) == nil)
        #expect(P.remembered(1, whenFull: false, current: 1) == nil)
        #expect(P.remembered(Int?.none, whenFull: true, current: 1) == nil)
        // Remembered → the next reveal there uses the Rolltop Bar even without the main switch.
        #expect(P.usesRolltopBar(enabled: false, onlyWithNotch: false, whenFull: true, hasNotch: true, overflows: true))
    }

    @Test func settingOffKeepsInlineBehaviour() {
        #expect(P.plan(.toggle, useRolltopBar: false, panelVisible: false, level: .collapsed, justDismissedByClick: false) == [.engineToggle])
        #expect(P.plan(.show, useRolltopBar: false, panelVisible: false, level: .collapsed, justDismissedByClick: false) == [.engineShow])
        #expect(P.plan(.collapse, useRolltopBar: false, panelVisible: false, level: .hiddenRevealed, justDismissedByClick: false) == [.engineCollapse])
        // A panel left open when the setting changed closes on the next command.
        #expect(P.plan(.toggle, useRolltopBar: false, panelVisible: true, level: .collapsed, justDismissedByClick: false) == [.dismissPanel, .engineToggle])
    }

    @Test func toggleOpensAndClosesThePanel() {
        #expect(P.plan(.toggle, useRolltopBar: true, panelVisible: false, level: .collapsed, justDismissedByClick: false) == [.presentPanel])
        #expect(P.plan(.toggle, useRolltopBar: true, panelVisible: true, level: .collapsed, justDismissedByClick: false) == [.dismissPanel])
    }

    @Test func toggleAfterOutsideClickDismissalDoesNotReopen() {
        #expect(P.plan(.toggle, useRolltopBar: true, panelVisible: false, level: .collapsed, justDismissedByClick: true) == [])
        // show-hidden is explicit: it opens again.
        #expect(P.plan(.show, useRolltopBar: true, panelVisible: false, level: .collapsed, justDismissedByClick: true) == [.presentPanel])
    }

    @Test func inlineRevealedItemsAreCollapsedNotDuplicated() {
        #expect(P.plan(.toggle, useRolltopBar: true, panelVisible: false, level: .allRevealed, justDismissedByClick: false) == [.engineCollapse])
        #expect(P.plan(.show, useRolltopBar: true, panelVisible: false, level: .hiddenRevealed, justDismissedByClick: false) == [.engineCollapse, .presentPanel])
    }

    @Test func collapseDismissesAndCollapses() {
        #expect(P.plan(.collapse, useRolltopBar: true, panelVisible: true, level: .collapsed, justDismissedByClick: false) == [.dismissPanel, .engineCollapse])
        #expect(P.plan(.collapse, useRolltopBar: true, panelVisible: false, level: .collapsed, justDismissedByClick: false) == [.engineCollapse])
    }

    @Test func ownersOfASectionArePresentAssignableAndNotOwn() {
        func entry(_ id: String, section: Section?, items: Int = 1, own: Bool = false, owner: OwnerID? = nil) -> CatalogEntry {
            CatalogEntry(id: id, kind: owner == nil && section == nil ? .macOSManaged : .app,
                         owner: owner ?? (section == nil ? nil : .app(id)), displayName: id, section: section,
                         hasExplicitSection: true, itemCount: items, pids: [], axIdentifiers: [], slots: [],
                         lastKnownFrames: [], runsOutsideApplications: false, isUnreadable: false, isOwn: own,
                         isCarriedOver: false)
        }
        let entries = [
            entry("com.a", section: .hidden),
            entry("com.shown", section: .shown),
            entry("com.gone", section: .hidden, items: 0),
            entry("com.alphapengwang.rolltop", section: .hidden, own: true),
            entry("managed:airdrop", section: nil),
            entry("com.b", section: .hidden, items: 2),
            entry("com.always", section: .alwaysHidden),
        ]
        #expect(P.owners(in: .hidden, entries: entries) == [.app("com.a"), .app("com.b")])
        #expect(P.owners(in: .alwaysHidden, entries: entries) == [.app("com.always")])
        // An automation forces com.a visible: it is in the menu bar, not in the panel.
        #expect(P.owners(in: .hidden, entries: entries, excluding: [.app("com.a")]) == [.app("com.b")])
    }
}

@Suite struct RevealGestureTriggerTests {
    @Test func gesturesDecideHowThePanelCloses() {
        #expect(RolltopBarPresenter.trigger(for: RevealGesture.click) == .pointerClick)
        #expect(RolltopBarPresenter.trigger(for: RevealGesture.hover) == .pointerHover)
        #expect(RolltopBarPresenter.trigger(for: RevealGesture.scroll) == .pointerHover)
        #expect(RolltopBarPresenter.trigger(for: ItemPanelGesture.click) == .pointerClick)
        #expect(RolltopBarPresenter.trigger(for: ItemPanelGesture.hover) == .pointerHover)
        #expect(RolltopBarPresenter.trigger(for: ItemPanelGesture.keyboard) == .keyboard)
        #expect(RevealController.gesture(for: .click) == .click)
        #expect(RevealController.gesture(for: .keep) == nil)
    }

    @Test func gestureArgumentParses() throws {
        #expect(try RevealAnchorArgument.gesture(for: CommandInvocation(arguments: ["gesture": "hover"])) == .hover)
        #expect(try RevealAnchorArgument.gesture(for: CommandInvocation()) == nil)
        #expect(throws: CommandError.invalidArgument("gesture", "wave")) {
            try RevealAnchorArgument.gesture(for: CommandInvocation(arguments: ["gesture": "wave"]))
        }
    }
}
