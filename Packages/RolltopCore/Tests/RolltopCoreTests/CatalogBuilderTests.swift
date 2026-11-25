import CoreGraphics
import Foundation
import Testing
@testable import RolltopCore

private let agentPID: Int32 = 10
private let fixturePID: Int32 = 20
private let busyPID: Int32 = 30
private let barePID: Int32 = 40

private let apps: [RunningAppRecord] = [
    RunningAppRecord(pid: agentPID, bundleID: menuBarAgentBundleID, name: "MenuBarAgent",
                     bundlePath: "/System/Library/CoreServices/MenuBarAgent.app", runsOutsideApplications: false),
    RunningAppRecord(pid: fixturePID, bundleID: "com.example.fixture", name: "Fixture",
                     bundlePath: "/Applications/Fixture.app", runsOutsideApplications: false),
    RunningAppRecord(pid: busyPID, bundleID: "com.example.busy", name: "Busy",
                     bundlePath: "/Users/me/Busy.app", runsOutsideApplications: true),
    RunningAppRecord(pid: barePID, bundleID: nil, name: "tool", bundlePath: nil, runsOutsideApplications: false),
]

private func rect(_ x: CGFloat, _ w: CGFloat = 20) -> CGRect { CGRect(x: x, y: 0, width: w, height: 24) }

private func agentExtras(_ ids: [String]) -> AppExtrasRecord {
    AppExtrasRecord(pid: agentPID, bundleID: menuBarAgentBundleID, status: .read,
                    items: ids.enumerated().map { ExtraItemRecord(index: $0.offset, frame: rect(1000 + CGFloat($0.offset) * 30),
                                                                  axIdentifier: $0.element, detail: $0.element.uppercased()) })
}

private func drawn(_ slots: [DrawnSlotRecord], chevron: CGRect? = nil) -> DrawnSnapshot {
    DrawnSnapshot(displays: [DisplayBarRecord(displayID: 1, isMain: true, barFrame: CGRect(x: 0, y: 0, width: 2000, height: 30),
                                              chevronFrame: chevron, chevronExpanded: false, slots: slots)],
                  capturedAt: Date(timeIntervalSince1970: 0), isReadable: true)
}

@Suite struct CatalogBuilderTests {
    @Test func classifiesAppsSystemManagedAndBareProcesses() throws {
        let extras = [
            agentExtras(["com.apple.menuextra.clock", "com.apple.menuextra.airdrop"]),
            AppExtrasRecord(pid: fixturePID, bundleID: "com.example.fixture", status: .read,
                            items: [ExtraItemRecord(index: 0, frame: rect(500)), ExtraItemRecord(index: 1, frame: rect(530))]),
            AppExtrasRecord(pid: barePID, bundleID: nil, status: .read, items: [ExtraItemRecord(index: 0, frame: rect(400))]),
        ]
        let slots = [
            DrawnSlotRecord(displayID: 1, frame: rect(500), ownerPID: fixturePID, ownerBundleID: "com.example.fixture", axIdentifier: nil),
            DrawnSlotRecord(displayID: 1, frame: rect(1000), ownerPID: agentPID, ownerBundleID: nil, axIdentifier: "com.apple.menuextra.clock"),
        ]
        let entries = CatalogBuilder.build(CatalogBuildInput(
            apps: apps, extras: extras, drawn: drawn(slots),
            layout: Layout(sections: [.app("com.example.fixture"): .hidden]),
            ownBundleIDs: [], restrictionHeld: false, previous: []))

        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let fixture = try #require(byID["com.example.fixture"])
        #expect(fixture.kind == .app)
        #expect(fixture.itemCount == 2)
        #expect(fixture.section == .hidden)
        #expect(fixture.hasExplicitSection)
        #expect(fixture.isDrawn)

        let clock = try #require(byID["system:clock"])
        #expect(clock.kind == .system)
        #expect(clock.owner == .system(.clock))
        // Fixed name; the spoken description (live state, system language) is the detail.
        #expect(clock.displayName == "Clock")
        #expect(clock.detail == "COM.APPLE.MENUEXTRA.CLOCK")
        #expect(clock.section == .shown)
        #expect(clock.isDrawn)

        let airdrop = try #require(byID["managed:com.apple.menuextra.airdrop"])
        #expect(airdrop.isMacOSManaged)
        #expect(airdrop.owner == nil)
        #expect(airdrop.section == nil)
        #expect(!airdrop.isDrawn)

        let bare = try #require(byID["pid:\(barePID)"])
        #expect(bare.kind == .unidentified)
        #expect(!bare.isAssignable)

        #expect(CatalogBuilder.presentOwners(entries) == [.app("com.example.fixture"), .system(.clock)])
        // Left to right by drawn slot, then last known frame.
        #expect(entries.map(\.id) == ["pid:\(barePID)", "com.example.fixture", "system:clock", "managed:com.apple.menuextra.airdrop"])
    }

