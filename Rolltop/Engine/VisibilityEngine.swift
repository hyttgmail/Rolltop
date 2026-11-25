import Foundation
import Observation
import RolltopCore

/// Owns the presentation state and keeps macOS's menu bar restriction in line with it.
///
/// Inputs: presentation level, "conceal shown", temporary allows (tokens), forced-visible
/// sets per source, suspensions (tokens), the layout, and the catalog's present owners.
/// Every input change replans through `AllowListPlanner` and applies the result:
/// activate the new assertion first, invalidate the old one only on success; a generation
/// counter makes late completions invalidate themselves; any error fails open (no
/// restriction held). Rehide policies and reveal gestures live in features and drive this
/// API; the engine never collapses by itself.
@Observable
final class VisibilityEngine {
    /// Opaque handle for temporary allows, suspensions and interactions.
    struct Token: Hashable, Sendable, CustomStringConvertible {
        fileprivate let value: Int
        var description: String { "#\(value)" }
    }

    // MARK: Observable state

    private(set) var level: PresentationLevel = .collapsed
    private(set) var concealShown = false
    private(set) var temporaryAllows: [Token: Set<OwnerID>] = [:]
    private(set) var forcedVisible: [String: Set<OwnerID>] = [:]
    /// While any suspension exists no restriction is held (the clock bridge uses this).
    private(set) var suspensions: [Token: String] = [:]
    /// Interactions in progress (an activated item's menu, a clock replay…); rehide
    /// policies should wait while this is non-empty.
    private(set) var interactions: [Token: String] = [:]
    /// The last plan, whether or not it is applied yet.
    private(set) var plannedAllowList: AllowList = .unrestricted
    /// What macOS confirmed (or `.unrestricted` when nothing is held).
    private(set) var appliedAllowList: AllowList = .unrestricted
    private(set) var isRestrictionHeld = false
    /// An activation is in flight.
    private(set) var isApplying = false
    private(set) var lastError: String?
    private(set) var lastErrorDate: Date?
    /// Bumps on every apply request.
    private(set) var generation = 0

    var isInteractionActive: Bool { !interactions.isEmpty }
    var isSuspended: Bool { !suspensions.isEmpty }
    var isAvailable: Bool { restriction.isAvailable }
    /// Owners allowed by any temporary token.
    var temporarilyAllowedOwners: Set<OwnerID> { temporaryAllows.values.reduce(into: []) { $0.formUnion($1) } }

    // MARK: Dependencies

    @ObservationIgnored private let restriction: MenuBarRestricting
    @ObservationIgnored private let layoutStore: LayoutStore
    @ObservationIgnored private let catalog: ItemCatalog
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let ownBundleIDs: Set<String>
    @ObservationIgnored private let log = Log.logger("visibility")

    @ObservationIgnored private var current: RestrictionAssertion?
    @ObservationIgnored private var inFlight: [Int: (assertion: RestrictionAssertion?, plan: AllowList)] = [:]
    @ObservationIgnored private var pendingGeneration: Int?
    @ObservationIgnored private var failedPlan: AllowList?
    @ObservationIgnored private var nextToken = 0
    @ObservationIgnored private var updateScheduled = false
    @ObservationIgnored private var inputObserver: ChangeObserver?
    @ObservationIgnored private var started = false

    /// How long macOS gets to answer an activation before Rolltop fails open.
    @ObservationIgnored var activationTimeout: Duration = .seconds(2)

    init(restriction: MenuBarRestricting, layoutStore: LayoutStore, catalog: ItemCatalog,
         settings: SettingsStore, ownBundleIDs: Set<String>) {
        self.restriction = restriction
        self.layoutStore = layoutStore
        self.catalog = catalog
        self.settings = settings
        self.ownBundleIDs = ownBundleIDs
    }

