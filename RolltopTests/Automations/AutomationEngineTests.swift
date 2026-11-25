import Foundation
import RolltopCore
import Testing
@testable import Rolltop

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

@Suite struct AutomationDebounceTests {
    @Test func commitsOnlyAfterStability() {
        var runtimes: [String: AutomationRuleRuntime] = [:]
        var step = AutomationDebouncer.step(&runtimes, raw: [("r", true)], now: t0, stability: 2)
        #expect(step.transitions.isEmpty)
        #expect(step.nextDeadline == t0.addingTimeInterval(2))
        #expect(runtimes["r"]?.isPending == true)

        step = AutomationDebouncer.step(&runtimes, raw: [("r", true)], now: t0.addingTimeInterval(1.9), stability: 2)
        #expect(step.transitions.isEmpty)
        step = AutomationDebouncer.step(&runtimes, raw: [("r", true)], now: t0.addingTimeInterval(2), stability: 2)
        #expect(step.transitions == [AutomationTransition(ruleID: "r", isActive: true)])
        #expect(step.nextDeadline == nil)
        #expect(runtimes["r"] == AutomationRuleRuntime(isActive: true))
    }

    @Test func flappingNeverCommits() {
        var runtimes: [String: AutomationRuleRuntime] = ["r": AutomationRuleRuntime(isActive: false)]
        for i in 0..<20 {
            let step = AutomationDebouncer.step(&runtimes, raw: [("r", i % 2 == 0)], now: t0.addingTimeInterval(Double(i) * 0.5),
                                                stability: 2)
            #expect(step.transitions.isEmpty)
        }
        #expect(runtimes["r"]?.isActive == false)
        // The pending change restarts when the value flips back and forth.
        let step = AutomationDebouncer.step(&runtimes, raw: [("r", true)], now: t0.addingTimeInterval(10.4), stability: 2)
        #expect(step.transitions.isEmpty)
        #expect(step.nextDeadline == t0.addingTimeInterval(12.4))
    }

    @Test func immediateRulesAndDeletedRules() {
        var runtimes: [String: AutomationRuleRuntime] = ["a": .init(isActive: true), "gone": .init(isActive: true),
                                                         "idle": .init(isActive: false)]
        let step = AutomationDebouncer.step(&runtimes, raw: [("a", false), ("idle", false)], immediate: ["a"],
                                            now: t0, stability: 5)
        #expect(step.transitions == [AutomationTransition(ruleID: "a", isActive: false),
                                     AutomationTransition(ruleID: "gone", isActive: false)])
        #expect(runtimes.keys.sorted() == ["a", "idle"])
        // Zero stability commits at once.
        let zero = AutomationDebouncer.step(&runtimes, raw: [("a", true), ("idle", false)], now: t0, stability: 0)
        #expect(zero.transitions == [AutomationTransition(ruleID: "a", isActive: true)])
    }
}

@Suite struct AutomationForcedVisibilityTests {
    private let battery = OwnerID.system(.battery)
    private let app = OwnerID.app("com.example.vpn")

    @Test func overlappingRulesKeepSeparateSources() {
        let r1 = AutomationRule(id: "r1", name: "1", actions: AutomationActions(showItems: [battery, app]))
        let r2 = AutomationRule(id: "r2", name: "2", actions: AutomationActions(showItems: [app]))
        let r3 = AutomationRule(id: "r3", name: "3")
        let both = AutomationForcedVisibility.plan(rules: [r1, r2, r3], active: ["r1", "r2", "r3"])
        #expect(both == ["automations.r1": [battery, app], "automations.r2": [app]])

        var updates = AutomationForcedVisibility.updates(from: [:], to: both)
        #expect(updates.map(\.source) == ["automations.r1", "automations.r2"])

        // r1 ends: only its source is cleared; the app stays forced through r2.
        let onlyR2 = AutomationForcedVisibility.plan(rules: [r1, r2, r3], active: ["r2"])
        updates = AutomationForcedVisibility.updates(from: both, to: onlyR2)
        #expect(updates.count == 1)
        #expect(updates[0].source == "automations.r1")
        #expect(updates[0].owners.isEmpty)
        let union = onlyR2.values.reduce(into: Set<OwnerID>()) { $0.formUnion($1) }
        #expect(union == [app])
        #expect(AutomationForcedVisibility.updates(from: onlyR2, to: onlyR2).isEmpty)
    }
}

@Suite struct AutomationProfileLedgerTests {
    private let layoutA = Layout(sections: [.app("com.a"): .hidden])
    private let layoutB = Layout(sections: [.app("com.b"): .hidden])