    @Test func hiddenSystemModulesAreCarriedOverOnlyWhileRestricted() throws {
        let first = CatalogBuilder.build(CatalogBuildInput(
            apps: apps, extras: [agentExtras(["com.apple.menuextra.wifi", "com.apple.menuextra.airdrop"])],
            drawn: drawn([]), layout: .empty, ownBundleIDs: [], restrictionHeld: false, previous: []))
        #expect(first.count == 2)

        // While restricted, MenuBarAgent drops the hidden module from its list.
        let restricted = CatalogBuilder.build(CatalogBuildInput(
            apps: apps, extras: [agentExtras([])], drawn: drawn([]),
            layout: Layout(sections: [.system(.wifi): .hidden]), ownBundleIDs: [], restrictionHeld: true, previous: first))
        let wifi = try #require(restricted.first { $0.id == "system:wifi" })
        #expect(wifi.isCarriedOver)
        #expect(wifi.section == .hidden)
        #expect(CatalogBuilder.presentOwners(restricted).contains(.system(.wifi)))
        #expect(restricted.contains { $0.id == "managed:com.apple.menuextra.airdrop" })

        let unrestricted = CatalogBuilder.build(CatalogBuildInput(
            apps: apps, extras: [agentExtras([])], drawn: drawn([]), layout: .empty,
            ownBundleIDs: [], restrictionHeld: false, previous: restricted))
        #expect(unrestricted.isEmpty)
    }

    @Test func unreadableAppIsKeptWhileRunning() throws {
        let readable = CatalogBuilder.build(CatalogBuildInput(
            apps: apps, extras: [AppExtrasRecord(pid: busyPID, bundleID: "com.example.busy", status: .read,
                                                 items: [ExtraItemRecord(index: 0, frame: rect(300))])],
            drawn: drawn([]), layout: .empty, ownBundleIDs: [], restrictionHeld: false, previous: []))
        #expect(readable.first?.runsOutsideApplications == true)

        let timedOut = CatalogBuilder.build(CatalogBuildInput(
            apps: apps, extras: [AppExtrasRecord(pid: busyPID, bundleID: "com.example.busy", status: .timedOut, items: [])],
            drawn: drawn([]), layout: .empty, ownBundleIDs: [], restrictionHeld: false, previous: readable))
        let busy = try #require(timedOut.first)
        #expect(busy.isUnreadable)
        #expect(CatalogBuilder.presentOwners(timedOut) == [.app("com.example.busy")])

        let quit = CatalogBuilder.build(CatalogBuildInput(
            apps: apps.filter { $0.pid != busyPID }, extras: [], drawn: drawn([]), layout: .empty,
            ownBundleIDs: [], restrictionHeld: false, previous: timedOut))
        #expect(quit.isEmpty)
    }