    /// Starts following the layout, the catalog and the pinned setting.
    func start() {
        guard !started else { return }
        started = true
        inputObserver = ChangeObserver(track: { [weak self] in
            guard let self else { return }
            _ = self.layoutStore.layout
            _ = self.catalog.presentOwners
            _ = self.catalog.knownBundleIDs
            _ = self.settings[CoreSettings.pinned]
        }) { [weak self] in
            self?.setNeedsUpdate()
        }
        if !restriction.isAvailable {
            recordError("The menu bar restriction API is unavailable on this macOS version; nothing can be hidden.")
        }
        setNeedsUpdate()
    }

    // MARK: Presentation

    func show(_ newLevel: PresentationLevel) {
        failedPlan = nil
        guard newLevel != level else { return setNeedsUpdate() }
        log.info("show \(newLevel.rawValue)")
        level = newLevel
        setNeedsUpdate()
    }

    func collapse() { show(.collapsed) }

    /// Collapses when at least `target` is revealed, otherwise reveals `target`.
    func toggle(_ target: PresentationLevel = .hiddenRevealed) {
        if level >= target, target != .collapsed { collapse() } else { show(target) }
    }

    /// "Swap" (with a revealed level) or "hide everything" (with `.collapsed`).
    func setConcealShown(_ on: Bool) {
        failedPlan = nil
        guard on != concealShown else { return }
        concealShown = on
        setNeedsUpdate()
    }

    // MARK: Allows, forcing, suspension

    /// Reveals `owners` until the token is ended, whatever their section.
    func allowTemporarily(_ owners: Set<OwnerID>) -> Token {
        failedPlan = nil
        let token = makeToken()
        temporaryAllows[token] = owners
        setNeedsUpdate()
        return token
    }

    func endTemporaryAllow(_ token: Token) {
        guard temporaryAllows.removeValue(forKey: token) != nil else { return }
        setNeedsUpdate()
    }

    /// Forces owners visible on behalf of `source` (e.g. `automation.<rule-id>`).
    /// An empty set removes the source.
    func setForcedVisible(_ owners: Set<OwnerID>, source: String) {
        let newValue: Set<OwnerID>? = owners.isEmpty ? nil : owners
        guard forcedVisible[source] != newValue else { return }
        forcedVisible[source] = newValue
        setNeedsUpdate()
    }

    /// Holds no restriction until the token is ended. Applies synchronously.
    func suspend(reason: String) -> Token {
        let token = makeToken()
        suspensions[token] = reason
        updateNow()
        return token
    }

    /// Ends a suspension and reapplies synchronously.
    func endSuspension(_ token: Token) {
        guard suspensions.removeValue(forKey: token) != nil else { return }
        updateNow()
    }

    func beginInteraction(_ reason: String) -> Token {
        let token = makeToken()
        interactions[token] = reason
        return token
    }

    func endInteraction(_ token: Token) {
        interactions.removeValue(forKey: token)
    }

    // MARK: Planning

    /// The planner input for the current state.
    func currentInput() -> AllowListInput {
        AllowListInput(layout: layoutStore.layout,
                       level: level,
                       concealShown: concealShown,
                       pinned: Set(settings[CoreSettings.pinned]),
                       temporaryAllows: temporarilyAllowedOwners,
                       forcedVisible: forcedVisible,
                       presentOwners: catalog.presentOwners,
                       knownBundleIDs: catalog.knownBundleIDs,
                       ownBundleIDs: ownBundleIDs)
    }

    /// Whether `owner` should be visible right now according to the plan.
    func isConcealed(_ owner: OwnerID) -> Bool {
        AllowListPlanner.isConcealed(owner, in: currentInput())
    }

