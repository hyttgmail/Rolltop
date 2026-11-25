import Foundation
import Observation
import RolltopCore

/// Settings keys of the Automations feature.
enum AutomationsSettings {
    static let rules = SettingsKey<AutomationRuleList>("rolltop.automations.rules", default: AutomationRuleList())
    static let paused = SettingsKey<Bool>("rolltop.automations.paused", default: false)
    /// Seconds a rule's conditions must hold before it switches.
    static let stability = SettingsKey<Double>("rolltop.automations.stability", default: 2)
    /// Rules that were active when last seen, so a relaunch does not re-run "becomes
    /// active" actions of a rule that never ended, and runs "ends" actions of one that did.
    static let activeRules = SettingsKey<[String]>("rolltop.automations.active-rules", default: [])
    static let profileLedger = SettingsKey<AutomationProfileLedger>("rolltop.automations.profile-ledger", default: AutomationProfileLedger())

    static let stabilityChoices: [Double] = [0.5, 1, 2, 5, 10, 30]
}

/// What rules do to the rest of the app. Built from the `AppContext` by the feature;
/// tests pass recording fakes.
struct AutomationEffects {
    var setForcedVisible: (Set<OwnerID>, String) -> Void
    var activeProfileID: () -> String?
    var profileIDs: () -> Set<String>
    var applyProfile: (String) throws -> Void
    var currentLayout: () -> Layout
    /// Puts back a layout with no active profile.
    var restoreLayout: (Layout) -> Void
    var runCommand: (AutomationCommandCall) async throws -> Void
}

/// The rule engine: holds rules and the live environment, evaluates with debounce, and
/// applies actions on transitions. All decisions are in the pure types of
/// `AutomationScheduling.swift` and `AutomationEvaluation.swift`.
@Observable
final class AutomationsController {
    private(set) var rules: [AutomationRule] = []
    private(set) var runtimes: [String: AutomationRuleRuntime] = [:]
    private(set) var environment = AutomationEnvironment()
    /// Last few state changes per rule, newest last.
    private(set) var logs: [String: [AutomationLogEntry]] = [:]
    private(set) var isPaused = false
    /// Bumps when script approvals change (they live outside observable state).
    private(set) var approvalsRevision = 0