    @Test func concealedAppThatLostItsExtrasBarIsCarriedOverWhileRestricted() throws {
        let hidden = Layout(sections: [.app("com.example.fixture"): .hidden])
        let listed = CatalogBuilder.build(CatalogBuildInput(
            apps: apps, extras: [AppExtrasRecord(pid: fixturePID, bundleID: "com.example.fixture", status: .read,
                                                 items: [ExtraItemRecord(index: 0, frame: rect(500))])],
            drawn: drawn([]), layout: hidden, ownBundleIDs: [], restrictionHeld: true, previous: []))
        // Overflowed, then concealed: the read succeeds with no items, list B has no slot.
        let emptyRead = [AppExtrasRecord(pid: fixturePID, bundleID: "com.example.fixture", status: .read, items: [])]
        func rebuild(_ previous: [CatalogEntry], layout: Layout, restricted: Bool) -> [CatalogEntry] {
            CatalogBuilder.build(CatalogBuildInput(apps: apps, extras: emptyRead, drawn: drawn([]), layout: layout,
                                                   ownBundleIDs: [], restrictionHeld: restricted, previous: previous))
        }
        let carried = try #require(rebuild(listed, layout: hidden, restricted: true).first)
        #expect(carried.isCarriedOver)
        #expect(carried.itemCount == 1)
        #expect(carried.section == .hidden)
        #expect(CatalogBuilder.presentOwners([carried]) == [.app("com.example.fixture")])
        #expect(rebuild(listed, layout: hidden, restricted: false).isEmpty)
        #expect(rebuild(listed, layout: .empty, restricted: true).isEmpty)

        // Known only from an overflowed slot (an earlier read already saw no extras bar):
        // carried over too, and stays carried on the next refresh.
        let slot = DrawnSlotRecord(displayID: 1, frame: rect(1000), ownerPID: fixturePID,
                                   ownerBundleID: "com.example.fixture", axIdentifier: nil, isOverflowed: true)
        let slotOnly = CatalogBuilder.build(CatalogBuildInput(
            apps: apps, extras: emptyRead, drawn: drawn([slot]), layout: hidden, ownBundleIDs: [],
            restrictionHeld: false, previous: []))
        #expect(slotOnly.first?.itemCount == 0)
        let once = rebuild(slotOnly, layout: hidden, restricted: true)
        let twice = rebuild(once, layout: hidden, restricted: true)
        #expect(twice.first?.isCarriedOver == true)
        #expect(twice.first?.itemCount == 1)
    }

    @Test func unreadableAppNeverSeenIsNotListed() {
        let entries = CatalogBuilder.build(CatalogBuildInput(
            apps: apps, extras: [AppExtrasRecord(pid: busyPID, bundleID: "com.example.busy", status: .refused, items: [])],
            drawn: drawn([]), layout: .empty, ownBundleIDs: [], restrictionHeld: false, previous: []))
        #expect(entries.isEmpty)
    }

    @Test func overflowedSlotsAreNotDrawn() throws {
        let chevron = CGRect(x: 1021, y: 0, width: 18, height: 30)
        let overflowed = DrawnSlotRecord(displayID: 1, frame: CGRect(x: 1000, y: 0, width: 38, height: 30),
                                         ownerPID: fixturePID, ownerBundleID: "com.example.fixture", axIdentifier: nil,
                                         isOverflowed: OverflowClassifier.isOverflowed(slot: CGRect(x: 1000, y: 0, width: 38, height: 30), chevron: chevron))
        #expect(overflowed.isOverflowed)
        #expect(!OverflowClassifier.isOverflowed(slot: CGRect(x: 1046, y: 0, width: 38, height: 30), chevron: chevron))
        #expect(!OverflowClassifier.isOverflowed(slot: CGRect(x: 1000, y: 0, width: 38, height: 30), chevron: nil))
        let entries = CatalogBuilder.build(CatalogBuildInput(
            apps: apps, extras: [], drawn: drawn([overflowed], chevron: chevron), layout: .empty,
            ownBundleIDs: [], restrictionHeld: false, previous: []))
        let entry = try #require(entries.first)
        #expect(entry.isOverflowed)
        #expect(!entry.isDrawn)
    }

    @Test func ownBundleIsFlagged() throws {
        let entries = CatalogBuilder.build(CatalogBuildInput(
            apps: apps, extras: [AppExtrasRecord(pid: fixturePID, bundleID: "com.example.fixture", status: .read,
                                                 items: [ExtraItemRecord(index: 0, frame: rect(10))])],
            drawn: drawn([]), layout: .empty, ownBundleIDs: ["com.example.fixture"], restrictionHeld: false, previous: []))
        #expect(try #require(entries.first).isOwn)
    }
}
