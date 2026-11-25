import CoreGraphics
import Foundation

/// One row of the item catalog: an owner and what is known about its items.
public struct CatalogEntry: Sendable, Equatable, Identifiable, Codable {
    public enum Kind: String, Sendable, Codable {
        /// A third-party or system app addressed by bundle id. Assignable.
        case app
        /// One of the `SystemModule`s. Assignable.
        case system
        /// A MenuBarAgent extra without a system id (AirDrop, Focus, Now Playing…).
        /// Listed but not assignable: any restriction hides it.
        case macOSManaged
        /// A process without bundle id. Not assignable: it cannot be allowed.
        case unidentified
    }

    /// Stable id: `owner.stringValue`, `managed:<AXIdentifier>` or `pid:<pid>`.
    public var id: String
    public var kind: Kind
    /// Nil for `.macOSManaged` and `.unidentified`.
    public var owner: OwnerID?
    /// Fixed name: the app's name, or the module's name for system modules (never live state).
    public var displayName: String
    /// What macOS says about the item right now (`AXDescription` of system modules and
    /// macOS-managed extras: "Wi‑Fi, connected, 3 bars"), nil for apps.
    public var detail: String?
    /// Effective section (explicit or default). Nil when not assignable.
    public var section: Section?
    public var hasExplicitSection: Bool
    /// Items reported by the owner's `AXExtrasMenuBar` (0 when unreadable).
    public var itemCount: Int
    public var pids: [Int32]
    /// `com.apple.menuextra.*` identifiers for system and managed entries.
    public var axIdentifiers: [String]
    /// Slots MenuBarAgent currently lays out for this owner, every display.
    public var slots: [DrawnSlotRecord]
    /// Frames from `AXExtrasMenuBar`; only refreshed while no restriction is held.
    public var lastKnownFrames: [CGRect]
    public var runsOutsideApplications: Bool
    /// The owner's Accessibility tree timed out or is refused.
    public var isUnreadable: Bool
    public var isOwn: Bool
    /// Kept from an earlier read because the current read cannot see it (hidden while restricted).
    public var isCarriedOver: Bool

    public init(id: String, kind: Kind, owner: OwnerID?, displayName: String, section: Section?,
                hasExplicitSection: Bool, itemCount: Int, pids: [Int32], axIdentifiers: [String],
                slots: [DrawnSlotRecord], lastKnownFrames: [CGRect], runsOutsideApplications: Bool,
                isUnreadable: Bool, isOwn: Bool, isCarriedOver: Bool, detail: String? = nil) {
        self.id = id
        self.detail = detail
        self.kind = kind
        self.owner = owner
        self.displayName = displayName
        self.section = section
        self.hasExplicitSection = hasExplicitSection
        self.itemCount = itemCount
        self.pids = pids
        self.axIdentifiers = axIdentifiers
        self.slots = slots
        self.lastKnownFrames = lastKnownFrames
        self.runsOutsideApplications = runsOutsideApplications
        self.isUnreadable = isUnreadable
        self.isOwn = isOwn
        self.isCarriedOver = isCarriedOver
    }

    public var isMacOSManaged: Bool { kind == .macOSManaged }
    public var isAssignable: Bool { owner != nil }
    /// At least one slot is visible in a bar (not under the overflow chevron).
    public var isDrawn: Bool { slots.contains { !$0.isOverflowed } }
    /// Laid out, but every slot is under the overflow chevron.
    public var isOverflowed: Bool { !slots.isEmpty && slots.allSatisfy(\.isOverflowed) }
    /// Visible slots on one display.
    public func drawnSlots(onDisplay displayID: UInt32) -> [DrawnSlotRecord] {
        slots.filter { $0.displayID == displayID && !$0.isOverflowed }
    }
}

/// Inputs of one catalog build.
public struct CatalogBuildInput: Sendable {
    public var apps: [RunningAppRecord]
    public var extras: [AppExtrasRecord]
    public var drawn: DrawnSnapshot
    public var layout: Layout
    public var ownBundleIDs: Set<String>
    /// Whether a restriction was held while reading. MenuBarAgent then omits hidden
    /// system modules and managed extras from list A, so earlier entries are kept.
    public var restrictionHeld: Bool
    public var previous: [CatalogEntry]