    @ObservationIgnored let approvals: AutomationScriptApprovals
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let effects: AutomationEffects
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var appliedForced: [String: Set<OwnerID>] = [:]
    @ObservationIgnored private var ledger = AutomationProfileLedger()
    @ObservationIgnored private var lastSaved = AutomationRuleList()
    @ObservationIgnored private var lastSavedPaused = false
    @ObservationIgnored private var settingsObserver: ChangeObserver?
    @ObservationIgnored private var evaluationScheduled = false
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var scriptTasks: [String: (signature: String, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private(set) var runsScripts = false
    /// Called after rules were added, removed or renamed (re-register commands).
    @ObservationIgnored var onRulesChanged: (() -> Void)?
    @ObservationIgnored private let log = Log.logger("automations")

    init(settings: SettingsStore, effects: AutomationEffects, approvals: AutomationScriptApprovals,
         now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.effects = effects
        self.approvals = approvals
        self.now = now
    }

    /// Reads rules, pause state, the active set and the profile ledger from settings, then
    /// follows external changes (a settings import replaces rules: every script approval
    /// is revoked).
    func load() {
        lastSaved = settings[AutomationsSettings.rules]
        rules = lastSaved.rules
        lastSavedPaused = settings[AutomationsSettings.paused]
        isPaused = lastSavedPaused
        ledger = settings[AutomationsSettings.profileLedger]
        let ids = Set(rules.map(\.id))
        for id in settings[AutomationsSettings.activeRules] where ids.contains(id) {
            runtimes[id] = AutomationRuleRuntime(isActive: true)
        }
        ledger.prune(keeping: ids)
        approvals.prune(rules: rules)
        settingsObserver = ChangeObserver(track: { [weak self] in
            guard let self else { return }
            _ = self.settings[AutomationsSettings.rules]
            _ = self.settings[AutomationsSettings.paused]
        }) { [weak self] in
            self?.settingsChangedExternally()
        }
        log.info("loaded \(rules.count) rules\(isPaused ? " (paused)" : "")")
        onRulesChanged?()
    }

    /// Starts script timers; called once live monitoring runs (never under unit tests).
    func startScripts() {
        runsScripts = true
        reconcileScripts()
    }

    func stop() {
        runsScripts = false
        reconcileScripts()
        wakeTask?.cancel()
        settingsObserver?.cancel()
        for source in appliedForced.keys { effects.setForcedVisible([], source) }
        appliedForced = [:]
    }

    // MARK: Queries

    func rule(id: String) -> AutomationRule? { rules.first { $0.id == id } }

    func isActive(_ ruleID: String) -> Bool { runtimes[ruleID]?.isActive ?? false }

    func isPending(_ ruleID: String) -> Bool { runtimes[ruleID]?.isPending ?? false }

    func conditionHolds(_ condition: AutomationCondition) -> Bool {
        AutomationEvaluator.evaluate(condition, in: environment)
    }

    func isApproved(rule: AutomationRule, conditionID: String, command: String) -> Bool {
        _ = approvalsRevision
        return approvals.isApproved(ruleID: rule.id, conditionID: conditionID, command: command)
    }

    var stability: TimeInterval { max(0, settings[AutomationsSettings.stability]) }

    var usesNetworkNames: Bool { rules.contains { $0.isEnabled && $0.usesNetworkNames } }

    /// An enabled rule has a place condition: location updates should run (if allowed).
    var usesPlaces: Bool { rules.contains { $0.isEnabled && $0.usesPlaces } }

    /// A place condition's value; nil while the location is unknown.
    func placeHolds(_ condition: AutomationCondition) -> Bool? {
        guard case .place(let place) = condition.kind else { return nil }
        return environment.placeHolds(place, id: condition.id)
    }

    /// The rule has a place condition whose value is unknown.
    func hasUnknownPlace(_ rule: AutomationRule) -> Bool {
        rule.placeConditions.contains { environment.placeHolds($0.condition, id: $0.id) == nil }
    }

    /// A new fix (or nil: unknown). Updates every place condition's inside state, so the
    /// hysteresis band keeps the previous state.
    func updateLocation(_ fix: AutomationLocationFix?) {
        let places = rules.flatMap(\.placeConditions)
        updateEnvironment { environment in
            var states: [String: Bool] = [:]
            for (id, condition) in places {
                states[id] = AutomationPlaceDecision.isInside(previous: environment.placeStates[id], fix: fix,
                                                              place: condition.place)
            }
            environment.location = fix
            environment.placeStates = states
        }
    }

    // MARK: Environment

    /// Monitors and tests change the environment through this; evaluation follows.
    func updateEnvironment(_ body: (inout AutomationEnvironment) -> Void) {
        var copy = environment
        body(&copy)
        guard copy != environment else { return }
        environment = copy
        scheduleEvaluation()
    }

    // MARK: Editing

    func add(_ rule: AutomationRule, approvingScripts approved: Set<String> = []) {
        var rule = rule
        if rules.contains(where: { $0.id == rule.id }) { rule.id = AutomationIDs.make() }
        setApprovals(for: rule, approved: approved)
        setRules(rules + [rule])
    }

    /// Replaces a rule. `approved` lists the script condition ids the user allowed in the
    /// editor; other scripts of the rule are not allowed.
    func update(_ rule: AutomationRule, approvingScripts approved: Set<String>) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        setApprovals(for: rule, approved: approved)
        var copy = rules
        copy[index] = rule
        setRules(copy)
    }

    func delete(id: String) {
        setRules(rules.filter { $0.id != id })
        logs[id] = nil
    }

    @discardableResult
    func duplicate(id: String) -> AutomationRule? {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = rules[index]
        copy.id = AutomationIDs.make()
        copy.name = String(localized: "\(copy.name) copy", table: "Automations")
        copy.conditions = copy.conditions.map { AutomationCondition($0.kind) }
        var list = rules
        list.insert(copy, at: index + 1)
        setRules(list)
        return copy
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var list = rules
        list.move(fromOffsets: source, toOffset: destination)
        setRules(list)
    }

    func setEnabled(_ enabled: Bool, id: String) {
        guard let index = rules.firstIndex(where: { $0.id == id }), rules[index].isEnabled != enabled else { return }
        var list = rules
        list[index].isEnabled = enabled
        setRules(list)
    }

    func toggle(id: String) throws {
        guard let rule = rule(id: id) else { throw CommandError.invalidArgument("id", id) }
        setEnabled(!rule.isEnabled, id: id)
    }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        lastSavedPaused = paused
        settings[AutomationsSettings.paused] = paused
        log.notice(paused ? "paused" : "resumed")
        reconcileScripts()
        evaluateNow()
    }

