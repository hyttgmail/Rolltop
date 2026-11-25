import Foundation
import Observation
import RolltopCore

/// What the "Turned off in System Settings" section shows.
nonisolated enum LayoutEditorTurnedOff: Equatable, Sendable {
    case notLoaded
    /// Bundle ids whose entry says not allowed.
    case apps([String])
    /// The allow list has a shape Rolltop does not know; types and key names only.
    case notRecognized(String)
    case unreadable
}

/// What one reorder did, for the editor and the Debug verify command.
nonisolated struct LayoutEditorMoveReport: Codable, Sendable {
    var moving: String
    var before: String?
    var changes: [String: Double] = [:]
    var previous: [String: Double] = [:]
    var write: String = "not attempted"
    var nudged: Bool?
    var landed: Bool?
    var landedAfterSeconds: Double?
    var rolledBack = false
    var drawnBefore: [String] = []
    var drawnAfter: [String] = []
    var problem: String?
}

/// Reading the two files (when allowed) and writing a new order. Owned by the feature;
/// nothing reads before the user allowed access on the consent row.
@Observable
final class LayoutEditorOrderModel {
    let orderAccess: LayoutEditorFileAccess
    let allowListAccess: LayoutEditorFileAccess
    private(set) var table: [String: Double]?
    private(set) var turnedOff: LayoutEditorTurnedOff = .notLoaded
    /// Shown in the editor after a reorder failed ("macOS did not apply…"), until the next one.
    private(set) var message: String?
    private(set) var isWriting = false
    private(set) var lastReport: LayoutEditorMoveReport?

    /// Makes MenuBarAgent lay the bar out again; false when Rolltop has no visible item.
    /// Set by the feature to `OwnStatusItemRegistry.nudgeLayout()`; false when Rolltop has no visible item.
    @ObservationIgnored var nudge: @MainActor () -> Bool = { false }
    /// List B, per display, left to right, without overflowed slots.
    @ObservationIgnored var drawnOrder: @MainActor () async -> [[OwnerID]] = { [] }
    /// Where the table is saved before Rolltop's first write ever.
    @ObservationIgnored var backupDirectory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first?.appending(path: "Rolltop/Backups", directoryHint: .isDirectory)
    @ObservationIgnored var settleDelay: Duration = .milliseconds(50)
    @ObservationIgnored var verifyWindow: Duration = .milliseconds(800)
    @ObservationIgnored var pollInterval: Duration = .milliseconds(100)

    static let backupName = "menu-bar-order-before-rolltop.plist"

    init(orderAccess: LayoutEditorFileAccess, allowListAccess: LayoutEditorFileAccess) {
        self.orderAccess = orderAccess
        self.allowListAccess = allowListAccess
    }

    var canReorder: Bool { orderAccess.canRead && table != nil }

    // MARK: Reading

    /// When the editor appears. Reads only the files the user allowed.
    func reload() async {
        if orderAccess.canRead, let read = await orderAccess.read() {
            table = Self.decodeTable(read)
        }
        if allowListAccess.canRead {
            turnedOff = Self.turnedOff(from: await allowListAccess.read())
        }
    }

