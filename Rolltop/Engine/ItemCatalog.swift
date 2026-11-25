import AppKit
import Foundation
import Observation
import RolltopCore

/// Everything Rolltop knows about menu bar items, merged from the running apps, list A
/// (`AXExtrasMenuBar`) and list B (what MenuBarAgent draws). See docs/PLATFORM.md §2.
///
/// Refreshes when apps launch or quit, on demand, after the restriction changes, and on
/// a slow timer. Sections come from the layout only, never from positions, so stale
/// frames of hidden items cannot move them; `lastKnownFrames` are frozen while a
/// restriction is held.
@Observable
final class ItemCatalog {
    private(set) var entries: [CatalogEntry] = []
    /// What MenuBarAgent lays out right now, per display.
    private(set) var drawn: DrawnSnapshot = .empty
    private(set) var runningApps: [RunningAppRecord] = []
    /// Assignable owners with items in the bar (input of the planner).
    private(set) var presentOwners: Set<OwnerID> = []
    /// Bundle ids allowed by default while restricted (input of the planner).
    private(set) var knownBundleIDs: Set<String> = []
    private(set) var lastRefresh: Date?
    private(set) var lastRefreshDuration: TimeInterval = 0
    private(set) var isRefreshing = false

    /// Set by the composition root: whether a restriction is currently held.
    @ObservationIgnored var restrictionHeld: () -> Bool = { false }

    @ObservationIgnored private let layoutStore: LayoutStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let permissions: Permissions
    @ObservationIgnored private let ownBundleIDs: Set<String>
    @ObservationIgnored private let ownPID = ProcessInfo.processInfo.processIdentifier
    @ObservationIgnored private var extras: [AppExtrasRecord] = []
    @ObservationIgnored private var appsObserver: RunningAppsObserver?
    @ObservationIgnored private var layoutObserver: ChangeObserver?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var scheduledRefresh: Task<Void, Never>?
    @ObservationIgnored private var scheduledDrawnRefresh: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private let log = Log.logger("catalog")

    init(layoutStore: LayoutStore, settings: SettingsStore, permissions: Permissions, ownBundleIDs: Set<String>) {
        self.layoutStore = layoutStore
        self.settings = settings
        self.permissions = permissions
        self.ownBundleIDs = ownBundleIDs
    }