    @Test func restoresThePreviousProfile() {
        var ledger = AutomationProfileLedger()
        ledger.recordApply(ruleID: "meeting", profileID: "meeting", previousProfileID: "work", previousLayout: layoutA)
        #expect(ledger.ruleEnded("meeting", activeProfileID: "meeting", existingProfileIDs: ["work", "meeting"]) == .profile("work"))
        #expect(ledger.entries.isEmpty)
        #expect(ledger.ruleEnded("meeting", activeProfileID: "meeting", existingProfileIDs: []) == .nothing)
    }

    @Test func userSwitchWins() {
        var ledger = AutomationProfileLedger()
        ledger.recordApply(ruleID: "r", profileID: "meeting", previousProfileID: "work", previousLayout: layoutA)
        #expect(ledger.ruleEnded("r", activeProfileID: "home", existingProfileIDs: ["work", "home", "meeting"]) == .nothing)
        #expect(ledger.entries.isEmpty)
    }

    @Test func noPreviousProfileRestoresTheLayout() {
        var ledger = AutomationProfileLedger()
        ledger.recordApply(ruleID: "r", profileID: "meeting", previousProfileID: nil, previousLayout: layoutA)
        #expect(ledger.ruleEnded("r", activeProfileID: "meeting", existingProfileIDs: ["meeting"]) == .layout(layoutA))
        // The previous profile was deleted meanwhile: the layout comes back too.
        ledger.recordApply(ruleID: "r", profileID: "meeting", previousProfileID: "work", previousLayout: layoutB)
        #expect(ledger.ruleEnded("r", activeProfileID: "meeting", existingProfileIDs: ["meeting"]) == .layout(layoutB))
    }

    @Test func overlappingRulesUnwindToTheStateBeforeBoth() {
        var ledger = AutomationProfileLedger()
        ledger.recordApply(ruleID: "r1", profileID: "p1", previousProfileID: "p0", previousLayout: layoutA)
        ledger.recordApply(ruleID: "r2", profileID: "p2", previousProfileID: "p1", previousLayout: layoutB)
        // r1 ends first while r2's profile is on top: nothing changes now…
        #expect(ledger.ruleEnded("r1", activeProfileID: "p2", existingProfileIDs: ["p0", "p1", "p2"]) == .nothing)
        #expect(ledger.entries.map(\.previousProfileID) == ["p0"])
        // …and when r2 ends, p0 (from before both) comes back, not p1.
        #expect(ledger.ruleEnded("r2", activeProfileID: "p2", existingProfileIDs: ["p0", "p1", "p2"]) == .profile("p0"))
    }

    @Test func reapplyKeepsTheOriginalPrevious() {
        var ledger = AutomationProfileLedger()
        ledger.recordApply(ruleID: "r", profileID: "p1", previousProfileID: "p0", previousLayout: layoutA)
        ledger.recordApply(ruleID: "r", profileID: "p1", previousProfileID: "p1", previousLayout: layoutB)
        #expect(ledger.entries.count == 1)
        #expect(ledger.entries[0].previousProfileID == "p0")
        ledger.prune(keeping: [])
        #expect(ledger.entries.isEmpty)
    }
}

// MARK: - Controller with fake effects

@MainActor
private final class FakeWorld {
    var clock = t0
    var forced: [String: Set<OwnerID>] = [:]
    var active: String?
    var profiles: [String: Layout] = [:]
    var layout = Layout.empty
    var applied: [String] = []
    var commands: [CommandID] = []

    var effects: AutomationEffects {
        AutomationEffects(
            setForcedVisible: { [unowned self] owners, source in forced[source] = owners.isEmpty ? nil : owners },
            activeProfileID: { [unowned self] in active },
            profileIDs: { [unowned self] in Set(profiles.keys) },
            applyProfile: { [unowned self] id in
                guard let layout = profiles[id] else { throw ProfileFileError.unknownProfile(id) }
                self.layout = layout
                active = id
                applied.append(id)
            },
            currentLayout: { [unowned self] in layout },
            restoreLayout: { [unowned self] layout in
                self.layout = layout
                active = nil
            },
            runCommand: { [unowned self] call in commands.append(call.id) })
    }

    var forcedOwners: Set<OwnerID> { forced.values.reduce(into: []) { $0.formUnion($1) } }
}

@MainActor
private struct ControllerHarness {
    let world = FakeWorld()
    let settings: SettingsStore
    let approvalsURL: URL
    let controller: AutomationsController

    init() throws {
        let defaults = try #require(UserDefaults(suiteName: "com.alphapengwang.rolltop.tests.automations.\(UUID().uuidString)"))
        settings = SettingsStore(defaults: defaults)
        approvalsURL = FileManager.default.temporaryDirectory.appending(path: "RolltopAutomationsTests-\(UUID().uuidString).json")
        let world = world
        controller = AutomationsController(settings: settings, effects: world.effects,
                                           approvals: AutomationScriptApprovals(fileURL: approvalsURL), now: { world.clock })
        controller.load()
    }

