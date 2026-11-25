import CoreGraphics
import Foundation
import RolltopCore
import Testing
@testable import Rolltop

@Suite struct LayoutEditorModelTests {
    // Two displays as on the test machine: main 2304 pt wide at x 0, built-in to its right.
    static let mainID: UInt32 = 1
    static let builtInID: UInt32 = 2
    static let mainBar = CGRect(x: 0, y: 0, width: 2304, height: 30)
    static let builtInBar = CGRect(x: 2304, y: -37, width: 1728, height: 33)

    private func slot(_ x: CGFloat, display: UInt32 = mainID, width: CGFloat = 30, overflowed: Bool = false) -> DrawnSlotRecord {
        DrawnSlotRecord(displayID: display, frame: CGRect(x: x, y: 0, width: width, height: 24), ownerPID: 1, ownerBundleID: nil,
                        axIdentifier: nil, isOverflowed: overflowed)
    }

    private func entry(_ id: String, kind: CatalogEntry.Kind = .app, owner: OwnerID? = nil, itemCount: Int = 1,
                       slots: [DrawnSlotRecord] = [], frames: [CGRect] = [], outside: Bool = false,
                       unreadable: Bool = false, own: Bool = false) -> CatalogEntry {
        let resolvedOwner: OwnerID? = owner ?? (kind == .app ? .app(id) : nil)
        return CatalogEntry(id: id, kind: kind, owner: resolvedOwner, displayName: id, section: .shown,
                            hasExplicitSection: false, itemCount: itemCount, pids: [1], axIdentifiers: [],
                            slots: slots, lastKnownFrames: frames, runsOutsideApplications: outside,
                            isUnreadable: unreadable, isOwn: own, isCarriedOver: false)
    }

    private func snapshot(main: [DrawnSlotRecord] = [], builtIn: [DrawnSlotRecord]? = nil, readable: Bool = true) -> DrawnSnapshot {
        var displays = [DisplayBarRecord(displayID: Self.mainID, isMain: true, barFrame: Self.mainBar, chevronFrame: nil,
                                         chevronExpanded: false, slots: main)]
        if let builtIn {
            displays.append(DisplayBarRecord(displayID: Self.builtInID, isMain: false, barFrame: Self.builtInBar,
                                             chevronFrame: nil, chevronExpanded: false, slots: builtIn))
        }
        return DrawnSnapshot(displays: displays, capturedAt: Date(), isReadable: readable)
    }

    // MARK: Grouping

    @Test func shelvesFollowTheLayoutNotTheEntry() {
        let layout = Layout(sections: [.app("com.b"): .hidden, .system(.wifi): .alwaysHidden, .app("com.gone"): .hidden],
                            defaultSection: .shown)
        let entries = [
            entry("com.a", slots: [slot(2000)]),
            entry("com.b", slots: [slot(2050)]),   // entry.section says shown: the layout wins
            entry("system:wifi", kind: .system, owner: .system(.wifi), slots: [slot(2100)]),
            entry("managed:com.apple.menuextra.airdrop", kind: .macOSManaged),
            entry("pid:42", kind: .unidentified),
            entry("com.alphapengwang.rolltop", slots: [slot(1900)], own: true),
        ]
        let board = LayoutEditorBoard.make(entries: entries, layout: layout, drawn: snapshot(main: []))
        #expect(board.shown.map(\.id) == ["com.alphapengwang.rolltop", "com.a"])
        #expect(board.hidden.map(\.id) == ["com.b"])
        #expect(board.alwaysHidden.map(\.id) == ["system:wifi"])
        #expect(board.managed.map(\.id) == ["managed:com.apple.menuextra.airdrop"])
        #expect(board.unidentified.map(\.id) == ["pid:42"])
        #expect(board.notRunning.map(\.id) == ["com.gone"])
        #expect(board.notRunning.first?.section == .hidden)
        // Rolltop itself sits on the Shown shelf but is neither movable nor counted.
        #expect(board.shown.first?.isMovable == false)
        #expect(board.movableCount(in: .shown) == 1)
        #expect(board.defaultSection == .shown)
    }