    func setStability(_ seconds: Double) {
        settings[AutomationsSettings.stability] = seconds
        scheduleEvaluation()
    }

    func setScriptApproved(_ approved: Bool, ruleID: String, conditionID: String) {
        guard let rule = rule(id: ruleID),
              let script = rule.scriptConditions.first(where: { $0.id == conditionID })?.script else { return }
        approvals.setApproved(approved, ruleID: ruleID, conditionID: conditionID, command: script.command)
        approvalsRevision += 1
        if !approved { environment.scripts[conditionID] = nil }
        reconcileScripts()
        scheduleEvaluation()
    }

    // MARK: Evaluation

    func scheduleEvaluation() {
        guard !evaluationScheduled else { return }
        evaluationScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.evaluationScheduled = false
            self.evaluateNow()
        }
    }

    /// Evaluates every rule, commits debounced changes, applies their actions and
    /// schedules the next check (a pending change or the next minute for time rules).
    func evaluateNow() {
        let date = now()
        environment.now = date
        let raw = rules.map { rule in
            (id: rule.id, value: !isPaused && rule.isEnabled && AutomationEvaluator.evaluate(rule, in: environment))
        }
        let immediate = Set(rules.filter { isPaused || !$0.isEnabled }.map(\.id))
        var updated = runtimes
        let result = AutomationDebouncer.step(&updated, raw: raw, immediate: immediate, now: date, stability: stability)
        if updated != runtimes { runtimes = updated }
        apply(result.transitions)
        applyForcedVisibility()
        persistActiveSet()
        scheduleWake(deadline: result.nextDeadline, from: date)
    }

    private func apply(_ transitions: [AutomationTransition]) {
        for transition in transitions {
            let rule = rule(id: transition.ruleID)
            appendLog(transition.ruleID, transition.isActive ? .activated : .deactivated)
            log.info("rule \(transition.ruleID) \(transition.isActive ? "active" : "inactive")")
            if transition.isActive {
                guard let rule else { continue }
                if let action = rule.actions.profile { applyProfile(action, rule: rule) }
                if let call = rule.actions.commandOnStart { run(call, ruleID: rule.id) }
            } else {
                restoreProfileIfNeeded(ruleID: transition.ruleID)
                if let call = rule?.actions.commandOnEnd { run(call, ruleID: transition.ruleID) }
            }
        }
    }

    private func applyProfile(_ action: AutomationProfileAction, rule: AutomationRule) {
        let previousID = effects.activeProfileID()
        let previousLayout = effects.currentLayout()
        do {
            try effects.applyProfile(action.profileID)
            if action.restorePrevious {
                ledger.recordApply(ruleID: rule.id, profileID: action.profileID, previousProfileID: previousID,
                                   previousLayout: previousLayout)
                saveLedger()
            }
            appendLog(rule.id, .note, String(localized: "Applied profile “\(action.profileID)”", table: "Automations"))
        } catch {
            appendLog(rule.id, .error, error.localizedDescription)
        }
    }

    private func restoreProfileIfNeeded(ruleID: String) {
        guard ledger.hasEntry(for: ruleID) else { return }
        let decision = ledger.ruleEnded(ruleID, activeProfileID: effects.activeProfileID(), existingProfileIDs: effects.profileIDs())
        saveLedger()
        switch decision {
        case .nothing:
            break
        case .profile(let id):
            do {
                try effects.applyProfile(id)
                appendLog(ruleID, .note, String(localized: "Restored profile “\(id)”", table: "Automations"))
            } catch {
                appendLog(ruleID, .error, error.localizedDescription)
            }
        case .layout(let layout):
            effects.restoreLayout(layout)
            appendLog(ruleID, .note, String(localized: "Restored the previous layout", table: "Automations"))
        }
    }

    private func run(_ call: AutomationCommandCall, ruleID: String) {
        let effects = effects
        Task { [weak self] in
            do {
                try await effects.runCommand(call)
            } catch {
                self?.appendLog(ruleID, .error, error.localizedDescription)
            }
        }
    }

    private func applyForcedVisibility() {
        let active = Set(runtimes.filter(\.value.isActive).keys)
        let planned = AutomationForcedVisibility.plan(rules: rules, active: active)
        for update in AutomationForcedVisibility.updates(from: appliedForced, to: planned) {
            effects.setForcedVisible(update.owners, update.source)
        }
        appliedForced = planned
    }

    private func scheduleWake(deadline: Date?, from date: Date) {
        var next = deadline
        if !isPaused, rules.contains(where: { $0.isEnabled && $0.usesTime }) {
            let minute = AutomationEvaluator.nextMinuteBoundary(after: date, calendar: environment.calendar)
            next = min(next ?? minute, minute)
        }
        wakeTask?.cancel()
        guard let next else { return }
        let delay = max(0.05, next.timeIntervalSince(date) + 0.05)
        wakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.evaluateNow()
        }
    }

    // MARK: Scripts

    private func reconcileScripts() {
        var desired: [String: (signature: String, script: AutomationScriptCondition)] = [:]
        if runsScripts, !isPaused {
            for rule in rules where rule.isEnabled {
                for (conditionID, script) in rule.scriptConditions
                where approvals.isApproved(ruleID: rule.id, conditionID: conditionID, command: script.command) {
                    desired[conditionID] = ("\(script.command)\u{0}\(script.effectiveInterval)\u{0}\(script.effectiveTimeout)", script)
                }
            }
        }
        for (conditionID, entry) in scriptTasks where desired[conditionID]?.signature != entry.signature {
            entry.task.cancel()
            scriptTasks[conditionID] = nil
        }
        for (conditionID, wanted) in desired where scriptTasks[conditionID] == nil {
            let script = wanted.script
            let task = Task { [weak self] in
                while !Task.isCancelled {
                    let outcome = await AutomationScriptExecutor.run(script.command, timeout: TimeInterval(script.effectiveTimeout))
                    guard !Task.isCancelled, let self else { return }
                    self.updateEnvironment { $0.scripts[conditionID] = outcome }
                    try? await Task.sleep(for: .seconds(script.effectiveInterval))
                }
            }
            scriptTasks[conditionID] = (wanted.signature, task)
        }
        // A script that may not run counts as false; forget results of removed ones.
        let live = Set(rules.flatMap { rule in
            rule.scriptConditions.filter { approvals.isApproved(ruleID: rule.id, conditionID: $0.id, command: $0.script.command) }.map(\.id)
        })
        let kept = environment.scripts.filter { live.contains($0.key) }
        if kept != environment.scripts { environment.scripts = kept }
    }

    // MARK: Persistence

    private func setRules(_ list: [AutomationRule]) {
        rules = list
        lastSaved = AutomationRuleList(rules: list)
        settings[AutomationsSettings.rules] = lastSaved
        rulesDidChange()
    }

    private func rulesDidChange() {
        let ids = Set(rules.map(\.id))
        approvals.prune(rules: rules)
        approvalsRevision += 1
        logs = logs.filter { ids.contains($0.key) }
        reconcileScripts()
        evaluateNow()
        // Entries of deleted rules were restored by the deletion transition; drop leftovers.
        ledger.prune(keeping: ids)
        saveLedger()
        onRulesChanged?()
    }

    private func setApprovals(for rule: AutomationRule, approved: Set<String>) {
        for (conditionID, script) in rule.scriptConditions {
            approvals.setApproved(approved.contains(conditionID), ruleID: rule.id, conditionID: conditionID, command: script.command)
        }
        approvalsRevision += 1
    }

    private func settingsChangedExternally() {
        let stored = settings[AutomationsSettings.rules]
        if stored != lastSaved {
            log.notice("rules replaced from outside (import); script approvals revoked")
            approvals.revokeAll()
            lastSaved = stored
            rules = stored.rules
            rulesDidChange()
        }
        let paused = settings[AutomationsSettings.paused]
        if paused != lastSavedPaused {
            lastSavedPaused = paused
            isPaused = paused
            reconcileScripts()
            evaluateNow()
        }
    }

    private func persistActiveSet() {
        let active = rules.map(\.id).filter { runtimes[$0]?.isActive == true }
        if settings[AutomationsSettings.activeRules] != active { settings[AutomationsSettings.activeRules] = active }
    }

    private func saveLedger() {
        if settings[AutomationsSettings.profileLedger] != ledger { settings[AutomationsSettings.profileLedger] = ledger }
    }

    private func appendLog(_ ruleID: String, _ kind: AutomationLogEntry.Kind, _ message: String? = nil) {
        var entries = logs[ruleID] ?? []
        entries.append(AutomationLogEntry(date: now(), kind: kind, message: message))
        if entries.count > AutomationLogEntry.limit { entries.removeFirst(entries.count - AutomationLogEntry.limit) }
        logs[ruleID] = entries
    }

    #if DEBUG
    var ledgerForDebugging: AutomationProfileLedger { ledger }
    #endif
}