    /// Coalesces updates into one per main-actor turn.
    func setNeedsUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            self.updateNow()
        }
    }

    /// Plans and applies right away.
    func updateNow() {
        var plan = isSuspended ? .unrestricted : AllowListPlanner.plan(currentInput())
        if plan.isRestricted, !restriction.isAvailable { plan = .unrestricted }
        if plan != plannedAllowList { plannedAllowList = plan }
        apply(plan)
    }

    /// Drops every assertion. Called at quit; the process exit would release them too.
    func releaseAll() {
        dropInFlight()
        current?.invalidate()
        current = nil
        isRestrictionHeld = false
        appliedAllowList = .unrestricted
    }

    // MARK: Applying

    private func apply(_ plan: AllowList) {
        if let pendingGeneration, inFlight[pendingGeneration]?.plan == plan { return }
        if plan.isRestricted, plan == appliedAllowList, current != nil {
            // Back to what is held: drop the in-flight request.
            dropInFlight()
            return
        }
        if !plan.isRestricted, pendingGeneration == nil, current == nil, !isRestrictionHeld { return }
        // After a failure, only an explicit user action (which clears this) retries the same plan.
        if let failedPlan, failedPlan == plan, plan.isRestricted { return }

        generation += 1
        let generation = generation

        // Whatever is still in flight is superseded now: never let it outlive this call,
        // even if macOS never answers it.
        dropInFlight()

        switch plan {
        case .unrestricted:
            current?.invalidate()
            current = nil
            failedPlan = nil
            if isRestrictionHeld { log.info("restriction released (gen \(generation))") }
            isRestrictionHeld = false
            appliedAllowList = .unrestricted
            catalog.setNeedsDrawnRefresh(after: .milliseconds(700))

        case .restricted(let ids, let bundles):
            pendingGeneration = generation
            isApplying = true
            let assertion = restriction.activate(systemIDs: ids, bundleIDs: bundles) { [weak self] error in
                self?.activationFinished(generation: generation, error: error)
            }
            inFlight[generation] = (assertion, plan)
            log.debug("activating gen \(generation): \(ids.count) system ids, \(bundles.count) bundles")
            let timeout = activationTimeout
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.activationTimedOut(generation: generation)
            }
        }
    }

    private func activationFinished(generation: Int, error: Error?) {
        guard let entry = inFlight.removeValue(forKey: generation) else { return }
        guard generation == pendingGeneration else {
            // Superseded while in flight: never hold it.
            entry.assertion?.invalidate()
            return
        }
        pendingGeneration = nil
        isApplying = false
        if let error {
            entry.assertion?.invalidate()
            failOpen(plan: entry.plan, reason: "Activation failed: \(error.localizedDescription)")
            return
        }
        guard let assertion = entry.assertion else {
            failOpen(plan: entry.plan, reason: "Activation returned no assertion")
            return
        }
        let old = current
        current = assertion
        old?.invalidate()
        failedPlan = nil
        appliedAllowList = entry.plan
        if !isRestrictionHeld { log.info("restriction held (gen \(generation))") }
        isRestrictionHeld = true
        catalog.setNeedsDrawnRefresh(after: .milliseconds(700))
    }

    private func activationTimedOut(generation: Int) {
        guard let entry = inFlight.removeValue(forKey: generation) else { return }
        entry.assertion?.invalidate()
        guard generation == pendingGeneration else { return }
        pendingGeneration = nil
        isApplying = false
        failOpen(plan: entry.plan, reason: "Activation timed out")
    }

    /// Invalidates every activation still in flight and forgets it.
    private func dropInFlight() {
        for (_, entry) in inFlight { entry.assertion?.invalidate() }
        inFlight.removeAll()
        pendingGeneration = nil
        isApplying = false
    }

    private func failOpen(plan: AllowList, reason: String) {
        current?.invalidate()
        current = nil
        isRestrictionHeld = false
        appliedAllowList = .unrestricted
        failedPlan = plan
        recordError(reason)
        catalog.setNeedsDrawnRefresh(after: .milliseconds(700))
    }

    private func recordError(_ message: String) {
        log.error(message)
        lastError = message
        lastErrorDate = Date()
    }

    private func makeToken() -> Token {
        nextToken += 1
        return Token(value: nextToken)
    }
}