    /// Moves the clock and evaluates.
    func advance(_ seconds: TimeInterval) {
        world.clock = world.clock.addingTimeInterval(seconds)
        controller.evaluateNow()
    }

    func cleanUp() {
        controller.stop()
        try? FileManager.default.removeItem(at: approvalsURL)
    }
}

private let fixtureA = OwnerID.app("com.alphapengwang.rolltop-fixture")
private let fixtureB = "com.alphapengwang.rolltop-fixture-b"

@MainActor
@Suite struct AutomationsControllerTests {
    private func whileBRuns(id: String = "show-a") -> AutomationRule {
        AutomationRule(id: id, name: "Show a while b runs",
                       conditions: [AutomationCondition(.app(.init(bundleID: fixtureB, test: .running)))],
                       actions: AutomationActions(showItems: [fixtureA]))
    }

    @Test func showsItemsWhileTheRuleHoldsAndLogsTransitions() throws {
        let harness = try ControllerHarness()
        defer { harness.cleanUp() }
        let controller = harness.controller
        controller.add(whileBRuns())
        #expect(harness.world.forced.isEmpty)

        controller.updateEnvironment { $0.apps.running = [fixtureB] }
        harness.advance(0)
        #expect(controller.isPending("show-a"))
        #expect(harness.world.forced.isEmpty)
        harness.advance(2)
        #expect(controller.isActive("show-a"))
        #expect(harness.world.forced == ["automations.show-a": [fixtureA]])
        #expect(harness.settings[AutomationsSettings.activeRules] == ["show-a"])

        controller.updateEnvironment { $0.apps.running = [] }
        harness.advance(1)
        #expect(controller.isActive("show-a"))   // still debouncing
        harness.advance(1.5)
        #expect(controller.isActive("show-a"))
        harness.advance(0.5)
        #expect(!controller.isActive("show-a"))
        #expect(harness.world.forced.isEmpty)
        #expect(controller.logs["show-a"]?.map(\.kind) == [.activated, .deactivated])
    }

    @Test func disablingPausingAndDeletingEndRulesAtOnce() throws {
        let harness = try ControllerHarness()
        defer { harness.cleanUp() }
        let controller = harness.controller
        harness.settings[AutomationsSettings.stability] = 0
        controller.add(whileBRuns(id: "r1"))
        controller.add(whileBRuns(id: "r2"))
        controller.updateEnvironment { $0.apps.running = [fixtureB] }
        harness.advance(0)
        #expect(harness.world.forced.count == 2)

        controller.setEnabled(false, id: "r1")
        #expect(harness.world.forced == ["automations.r2": [fixtureA]])
        #expect(harness.world.forcedOwners == [fixtureA])   // still forced by r2

        controller.setPaused(true)
        #expect(harness.world.forced.isEmpty)
        #expect(!controller.isActive("r2"))
        controller.setPaused(false)
        #expect(controller.isActive("r2"))

        controller.delete(id: "r2")
        #expect(harness.world.forced.isEmpty)
        try controller.toggle(id: "r1")
        #expect(controller.isActive("r1"))
        #expect(throws: CommandError.invalidArgument("id", "nope")) { try controller.toggle(id: "nope") }
    }

    @Test func appliesAndRestoresProfilesAndRunsCommands() async throws {
        let harness = try ControllerHarness()
        defer { harness.cleanUp() }
        let controller = harness.controller
        let world = harness.world
        harness.settings[AutomationsSettings.stability] = 0
        world.profiles = ["work": Layout(sections: [fixtureA: .hidden]), "meeting": Layout(sections: [fixtureA: .shown])]
        try world.effects.applyProfile("work")
        var rule = whileBRuns(id: "meeting-rule")
        rule.actions = AutomationActions(profile: AutomationProfileAction(profileID: "meeting", restorePrevious: true),
                                         commandOnStart: AutomationCommandCall(id: "visibility.collapse"),
                                         commandOnEnd: AutomationCommandCall(id: "visibility.show-hidden"))
        controller.add(rule)

        controller.updateEnvironment { $0.apps.running = [fixtureB] }
        harness.advance(0)
        #expect(world.active == "meeting")
        #expect(harness.settings[AutomationsSettings.profileLedger].entries.map(\.previousProfileID) == ["work"])

        controller.updateEnvironment { $0.apps.running = [] }
        harness.advance(0)
        #expect(world.active == "work")
        #expect(world.applied == ["work", "meeting", "work"])
        #expect(harness.settings[AutomationsSettings.profileLedger].entries.isEmpty)
        await Task.yield()
        await Task.yield()
        #expect(world.commands == ["visibility.collapse", "visibility.show-hidden"])
        #expect(controller.logs["meeting-rule"]?.contains { $0.kind == .note } == true)
    }