    public init(apps: [RunningAppRecord], extras: [AppExtrasRecord], drawn: DrawnSnapshot, layout: Layout,
                ownBundleIDs: Set<String>, restrictionHeld: Bool, previous: [CatalogEntry]) {
        self.apps = apps
        self.extras = extras
        self.drawn = drawn
        self.layout = layout
        self.ownBundleIDs = ownBundleIDs
        self.restrictionHeld = restrictionHeld
        self.previous = previous
    }
}

public enum CatalogBuilder {
    /// The catalog key for an extra hosted by MenuBarAgent.
    static func hostedKey(_ identifier: String) -> (id: String, kind: CatalogEntry.Kind, owner: OwnerID?) {
        if let module = SystemModule(axIdentifier: identifier) {
            let owner = OwnerID.system(module)
            return (owner.stringValue, .system, owner)
        }
        return ("managed:" + identifier, .macOSManaged, nil)
    }

    /// System modules get their fixed name; macOS-managed extras (AirDrop, Focus…) have no
    /// fixed name, so their spoken description stands in, else the identifier's suffix.
    static func hostedName(_ identifier: String, owner: OwnerID?, description: String?) -> String {
        if case .system(let module)? = owner { return module.defaultName }
        return description ?? String(identifier.dropFirst(SystemModule.menuExtraIdentifierPrefix.count))
    }