    nonisolated static func decodeTable(_ read: MenuBarFileRead) -> [String: Double]? {
        guard let dict = read.object as? [String: Any] else { return nil }
        return dict.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    nonisolated static func turnedOff(from read: MenuBarFileRead?) -> LayoutEditorTurnedOff {
        switch read {
        case .value?:
            switch MenuBarAllowListParser.parse(read?.object) {
            case .entries(let entries, _): return .apps(MenuBarAllowListParser.turnedOff(entries))
            case .notRecognized(let found): return .notRecognized(found)
            }
        case .keyMissing?: return .notRecognized("no trackedApplications key")
        default: return .unreadable
        }
    }

    func clearMessage() { message = nil }

    // MARK: Writing

    /// Moves `owner` (all of its rows) to just left of `target` (nil: the right end, left
    /// of Control Center and the clock) in the menu bar: re-reads the table, plans the
    /// smallest change, saves a backup before Rolltop's first write, writes through cfprefsd,
    /// waits, nudges the layout and checks list B. If list B does not show the new order
    /// in time, the old weights go back and the editor says so. No retries.
    /// `onlyKeys` (Debug verify) refuses a plan that would touch any other row.
    @discardableResult
    func move(_ owner: OwnerID, before target: OwnerID?, onlyKeys: Set<String>? = nil) async -> LayoutEditorMoveReport {
        var report = LayoutEditorMoveReport(moving: owner.stringValue, before: target?.stringValue)
        guard !isWriting else { report.problem = "busy"; return report }
        isWriting = true
        message = nil
        defer {
            isWriting = false
            lastReport = report
        }
        func fail(_ problem: String, _ text: String?) -> LayoutEditorMoveReport {
            report.problem = problem
            message = text
            return report
        }
        let notApplied = String(localized: "macOS didn’t apply the new order. Hold ⌘ and drag the icon in the menu bar instead.",
                                table: "LayoutEditor")

        let displays = await drawnOrder()
        guard let drawn = displays.first(where: { $0.contains(owner) && (target.map($0.contains) ?? true) }) else {
            return fail("not drawn", String(localized: "Only items that are in the menu bar right now can be reordered.", table: "LayoutEditor"))
        }
        report.drawnBefore = drawn.map(\.stringValue)
        guard let read = await orderAccess.read(), case .value(let raw) = read, let table = Self.decodeTable(read) else {
            return fail("read failed", notApplied)
        }
        self.table = table
        var seen = Set<OwnerID>()
        let units = drawn.filter { seen.insert($0).inserted }
            .map { MenuBarOrderPlanner.Unit(owner: $0, keys: MenuBarOrderKeys.keys(for: $0, in: table)) }
            .filter { !$0.keys.isEmpty }
        var rest = units.map(\.owner).filter { $0 != owner }
        let destination = target.flatMap { rest.firstIndex(of: $0) } ?? rest.count
        guard units.contains(where: { $0.owner == owner }),
              let changes = MenuBarOrderPlanner.plan(table: table, order: units, moving: owner, to: destination) else {
            return fail("no plan", String(localized: "Rolltop can’t move this item. Hold ⌘ and drag it in the menu bar instead.", table: "LayoutEditor"))
        }
        if changes.isEmpty { return report }
        if let onlyKeys, !Set(changes.keys).isSubset(of: onlyKeys) {
            report.changes = changes
            return fail("plan touches other rows", nil)
        }
        rest.insert(owner, at: min(destination, rest.firstIndex(where: MenuBarOrderKeys.isFixed) ?? rest.count))
        report.changes = changes
        report.previous = table.filter { changes[$0.key] != nil }

        saveBackupIfFirst(raw)
        let written = await orderAccess.write(changes)
        report.write = "\(written)"
        guard written == .written else { return fail("write refused", notApplied) }
        try? await Task.sleep(for: settleDelay)
        let nudged = nudge()
        report.nudged = nudged
        guard nudged else {
            self.table = table.merging(changes) { $1 }
            return fail("no visible item to nudge",
                        String(localized: "The new order takes effect the next time the menu bar changes, because Rolltop’s icon is hidden.",
                               table: "LayoutEditor"))
        }
        let start = ContinuousClock.now
        var landed = false
        var after: [OwnerID] = []
        while ContinuousClock.now - start < verifyWindow {
            try? await Task.sleep(for: pollInterval)
            after = (await drawnOrder()).first { $0.contains(owner) } ?? []
            if MenuBarOrderPlanner.landed(moving: owner, planned: rest, drawn: after) { landed = true; break }
        }
        report.landed = landed
        report.drawnAfter = after.map(\.stringValue)
        let elapsed = ContinuousClock.now - start
        report.landedAfterSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        if landed {
            self.table = table.merging(changes) { $1 }
            return report
        }
        _ = await orderAccess.write(report.previous)
        report.rolledBack = true
        _ = nudge()
        return fail("did not land", notApplied)
    }

    /// Puts rows back to the given weights (Debug verify restore), with a nudge.
    func restore(_ weights: [String: Double]) async -> MenuBarFileWrite {
        let result = await orderAccess.write(weights)
        try? await Task.sleep(for: settleDelay)
        _ = nudge()
        return result
    }

    private func saveBackupIfFirst(_ raw: Data) {
        guard let directory = backupDirectory, orderAccess.injectedState == nil else { return }
        let url = directory.appending(path: Self.backupName)
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? raw.write(to: url, options: .atomic)
    }

    // MARK: Injected data (Debug)

    #if DEBUG
    func inject(table: [String: Double]?, allowList: Any?) {
        self.table = table
        turnedOff = allowList.map { MenuBarAllowListParser.parse($0) }.map {
            switch $0 {
            case .entries(let entries, _): .apps(MenuBarAllowListParser.turnedOff(entries))
            case .notRecognized(let found): .notRecognized(found)
            }
        } ?? .notLoaded
    }
    #endif
}

/// List B as owners: per display, left to right, without overflowed slots.
nonisolated enum LayoutEditorDrawnOrder {
    static func owners(_ snapshot: DrawnSnapshot) -> [[OwnerID]] {
        snapshot.displays.map { display in
            display.slots.filter { !$0.isOverflowed }.sorted { $0.frame.minX < $1.frame.minX }.compactMap { slot -> OwnerID? in
                if let identifier = slot.axIdentifier, let module = SystemModule(axIdentifier: identifier) { return .system(module) }
                return slot.ownerBundleID.map(OwnerID.app)
            }
        }
    }
}
