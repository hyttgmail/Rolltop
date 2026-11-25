import Foundation
import Testing
@testable import RolltopCore

private let fixture = OwnerID.app("com.example.fixture")
private let other = OwnerID.app("com.example.other")
private let rolltop = "com.alphapengwang.rolltop"

private func input(_ sections: [OwnerID: Section] = [:],
                   default defaultSection: Section = .shown,
                   level: PresentationLevel = .collapsed,
                   present: Set<OwnerID>? = nil,
                   known: Set<String>? = nil) -> AllowListInput {
    let presentOwners = present ?? Set(sections.keys).union([.system(.clock), .system(.wifi)])
    return AllowListInput(layout: Layout(sections: sections, defaultSection: defaultSection),
                          level: level,
                          presentOwners: presentOwners,
                          knownBundleIDs: known ?? Set(presentOwners.compactMap(\.bundleID)),
                          ownBundleIDs: [rolltop])
}

private func restricted(_ plan: AllowList) -> (ids: [Int], bundles: [String])? {
    if case .restricted(let ids, let bundles) = plan { return (ids, bundles) }
    return nil
}

@Suite struct AllowListPlannerTests {
    @Test func nothingHiddenMeansUnrestricted() {
        #expect(AllowListPlanner.plan(input([fixture: .shown])) == .unrestricted)
    }

    @Test func emptyInputIsUnrestricted() {
        #expect(AllowListPlanner.plan(AllowListInput()) == .unrestricted)
    }

    @Test func hiddenPresentOwnerRestrictsAndIsExcluded() throws {
        let plan = try #require(restricted(AllowListPlanner.plan(input([fixture: .hidden, other: .shown]))))
        #expect(!plan.bundles.contains(fixture.bundleID!))
        #expect(plan.bundles.contains(other.bundleID!))
        #expect(plan.bundles.contains(rolltop))
        #expect(plan.ids == SystemModule.allCases.map(\.rawValue))
    }

    @Test func hiddenOwnerThatIsNotPresentDoesNotRestrict() {
        let plan = AllowListPlanner.plan(input([fixture: .hidden], present: [other, .system(.clock)]))
        #expect(plan == .unrestricted)
    }

    @Test func revealingHiddenLevelUnrestricts() {
        #expect(AllowListPlanner.plan(input([fixture: .hidden], level: .hiddenRevealed)) == .unrestricted)
        #expect(AllowListPlanner.plan(input([fixture: .hidden], level: .allRevealed)) == .unrestricted)
    }

    @Test func alwaysHiddenNeedsAllRevealed() throws {
        let sections: [OwnerID: Section] = [fixture: .alwaysHidden]
        let plan = try #require(restricted(AllowListPlanner.plan(input(sections, level: .hiddenRevealed))))
        #expect(!plan.bundles.contains(fixture.bundleID!))
        #expect(AllowListPlanner.plan(input(sections, level: .allRevealed)) == .unrestricted)
    }

    @Test func unknownOwnersUseTheDefaultSection() throws {
        let present: Set<OwnerID> = [fixture, other]
        let hiddenDefault = try #require(restricted(AllowListPlanner.plan(input([other: .shown], default: .hidden, present: present))))
        #expect(hiddenDefault.bundles == [other.bundleID!, rolltop].sorted())
        #expect(AllowListPlanner.plan(input([other: .shown], default: .shown, present: present)) == .unrestricted)
    }