    public static func build(_ input: CatalogBuildInput) -> [CatalogEntry] {
        let appsByPID = Dictionary(input.apps.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var entries: [String: CatalogEntry] = [:]

        func entry(id: String, kind: CatalogEntry.Kind, owner: OwnerID?, name: String) -> CatalogEntry {
            if let existing = entries[id] { return existing }
            let section = owner.map { input.layout.section(for: $0) }
            let explicit = owner.map { input.layout.hasExplicitSection($0) } ?? false
            let isOwn = owner?.bundleID.map { input.ownBundleIDs.contains($0) } ?? false
            return CatalogEntry(id: id, kind: kind, owner: owner, displayName: name, section: section,
                                hasExplicitSection: explicit, itemCount: 0, pids: [], axIdentifiers: [],
                                slots: [], lastKnownFrames: [], runsOutsideApplications: false,
                                isUnreadable: false, isOwn: isOwn, isCarriedOver: false)
        }

        // List A: per-app AXExtrasMenuBar.
        for record in input.extras {
            let app = appsByPID[record.pid]
            if record.bundleID == menuBarAgentBundleID {
                for item in record.items {
                    guard let identifier = item.axIdentifier else { continue }
                    let key = hostedKey(identifier)
                    var current = entry(id: key.id, kind: key.kind, owner: key.owner,
                                        name: hostedName(identifier, owner: key.owner, description: item.detail))
                    if current.detail == nil { current.detail = item.detail }
                    current.itemCount += 1
                    if !current.axIdentifiers.contains(identifier) { current.axIdentifiers.append(identifier) }
                    current.lastKnownFrames.append(item.frame)
                    entries[key.id] = current
                }
                continue
            }
            let unreadable = record.status != .read
            guard !record.items.isEmpty || unreadable else { continue }
            let (id, kind, owner): (String, CatalogEntry.Kind, OwnerID?) = {
                if let bundle = record.bundleID { return (bundle, .app, OwnerID.app(bundle)) }
                return ("pid:\(record.pid)", .unidentified, nil)
            }()
            // An unreadable app is only listed when list B or an earlier read shows it has items.
            if unreadable, record.items.isEmpty {
                let drawnHere = input.drawn.allSlots.contains { $0.ownerPID == record.pid }
                let seenBefore = input.previous.contains { $0.id == id && $0.itemCount > 0 }
                guard drawnHere || seenBefore else { continue }
            }
            var current = entry(id: id, kind: kind, owner: owner, name: app?.name ?? record.bundleID ?? "pid \(record.pid)")
            current.itemCount += record.items.count
            if !current.pids.contains(record.pid) { current.pids.append(record.pid) }
            current.lastKnownFrames += record.items.map(\.frame)
            current.runsOutsideApplications = current.runsOutsideApplications || (app?.runsOutsideApplications ?? false)
            current.isUnreadable = current.isUnreadable || unreadable
            entries[id] = current
        }

        // List B: what MenuBarAgent lays out.
        for display in input.drawn.displays {
            for slot in display.slots {
                let key: (id: String, kind: CatalogEntry.Kind, owner: OwnerID?)
                var name: String
                if let identifier = slot.axIdentifier {
                    key = hostedKey(identifier)
                    name = hostedName(identifier, owner: key.owner, description: nil)
                } else if let bundle = slot.ownerBundleID {
                    key = (bundle, .app, .app(bundle))
                    name = slot.ownerPID.flatMap { appsByPID[$0]?.name } ?? bundle
                } else if let pid = slot.ownerPID {
                    key = ("pid:\(pid)", .unidentified, nil)
                    name = appsByPID[pid]?.name ?? "pid \(pid)"
                } else {
                    continue
                }
                if let existing = entries[key.id] { name = existing.displayName }
                var current = entry(id: key.id, kind: key.kind, owner: key.owner, name: name)
                current.slots.append(slot)
                if let pid = slot.ownerPID, key.kind == .app || key.kind == .unidentified, !current.pids.contains(pid) {
                    current.pids.append(pid)
                    if let app = appsByPID[pid] {
                        current.runsOutsideApplications = current.runsOutsideApplications || app.runsOutsideApplications
                    }
                }
                entries[key.id] = current
            }
        }

        // Carry over what the current read cannot see.
        let runningPIDs = Set(input.apps.map(\.pid))
        for old in input.previous where entries[old.id] == nil {
            let keep: Bool
            switch old.kind {
            case .system, .macOSManaged:
                // Hidden modules vanish from MenuBarAgent's own list while restricted.
                keep = input.restrictionHeld
            case .app, .unidentified:
                let running = old.pids.contains(where: runningPIDs.contains)
                // An app that stopped answering keeps its entry while it runs.
                let unanswered = input.extras.contains { old.pids.contains($0.pid) && $0.status != .read }
                // An app whose item overflowed and was then concealed loses its
                // AXExtrasMenuBar (PLATFORM §2): the read succeeds with nothing and list B
                // has no slot. While it is concealed nothing can tell that the item is gone,
                // so keep it. An owner without bundle id cannot be allowed: always concealed.
                let hadItems = old.itemCount > 0 || !old.slots.isEmpty || old.isCarriedOver
                let concealed = old.owner.map { input.layout.section(for: $0) != .shown } ?? true
                keep = running && (unanswered || (input.restrictionHeld && hadItems && concealed))
            }
            guard keep else { continue }
            var carried = old
            // An app known only from an overflowed slot still has one item.
            if old.kind == .app || old.kind == .unidentified, old.itemCount == 0, !old.slots.isEmpty { carried.itemCount = 1 }
            carried.slots = []
            carried.isCarriedOver = true
            if let owner = carried.owner {
                carried.section = input.layout.section(for: owner)
                carried.hasExplicitSection = input.layout.hasExplicitSection(owner)
            }
            entries[old.id] = carried
        }

        // Frames from list A are stale for hidden items: keep the previous ones while restricted.
        if input.restrictionHeld {
            let previousByID = Dictionary(input.previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (id, current) in entries {
                if let old = previousByID[id], !old.lastKnownFrames.isEmpty {
                    var updated = current
                    updated.lastKnownFrames = old.lastKnownFrames
                    entries[id] = updated
                }
            }
        }

        return entries.values.sorted(by: ordering)
    }

    /// Left-to-right by the first visible slot on the main display, then by last known
    /// position, then by id.
    static func ordering(_ lhs: CatalogEntry, _ rhs: CatalogEntry) -> Bool {
        let l = sortX(lhs), r = sortX(rhs)
        if l != r { return l < r }
        return lhs.id < rhs.id
    }

    private static func sortX(_ entry: CatalogEntry) -> CGFloat {
        if let slot = entry.slots.filter({ !$0.isOverflowed }).min(by: { $0.frame.minX < $1.frame.minX }) {
            return slot.frame.minX
        }
        return entry.lastKnownFrames.map(\.minX).min() ?? .greatestFiniteMagnitude
    }

    /// Owners that count as present for the planner: assignable entries with items or slots.
    public static func presentOwners(_ entries: [CatalogEntry]) -> Set<OwnerID> {
        Set(entries.compactMap { entry in
            guard let owner = entry.owner else { return nil }
            return (entry.itemCount > 0 || !entry.slots.isEmpty || entry.isCarriedOver || entry.isUnreadable) ? owner : nil
        })
    }
}