    @Test func ownItemIsShownWhateverTheLayoutSays() {
        let layout = Layout(sections: [.app("com.alphapengwang.rolltop"): .hidden], defaultSection: .hidden)
        let board = LayoutEditorBoard.make(entries: [entry("com.alphapengwang.rolltop", own: true)], layout: layout, drawn: snapshot())
        #expect(board.shown.map(\.id) == ["com.alphapengwang.rolltop"])
        #expect(board.hidden.isEmpty)
    }

    @Test func clustersMergeEntriesOfOneOwner() {
        let first = entry("com.a", itemCount: 2, slots: [slot(2000), slot(2030)])
        var second = entry("com.a", itemCount: 1, slots: [slot(2060)])
        second.pids = [2]
        second.isUnreadable = true
        let merged = LayoutEditorBoard.clusterByOwner([first, entry("com.b"), second])
        #expect(merged.map(\.id) == ["com.a", "com.b"])
        #expect(merged[0].itemCount == 3)
        #expect(merged[0].slots.count == 3)
        #expect(merged[0].pids == [1, 2])
        #expect(merged[0].isUnreadable)
        // A cluster is one chip: three items, one owner.
        let board = LayoutEditorBoard.make(entries: [first, second], layout: .empty, drawn: snapshot())
        #expect(board.shown.count == 1)
        #expect(board.shown[0].itemCount == 3)
        #expect(board.shown[0].notes.contains(.itemCount(3)))
    }

    @Test func itemCountIsAtLeastOne() {
        let board = LayoutEditorBoard.make(entries: [entry("com.a", itemCount: 0, unreadable: true)], layout: .empty, drawn: snapshot())
        #expect(board.shown.first?.itemCount == 1)
    }

    // MARK: Ordering

    @Test func shelvesFollowMenuBarOrderLeftToRight() {
        let entries = [
            entry("com.c", slots: [slot(2200)]),
            entry("com.a", slots: [slot(2000)]),
            entry("com.b", slots: [slot(2100)]),
        ]
        let board = LayoutEditorBoard.make(entries: entries, layout: .empty, drawn: snapshot())
        #expect(board.shown.map(\.id) == ["com.a", "com.b", "com.c"])
    }

    @Test func orderComparesDisplaysFromTheirTrailingEdge() {
        // com.x is drawn only on the built-in display, 200 pt from its trailing edge; on the
        // main display com.a is 304 pt and com.b 104 pt from the edge. Global x would put
        // com.x last; its real place is between them.
        let entries = [
            entry("com.a", slots: [slot(2000)]),
            entry("com.b", slots: [slot(2200)]),
            entry("com.x", slots: [slot(2304 + 1728 - 200, display: Self.builtInID)]),
        ]
        let board = LayoutEditorBoard.make(entries: entries, layout: .empty, drawn: snapshot(builtIn: []))
        #expect(board.shown.map(\.id) == ["com.a", "com.x", "com.b"])
    }

    @Test func mainDisplayWinsOverOtherDisplays() {
        let a = entry("com.a", slots: [slot(2000), slot(2304 + 1728 - 50, display: Self.builtInID)])
        #expect(LayoutEditorOrdering.trailingOffset(of: a, in: snapshot(builtIn: [])) == 304)
    }

    @Test func overflowedItemsSitAtTheLeftEdgeAndVisibleSlotsWin() {
        let chevronX: CGFloat = 1500
        let entries = [
            entry("com.a", slots: [slot(2000)]),
            entry("com.over", slots: [slot(chevronX, overflowed: true)]),
            entry("com.mixed", slots: [slot(chevronX, overflowed: true), slot(2100)]),
        ]
        let board = LayoutEditorBoard.make(entries: entries, layout: .empty, drawn: snapshot())
        #expect(board.shown.map(\.id) == ["com.over", "com.a", "com.mixed"])
        #expect(board.shown[0].drawState == .overflowed)
        #expect(board.shown[2].drawState == .drawn)
    }

    @Test func hiddenItemsKeepTheirLastPositionAndUnplacedOnesGoLast() {
        // Hidden: no slots, but the stale frame from the app's own list still places them.
        let entries = [
            entry("com.unplaced"),
            entry("com.b", frames: [CGRect(x: 2100, y: 0, width: 30, height: 24)]),
            entry("com.a", slots: [slot(2150)]),
            entry("com.c", frames: [CGRect(x: 2250, y: 0, width: 30, height: 24)]),
        ]
        let board = LayoutEditorBoard.make(entries: entries, layout: .empty, drawn: snapshot())
        #expect(board.shown.map(\.id) == ["com.b", "com.a", "com.c", "com.unplaced"])
        #expect(board.shown[0].drawState == .notDrawn)
        #expect(board.shown[0].notes.contains(.hiddenNow))
    }