    @Test func defaultSectionAppliesToSystemModules() throws {
        let present: Set<OwnerID> = [fixture, .system(.clock), .system(.battery)]
        let plan = try #require(restricted(AllowListPlanner.plan(
            input([fixture: .shown, .system(.clock): .shown], default: .hidden, present: present))))
        #expect(plan.ids == [SystemModule.clock.rawValue])
    }

    @Test func temporaryAllowBeatsSection() {
        var value = input([fixture: .alwaysHidden])
        value.temporaryAllows = [fixture]
        #expect(AllowListPlanner.plan(value) == .unrestricted)
        #expect(!AllowListPlanner.isConcealed(fixture, in: value))
    }

    @Test func forcedVisibleBeatsSectionFromAnySource() throws {
        var value = input([fixture: .hidden, other: .hidden])
        value.forcedVisible = ["automation.a": [fixture], "automation.b": []]
        let plan = try #require(restricted(AllowListPlanner.plan(value)))
        #expect(plan.bundles.contains(fixture.bundleID!))
        #expect(!plan.bundles.contains(other.bundleID!))
    }

    @Test func temporaryAllowBeatsConcealShown() {
        var value = input([fixture: .shown], level: .collapsed)
        value.concealShown = true
        #expect(AllowListPlanner.isConcealed(fixture, in: value))
        value.temporaryAllows = [fixture]
        #expect(!AllowListPlanner.isConcealed(fixture, in: value))
    }

    @Test func ownBundleIsNeverConcealed() throws {
        let own = OwnerID.app(rolltop)
        var value = input([own: .alwaysHidden, fixture: .hidden], present: [own, fixture])
        value.concealShown = true
        #expect(!AllowListPlanner.isConcealed(own, in: value))
        let plan = try #require(restricted(AllowListPlanner.plan(value)))
        #expect(plan.bundles == [rolltop])
    }

    @Test func ownBundleAloneNeverRestricts() {
        let own = OwnerID.app(rolltop)
        #expect(AllowListPlanner.plan(input([own: .hidden], present: [own])) == .unrestricted)
    }

    @Test func concealShownSwapsSectionsExceptPinned() throws {
        var value = input([fixture: .shown, other: .hidden, .system(.clock): .shown, .system(.wifi): .shown],
                          level: .hiddenRevealed)
        value.concealShown = true
        value.pinned = [.system(.clock)]
        let plan = try #require(restricted(AllowListPlanner.plan(value)))
        #expect(!plan.bundles.contains(fixture.bundleID!))
        #expect(plan.bundles.contains(other.bundleID!))
        #expect(plan.ids.contains(SystemModule.clock.rawValue))
        #expect(!plan.ids.contains(SystemModule.wifi.rawValue))
    }

    @Test func hideEverythingKeepsOnlyPinnedAndOwn() throws {
        var value = input([fixture: .shown, other: .hidden], level: .collapsed)
        value.concealShown = true
        value.pinned = [.system(.controlCenter)]
        let plan = try #require(restricted(AllowListPlanner.plan(value)))
        #expect(plan.bundles == [rolltop])
        #expect(plan.ids == [SystemModule.controlCenter.rawValue])
    }

    @Test func hiddenSystemModuleIsLeftOut() throws {
        let plan = try #require(restricted(AllowListPlanner.plan(input([.system(.wifi): .hidden]))))
        #expect(!plan.ids.contains(SystemModule.wifi.rawValue))
        #expect(plan.ids.contains(SystemModule.clock.rawValue))
        #expect(plan.ids.contains(SystemModule.screenMirroring.rawValue))
    }

    @Test func defaultAllowIncludesKnownBundlesWithoutItems() throws {
        let plan = try #require(restricted(AllowListPlanner.plan(
            input([fixture: .hidden], present: [fixture], known: ["com.example.background", fixture.bundleID!]))))
        #expect(plan.bundles == ["com.example.background", rolltop].sorted())
    }

    @Test func layoutOwnersThatAreShownAreAllowedAhead() throws {
        let later = OwnerID.app("com.example.later")
        let plan = try #require(restricted(AllowListPlanner.plan(
            input([fixture: .hidden, later: .shown], present: [fixture]))))
        #expect(plan.bundles.contains(later.bundleID!))
    }

    @Test func outputIsSortedAndDeterministic() throws {
        let owners: [OwnerID] = (0..<20).map { .app("com.example.app\($0)") }
        var sections: [OwnerID: Section] = [fixture: .hidden]
        for owner in owners { sections[owner] = .shown }
        let value = input(sections)
        let first = try #require(restricted(AllowListPlanner.plan(value)))
        #expect(first.bundles == first.bundles.sorted())
        #expect(first.ids == first.ids.sorted())
        for _ in 0..<5 { #expect(AllowListPlanner.plan(value) == AllowListPlanner.plan(value)) }
    }

    @Test func concealedPresentOwnersAreReported() {
        let value = input([fixture: .hidden, other: .alwaysHidden])
        #expect(AllowListPlanner.concealedPresentOwners(value) == [fixture, other].sorted())
    }
}