    @Test func relaunchKeepsActiveRulesWithoutRerunningStartActions() throws {
        let harness = try ControllerHarness()
        defer { harness.cleanUp() }
        let world = harness.world
        harness.settings[AutomationsSettings.stability] = 0
        world.profiles = ["meeting": .empty]
        var rule = whileBRuns(id: "r")
        rule.actions.profile = AutomationProfileAction(profileID: "meeting", restorePrevious: true)
        harness.controller.add(rule)
        harness.controller.updateEnvironment { $0.apps.running = [fixtureB] }
        harness.advance(0)
        #expect(world.applied == ["meeting"])
        harness.controller.stop()

        // Same settings, new controller (relaunch): still running b, nothing re-applied.
        let again = AutomationsController(settings: harness.settings, effects: world.effects,
                                          approvals: AutomationScriptApprovals(fileURL: harness.approvalsURL), now: { world.clock })
        again.load()
        #expect(again.isActive("r"))
        again.updateEnvironment { $0.apps.running = [fixtureB] }
        again.evaluateNow()
        #expect(world.applied == ["meeting"])
        #expect(world.forced == ["automations.r": [fixtureA]])
        // b quit while Rolltop was not running: the rule ends and the layout comes back.
        again.updateEnvironment { $0.apps.running = [] }
        again.evaluateNow()
        #expect(!again.isActive("r"))
        #expect(world.active == nil)
        again.stop()
    }

    @Test func scriptsNeedApprovalAndImportsRevokeIt() async throws {
        let harness = try ControllerHarness()
        defer { harness.cleanUp() }
        let controller = harness.controller
        harness.settings[AutomationsSettings.stability] = 0
        let condition = AutomationCondition(id: "c", .script(AutomationScriptCondition(command: "test -e /tmp/x")))
        let rule = AutomationRule(id: "s", name: "Script", conditions: [condition], actions: AutomationActions(showItems: [fixtureA]))
        controller.add(rule, approvingScripts: ["c"])
        #expect(controller.isApproved(rule: rule, conditionID: "c", command: "test -e /tmp/x"))
        controller.updateEnvironment { $0.scripts["c"] = AutomationScriptOutcome(finishedAt: t0, exitStatus: 0) }
        harness.advance(0)
        #expect(controller.isActive("s"))

        // A settings import replaces the rules: approvals are revoked, the result forgotten.
        var imported = rule
        imported.name = "Imported"
        harness.settings[AutomationsSettings.rules] = AutomationRuleList(rules: [imported])
        for _ in 0..<5 { await Task.yield() }   // the settings observer runs on a later turn
        #expect(controller.rules.map(\.name) == ["Imported"])
        #expect(!controller.isApproved(rule: imported, conditionID: "c", command: "test -e /tmp/x"))
        #expect(controller.approvals.keys.isEmpty)
        #expect(controller.environment.scripts.isEmpty)
        #expect(!controller.isActive("s"))
    }
}

@Suite struct AutomationScriptTests {
    @Test func runsWithExitStatusOutputAndMinimalEnvironment() async {
        setenv("ROLLTOP_TEST_SECRET", "leak", 1)
        let ok = await AutomationScriptExecutor.run("printf 'hi'; printf %s \"$ROLLTOP_TEST_SECRET\"; exit 0", timeout: 5)
        #expect(ok.succeeded)
        #expect(ok.output == "hi")
        let failed = await AutomationScriptExecutor.run("echo nope >&2; exit 3", timeout: 5)
        #expect(failed.exitStatus == 3)
        #expect(failed.output == "nope")
        #expect(!failed.succeeded)
        let path = await AutomationScriptExecutor.run("printf %s \"$PATH\"", timeout: 5)
        #expect(path.output == "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func timesOutEvenWhenAChildKeepsThePipeOpen() async {
        let started = Date()
        let outcome = await AutomationScriptExecutor.run("sleep 30 & sleep 30", timeout: 1)
        #expect(outcome.timedOut)
        #expect(!outcome.succeeded)
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test @MainActor func approvalsAreBoundToRuleConditionAndCommand() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "RolltopApprovals-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let approvals = AutomationScriptApprovals(fileURL: url)
        approvals.setApproved(true, ruleID: "r", conditionID: "c", command: "true")
        #expect(approvals.isApproved(ruleID: "r", conditionID: "c", command: "true"))
        #expect(!approvals.isApproved(ruleID: "r", conditionID: "c", command: "true "))
        #expect(!approvals.isApproved(ruleID: "other", conditionID: "c", command: "true"))
        #expect(AutomationScriptApprovals(fileURL: url).isApproved(ruleID: "r", conditionID: "c", command: "true"))
        let rule = AutomationRule(id: "r", name: "r", conditions: [AutomationCondition(id: "c", .script(.init(command: "false")))])
        approvals.prune(rules: [rule])
        #expect(approvals.keys.isEmpty)
    }
}