    @Test func unreadableBarKeepsCatalogOrderAndClaimsNothing() {
        let entries = [entry("com.z"), entry("com.a")]
        let drawn = DrawnSnapshot.empty
        let board = LayoutEditorBoard.make(entries: entries, layout: .empty, drawn: drawn)
        #expect(board.shown.map(\.id) == ["com.z", "com.a"])
        #expect(board.shown.allSatisfy { $0.drawState == .unknown })
        #expect(board.shown.allSatisfy { !$0.notes.contains(.hiddenNow) })
    }

    // MARK: Notes

    @Test func notesStateLimitsWhereTheyApply() {
        let drawn = [slot(2000)]
        #expect(LayoutEditorNote.notes(for: entry("com.a", slots: drawn), drawnIsReadable: true) == [])
        #expect(LayoutEditorNote.notes(for: entry("com.a", itemCount: 3, slots: drawn), drawnIsReadable: true) == [.itemCount(3)])
        #expect(LayoutEditorNote.notes(for: entry("com.a"), drawnIsReadable: true) == [.hiddenNow])
        #expect(LayoutEditorNote.notes(for: entry("com.a"), drawnIsReadable: false) == [])
        #expect(LayoutEditorNote.notes(for: entry("com.a", outside: true), drawnIsReadable: true) == [.outsideApplications])
        #expect(LayoutEditorNote.notes(for: entry("com.a", slots: drawn, unreadable: true), drawnIsReadable: true) == [.unreadable])
        #expect(LayoutEditorNote.notes(for: entry("com.a", slots: [slot(1500, overflowed: true)]), drawnIsReadable: true) == [.overflowed])
        let mirroring = entry("system:screen-mirroring", kind: .system, owner: .system(.screenMirroring), slots: drawn)
        #expect(LayoutEditorNote.notes(for: mirroring, drawnIsReadable: true) == [.unverifiedModule])
        let wifi = entry("system:wifi", kind: .system, owner: .system(.wifi), slots: drawn)
        #expect(LayoutEditorNote.notes(for: wifi, drawnIsReadable: true) == [])
        #expect(LayoutEditorNote.unverifiedModule.isWarning && LayoutEditorNote.outsideApplications.isWarning)
        #expect(!LayoutEditorNote.hiddenNow.isWarning && !LayoutEditorNote.itemCount(2).isWarning)
    }

    @Test func notedListsOnlyWarnings() {
        let entries = [entry("com.a", slots: [slot(2000)]), entry("com.out", outside: true), entry("com.hidden")]
        let board = LayoutEditorBoard.make(entries: entries, layout: .empty, drawn: snapshot())
        #expect(board.noted.map(\.id) == ["com.out"])
    }

    // MARK: Drops

    private let own: Set<OwnerID> = [.app("com.alphapengwang.rolltop")]

    @Test func droppingAnItemMovesItsWholeApp() {
        let layout = Layout(sections: [.app("com.a"): .shown], defaultSection: .shown)
        let edit = LayoutEditorDrop.edit(dropping: .owner(.app("com.a")), on: .hidden, layout: layout, presentOwners: [], ownOwners: own)
        #expect(edit == .setSection(.app("com.a"), .hidden))
        #expect(edit.applied(to: layout).section(for: .app("com.a")) == .hidden)
    }

    @Test func droppingWhereAnItemAlreadyIsChangesNothing() {
        let layout = Layout(sections: [.app("com.a"): .hidden], defaultSection: .shown)
        #expect(LayoutEditorDrop.edit(dropping: .owner(.app("com.a")), on: .hidden, layout: layout, presentOwners: [], ownOwners: own) == .none)
        // Following the default and dropped on the default's shelf: no explicit entry is written.
        #expect(LayoutEditorDrop.edit(dropping: .owner(.app("com.b")), on: .shown, layout: layout, presentOwners: [], ownOwners: own) == .none)
        #expect(LayoutEditorEdit.none.applied(to: layout) == layout)
    }