    func start() {
        updateRunningApps()
        appsObserver = RunningAppsObserver { [weak self] in
            self?.updateRunningApps()
            self?.setNeedsRefresh(after: .milliseconds(300))
        }
        layoutObserver = ChangeObserver(track: { [weak self] in _ = self?.layoutStore.layout }) { [weak self] in
            self?.rebuild()
        }
        let interval = max(5, settings[CoreSettings.catalogRefreshInterval])
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.setNeedsRefresh(after: .zero) }
        }
        setNeedsRefresh(after: .zero)
    }

    func stop() {
        appsObserver?.invalidate()
        appsObserver = nil
        layoutObserver?.cancel()
        timer?.invalidate()
        scheduledRefresh?.cancel()
        scheduledDrawnRefresh?.cancel()
    }

    // MARK: Queries

    func entry(for owner: OwnerID) -> CatalogEntry? {
        entries.first { $0.owner == owner }
    }

    func entry(id: String) -> CatalogEntry? {
        entries.first { $0.id == id }
    }

    /// Visible (not overflowed) on at least one display, per the last list B read.
    func isDrawn(_ owner: OwnerID) -> Bool {
        entry(for: owner)?.isDrawn ?? false
    }

    func entries(in section: Section) -> [CatalogEntry] {
        entries.filter { $0.section == section }
    }

    /// The owner's fixed name: system modules and known Apple agents by `ItemNames`, apps by
    /// the catalog, the running app, or the installed app; the bundle id as a last resort.
    /// Never live state ("connected, 3 bars": that is `CatalogEntry.detail`).
    func displayName(for owner: OwnerID) -> String {
        switch owner {
        case .system(let module):
            return ItemNames.module(module)
        case .app(let bundle):
            if let name = ItemNames.agent(bundleID: bundle) { return name }
            if let name = entry(for: owner)?.displayName, !name.isEmpty, name != bundle { return name }
            if let name = runningApps.first(where: { $0.bundleID == bundle })?.name { return name }
            return ItemNames.installedApp(bundleID: bundle) ?? bundle
        }
    }

    /// Localized fixed names for system modules and Apple agents (the builder in RolltopCore
    /// has only English ones).
    private static func localizingName(_ entry: CatalogEntry) -> CatalogEntry {
        var entry = entry
        switch entry.owner {
        case .system(let module)?:
            entry.displayName = ItemNames.module(module)
        case .app(let bundle)?:
            if let name = ItemNames.agent(bundleID: bundle) { entry.displayName = name }
        case nil:
            if let name = ItemNames.managed(id: entry.id) { entry.displayName = name }
        }
        return entry
    }

    // MARK: Refresh

    /// Debounced full refresh (list A + list B).
    func setNeedsRefresh(after delay: Duration = .milliseconds(300)) {
        scheduledRefresh?.cancel()
        scheduledRefresh = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Debounced list-B-only refresh, e.g. after the restriction changed.
    func setNeedsDrawnRefresh(after delay: Duration) {
        scheduledDrawnRefresh?.cancel()
        scheduledDrawnRefresh = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            _ = await self?.refreshDrawn()
        }
    }

    /// Reads both lists now. Concurrent calls coalesce into one extra pass.
    func refresh() async {
        guard !isRefreshing else {
            refreshAgain = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshAgain = false
            await performRefresh()
        } while refreshAgain
    }

    private func performRefresh() async {
        permissions.refresh()
        updateRunningApps()
        guard permissions.accessibility else {
            // Without Accessibility nothing can be read: keep nothing present so the
            // planner holds no restriction (fail open).
            apply(extras: [], drawn: DrawnSnapshot(displays: [], capturedAt: Date(), isReadable: false))
            return
        }
        let started = Date()
        let apps = runningApps
        let restricted = restrictionHeld()
        let extras = await AXInventory.readExtras(of: apps, excluding: ownPID)
        let drawn = await readDrawnSnapshot()
        lastRefreshDuration = Date().timeIntervalSince(started)
        apply(extras: extras, drawn: drawn, restrictedWhileReading: restricted || restrictionHeld())
        log.debug("refresh: \(apps.count) apps, \(extras.filter { !$0.items.isEmpty }.count) with items, \(entries.count) entries in \(Int(lastRefreshDuration * 1000)) ms")
    }

    /// Reads list B only and updates slots; returns the snapshot.
    @discardableResult
    func refreshDrawn() async -> DrawnSnapshot {
        guard permissions.accessibility else { return drawn }
        updateRunningApps()
        let snapshot = await readDrawnSnapshot()
        apply(extras: extras, drawn: snapshot, restrictedWhileReading: restrictionHeld())
        return snapshot
    }

    private func readDrawnSnapshot() async -> DrawnSnapshot {
        let apps = runningApps
        let bundleByPID = Dictionary(apps.compactMap { app in app.bundleID.map { (app.pid, $0) } },
                                     uniquingKeysWith: { first, _ in first })
        return await AXInventory.readDrawn(agentPID: AXInventory.agentPID(in: apps),
                                           bundleByPID: bundleByPID,
                                           displays: DisplayGeometry.current())
    }

    private func updateRunningApps() {
        let apps = AXInventory.runningApps()
        if apps != runningApps { runningApps = apps }
        let known = Set(apps.compactMap(\.bundleID)).union(presentOwners.compactMap(\.bundleID))
        if known != knownBundleIDs { knownBundleIDs = known }
    }

    /// Re-merges the last reads with the current layout (no Accessibility calls).
    func rebuild() {
        apply(extras: extras, drawn: drawn, restrictedWhileReading: restrictionHeld())
    }

    #if DEBUG
    /// Unit tests only: sets what the planner sees as present without reading anything.
    func setPresenceForTesting(present: Set<OwnerID>, known: Set<String>) {
        presentOwners = present
        knownBundleIDs = known
    }
    #endif

    private func apply(extras newExtras: [AppExtrasRecord], drawn newDrawn: DrawnSnapshot, restrictedWhileReading: Bool = false) {
        extras = newExtras
        let built = CatalogBuilder.build(CatalogBuildInput(
            apps: runningApps, extras: newExtras, drawn: newDrawn, layout: layoutStore.layout,
            ownBundleIDs: ownBundleIDs, restrictionHeld: restrictedWhileReading, previous: entries))
            .map(Self.localizingName)
        if built != entries { entries = built }
        if newDrawn != drawn { drawn = newDrawn }
        let present = CatalogBuilder.presentOwners(built)
        if present != presentOwners { presentOwners = present }
        let known = Set(runningApps.compactMap(\.bundleID)).union(present.compactMap(\.bundleID))
        if known != knownBundleIDs { knownBundleIDs = known }
        lastRefresh = Date()
    }
}