    @Test func rolltopItselfCannotMove() {
        #expect(LayoutEditorDrop.edit(dropping: .owner(.app("com.alphapengwang.rolltop")), on: .hidden, layout: .empty,
                                      presentOwners: [], ownOwners: own) == .none)
    }

    @Test func droppingTheMarkerFreezesPresentItems() {
        let layout = Layout(sections: [.app("com.a"): .alwaysHidden], defaultSection: .shown)
        let present: Set<OwnerID> = [.app("com.a"), .app("com.b"), .system(.wifi), .app("com.alphapengwang.rolltop")]
        let edit = LayoutEditorDrop.edit(dropping: .marker, on: .hidden, layout: layout, presentOwners: present, ownOwners: own)
        #expect(edit == .setDefaultSection(.hidden, freezing: present))
        let after = edit.applied(to: layout)
        #expect(after.defaultSection == .hidden)
        // Every present item keeps the section it had; only owners seen later follow Hidden.
        #expect(after.section(for: .app("com.a")) == .alwaysHidden)
        #expect(after.section(for: .app("com.b")) == .shown)
        #expect(after.section(for: .system(.wifi)) == .shown)
        #expect(after.section(for: .app("com.new")) == .hidden)
        // Exactly the core command's freeze (Rolltop's own entry included; it is always shown anyway).
        #expect(after.section(for: .app("com.alphapengwang.rolltop")) == .shown)
        // Same shelf: nothing happens, nothing is frozen.
        #expect(LayoutEditorDrop.edit(dropping: .marker, on: .shown, layout: layout, presentOwners: present, ownOwners: own) == .none)
    }

    @Test func payloadRoundTripsAndRejectsForeignText() {
        for payload in [LayoutEditorPayload.marker, .owner(.app("com.a")), .owner(.system(.screenMirroring))] {
            #expect(LayoutEditorPayload(stringValue: payload.stringValue) == payload)
        }
        #expect(LayoutEditorPayload(stringValue: "com.a") == nil)
        #expect(LayoutEditorPayload(stringValue: "rolltop-layout-editor:owner:") == nil)
        #expect(LayoutEditorPayload(stringValue: "rolltop-layout-editor:owner:system:nope") == nil)
        #expect(LayoutEditorPayload(stringValue: "rolltop-layout-editor:something") == nil)
    }

    // MARK: Filter

    @Test func filterMatchesNameOrIdIgnoringCaseAndDiacritics() {
        let layout = Layout(sections: [.app("com.gone.Cafe"): .hidden], defaultSection: .shown)
        let entries = [
            entry("com.a.Fixture", slots: [slot(2000)]),
            entry("system:wifi", kind: .system, owner: .system(.wifi), slots: [slot(2100)]),
            entry("managed:com.apple.menuextra.airdrop", kind: .macOSManaged),
        ]
        let board = LayoutEditorBoard.make(entries: entries, layout: layout, drawn: snapshot()) { owner in
            switch owner {
            case .system(.wifi): "Wi-Fi"
            case .app("com.gone.Cafe"): "Café"
            default: nil
            }
        }
        #expect(board.filtered(by: "").shown.count == 2)
        #expect(board.filtered(by: "  ") == board)
        #expect(board.filtered(by: "wi-fi").shown.map(\.id) == ["system:wifi"])
        #expect(board.filtered(by: "FIXTURE").shown.map(\.id) == ["com.a.Fixture"])
        #expect(board.filtered(by: "cafe").notRunning.map(\.id) == ["com.gone.Cafe"])
        #expect(board.filtered(by: "airdrop").managed.count == 1)
        // Every word must match.
        #expect(board.filtered(by: "com fixture").shown.map(\.id) == ["com.a.Fixture"])
        #expect(board.filtered(by: "fixture wifi").shown.isEmpty)
        // The marker is not an item: its shelf keeps it.
        #expect(board.filtered(by: "zzz").defaultSection == .shown)
    }

    // MARK: Selection

    @Test func selectionSurvivesRefreshesAndQuits() {
        let layout = Layout(sections: [.app("com.a"): .hidden], defaultSection: .shown)
        let running = LayoutEditorBoard.make(entries: [entry("com.a", slots: [slot(2000)]), entry("com.b")], layout: layout, drawn: snapshot())
        // Reordered and redrawn: still selected.
        let refreshed = LayoutEditorBoard.make(entries: [entry("com.b"), entry("com.a")], layout: layout, drawn: snapshot())
        #expect(LayoutEditorSelection.surviving(.owner(.app("com.a")), in: running) == .owner(.app("com.a")))
        #expect(LayoutEditorSelection.surviving(.owner(.app("com.a")), in: refreshed) == .owner(.app("com.a")))
        // Quit with a saved section: moves to "Not running" and stays selected.
        let quit = LayoutEditorBoard.make(entries: [entry("com.b")], layout: layout, drawn: snapshot())
        #expect(LayoutEditorSelection.surviving(.owner(.app("com.a")), in: quit) == .owner(.app("com.a")))
        // Quit without a saved section: gone.
        #expect(LayoutEditorSelection.surviving(.owner(.app("com.b")), in: LayoutEditorBoard.make(entries: [], layout: layout, drawn: snapshot())) == nil)
        #expect(LayoutEditorSelection.surviving(.marker, in: quit) == .marker)
        #expect(LayoutEditorSelection.surviving(nil, in: quit) == nil)
    }

    @Test func arrowsWalkTheShelves() {
        let layout = Layout(sections: [.app("com.h1"): .hidden, .app("com.h2"): .hidden], defaultSection: .hidden)
        let entries = [
            entry("com.s1", slots: [slot(2000)]), entry("com.s2", slots: [slot(2050)]), entry("com.s3", slots: [slot(2100)]),
            entry("com.h1", frames: [CGRect(x: 1800, y: 0, width: 30, height: 24)]),
            entry("com.h2", frames: [CGRect(x: 1850, y: 0, width: 30, height: 24)]),
        ]
        // Present items were frozen when the default moved to Hidden.
        let frozen = layout.freezingSections(of: [OwnerID]()).with(shown: ["com.s1", "com.s2", "com.s3"])
        let board = LayoutEditorBoard.make(entries: entries, layout: frozen, drawn: snapshot())
        #expect(LayoutEditorSelection.row(.hidden, in: board) == [.owner(.app("com.h1")), .owner(.app("com.h2")), .marker])
        #expect(LayoutEditorSelection.row(.alwaysHidden, in: board).isEmpty)

        let s2 = LayoutEditorSelection.owner(.app("com.s2"))
        #expect(LayoutEditorSelection.moved(s2, .left, in: board, focusedShelf: .shown) == .owner(.app("com.s1")))
        #expect(LayoutEditorSelection.moved(s2, .right, in: board, focusedShelf: .shown) == .owner(.app("com.s3")))
        // Right from the end of a shelf continues on the next one.
        #expect(LayoutEditorSelection.moved(.owner(.app("com.s3")), .right, in: board, focusedShelf: .shown) == .owner(.app("com.h1")))
        // Down keeps the column, clamped; empty shelves are skipped; the edges stay put.
        #expect(LayoutEditorSelection.moved(.owner(.app("com.s3")), .down, in: board, focusedShelf: .shown) == .marker)
        #expect(LayoutEditorSelection.moved(.marker, .down, in: board, focusedShelf: .hidden) == .marker)
        #expect(LayoutEditorSelection.moved(.marker, .up, in: board, focusedShelf: .hidden) == .owner(.app("com.s3")))
        #expect(LayoutEditorSelection.moved(.owner(.app("com.s1")), .left, in: board, focusedShelf: .shown) == .owner(.app("com.s1")))
        // No selection: the first thing on the focused shelf.
        #expect(LayoutEditorSelection.moved(nil, .right, in: board, focusedShelf: .hidden) == .owner(.app("com.h1")))
        #expect(LayoutEditorSelection.moved(nil, .right, in: board, focusedShelf: .alwaysHidden) == .owner(.app("com.s1")))
        #expect(LayoutEditorSelection.shelf(of: .marker, in: board) == .hidden)
        #expect(LayoutEditorSelection.shelf(of: s2, in: board) == .shown)
    }
}

private extension Layout {
    func with(shown bundleIDs: [String]) -> Layout {
        var copy = self
        for id in bundleIDs { copy.setSection(.shown, for: .app(id)) }
        return copy
    }
}
