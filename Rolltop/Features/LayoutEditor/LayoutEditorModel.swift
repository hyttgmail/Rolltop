import CoreGraphics
import Foundation
import RolltopCore

// The Menu Bar Items editor's decisions, as plain values: which owners go on which shelf
// and in what order, what a drop does, filtering and selection. Every function here is
// pure and unit-tested (RolltopTests/LayoutEditor); the views only render and apply.

// MARK: - Notes

/// What the editor says about an item besides its section, most important first.
nonisolated enum LayoutEditorNote: Hashable, Sendable, Codable {
    /// macOS hides third-party apps that run outside /Applications, whatever the section.
    case outsideApplications
    /// The app's Accessibility tree timed out or is refused.
    case unreadable
    /// A system module whose id macOS expects was not confirmed on a real machine.
    case unverifiedModule
    /// Laid out, but under the menu bar's overflow chevron.
    case overflowed
    /// Not in the menu bar right now (hidden by Rolltop).
    case hiddenNow
    /// Several items: they always move together.
    case itemCount(Int)

    /// Limits that change what the user sees whatever the section.
    var isWarning: Bool {
        switch self {
        case .outsideApplications, .unreadable, .unverifiedModule: true
        default: false
        }
    }

    /// `drawnIsReadable`: whether list B could be read at all; without it nothing is known
    /// about what is drawn, so "hidden now" is not claimed.
    static func notes(for entry: CatalogEntry, drawnIsReadable: Bool) -> [LayoutEditorNote] {
        var notes: [LayoutEditorNote] = []
        if entry.runsOutsideApplications { notes.append(.outsideApplications) }
        if entry.isUnreadable { notes.append(.unreadable) }
        if let module = entry.owner?.systemModule, !module.isVerified { notes.append(.unverifiedModule) }
        if entry.isOverflowed {
            notes.append(.overflowed)
        } else if drawnIsReadable, !entry.isDrawn, !entry.runsOutsideApplications {
            notes.append(.hiddenNow)
        }
        if entry.itemCount > 1 { notes.append(.itemCount(entry.itemCount)) }
        return notes
    }
}

// MARK: - Cluster

/// One owner on a shelf: all items of one app (or one system module). macOS hides per app
/// (docs/PLATFORM.md §3), so the items of a cluster always move together.
nonisolated struct LayoutEditorCluster: Identifiable, Equatable, Sendable {
    enum DrawState: String, Equatable, Sendable, Codable {
        /// At least one item is visible in a menu bar.
        case drawn
        /// Laid out, but every item sits under the system's overflow chevron.
        case overflowed
        /// Not in the menu bar right now.
        case notDrawn
        /// What is drawn could not be read (no Accessibility, MenuBarAgent timed out).
        case unknown
    }

    var owner: OwnerID
    var id: String { owner.stringValue }
    var name: String
    var isSystem: Bool
    /// From the layout (explicit or default), never from the bar position.
    var section: RolltopCore.Section
    var hasExplicitSection: Bool
    /// Items the owner has in the bar; at least 1.
    var itemCount: Int
    var drawState: DrawState
    var notes: [LayoutEditorNote]
    /// Rolltop itself: always shown, cannot be moved.
    var isOwn: Bool

    var isMovable: Bool { !isOwn }
    var warnings: [LayoutEditorNote] { notes.filter(\.isWarning) }

    static func drawState(of entry: CatalogEntry, drawnIsReadable: Bool) -> DrawState {
        guard drawnIsReadable else { return .unknown }
        if entry.isDrawn { return .drawn }
        if entry.isOverflowed { return .overflowed }
        return .notDrawn
    }
}

/// An owner with a saved section that is not in the bar (app not running, module absent).
nonisolated struct LayoutEditorSavedOwner: Identifiable, Equatable, Sendable {
    var owner: OwnerID
    var id: String { owner.stringValue }
    var name: String
    var section: RolltopCore.Section
}

/// Something in the bar that cannot be assigned (macOS-managed extras, processes without
/// a bundle id).
nonisolated struct LayoutEditorFixedItem: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
}

// MARK: - Board

/// Everything the editor shows, grouped and ordered.
nonisolated struct LayoutEditorBoard: Equatable, Sendable {
    var shown: [LayoutEditorCluster] = []
    var hidden: [LayoutEditorCluster] = []
    var alwaysHidden: [LayoutEditorCluster] = []
    /// Where apps Rolltop has not seen go (the "New items" marker's shelf).
    var defaultSection: RolltopCore.Section = .shown
    /// AirDrop, Focus, Now Playing…: any restriction hides them.
    var managed: [LayoutEditorFixedItem] = []
    /// Processes without a bundle id: cannot be allowed, so any restriction hides them.
    var unidentified: [LayoutEditorFixedItem] = []
    /// Owners with a saved section and no catalog entry.
    var notRunning: [LayoutEditorSavedOwner] = []
    /// Whether list B could be read: without it nothing is known about what is drawn.
    var drawnIsReadable = false

    func clusters(in section: RolltopCore.Section) -> [LayoutEditorCluster] {
        switch section {
        case .shown: shown
        case .hidden: hidden
        case .alwaysHidden: alwaysHidden
        }
    }

    /// Movable clusters in a section (the count a shelf shows; Rolltop itself is not counted).
    func movableCount(in section: RolltopCore.Section) -> Int {
        clusters(in: section).count { $0.isMovable }
    }

    var allClusters: [LayoutEditorCluster] { shown + hidden + alwaysHidden }

    /// Clusters with a limit worth stating in the "Notes" group.
    var noted: [LayoutEditorCluster] { allClusters.filter { !$0.warnings.isEmpty } }

    func cluster(for owner: OwnerID) -> LayoutEditorCluster? {
        allClusters.first { $0.owner == owner }
    }

    func savedOwner(for owner: OwnerID) -> LayoutEditorSavedOwner? {
        notRunning.first { $0.owner == owner }
    }

    var isEmpty: Bool {
        allClusters.isEmpty && managed.isEmpty && unidentified.isEmpty && notRunning.isEmpty
    }

    /// Builds the board from the catalog (left to right), the layout (source of truth for
    /// sections) and the drawn snapshot (order and drawn state).
    /// `name`: the owner's localized fixed name; nil falls back to the entry's name.
    /// Rolltop's own items (its icon, custom items) are not read through Accessibility, so
    /// their count comes from the slots MenuBarAgent lays out, on the display with most.
    static func slotsPerDisplay(_ entry: CatalogEntry) -> Int {
        Dictionary(grouping: entry.slots, by: \.displayID).values.map(\.count).max() ?? 0
    }

    static func make(entries: [CatalogEntry], layout: Layout, drawn: DrawnSnapshot,
                     name: (OwnerID) -> String? = { _ in nil }) -> LayoutEditorBoard {
        var board = LayoutEditorBoard(defaultSection: layout.defaultSection, drawnIsReadable: drawn.isReadable)
        var listed = Set<OwnerID>()
        for entry in LayoutEditorOrdering.sorted(clusterByOwner(entries), drawn: drawn) {
            switch entry.kind {
            case .macOSManaged:
                board.managed.append(LayoutEditorFixedItem(id: entry.id, name: entry.displayName))
                continue
            case .unidentified:
                board.unidentified.append(LayoutEditorFixedItem(id: entry.id, name: entry.displayName))
                continue
            case .app, .system:
                break
            }
            guard let owner = entry.owner else {
                board.unidentified.append(LayoutEditorFixedItem(id: entry.id, name: entry.displayName))
                continue
            }
            listed.insert(owner)
            // The layout is the source of truth; the entry's section may lag one rebuild.
            // Rolltop itself is always shown.
            let section = entry.isOwn ? .shown : layout.section(for: owner)
            let cluster = LayoutEditorCluster(
                owner: owner, name: name(owner) ?? entry.displayName, isSystem: entry.kind == .system,
                section: section, hasExplicitSection: layout.hasExplicitSection(owner),
                itemCount: max(1, entry.itemCount, entry.isOwn ? Self.slotsPerDisplay(entry) : 0),
                drawState: LayoutEditorCluster.drawState(of: entry, drawnIsReadable: drawn.isReadable),
                notes: LayoutEditorNote.notes(for: entry, drawnIsReadable: drawn.isReadable), isOwn: entry.isOwn)
            switch section {
            case .shown: board.shown.append(cluster)
            case .hidden: board.hidden.append(cluster)
            case .alwaysHidden: board.alwaysHidden.append(cluster)
            }
        }
        board.notRunning = layout.sections
            .filter { !listed.contains($0.key) }
            .map { LayoutEditorSavedOwner(owner: $0.key, name: name($0.key) ?? $0.key.stringValue, section: $0.value) }
            .sorted { lhs, rhs in
                let order = lhs.name.localizedStandardCompare(rhs.name)
                return order == .orderedSame ? lhs.owner < rhs.owner : order == .orderedAscending
            }
        return board
    }

    /// Merges entries that share an owner into one (all of an app's items move together).
    /// The catalog already keys entries by owner; this keeps the editor correct if a
    /// future catalog lists an app's processes separately. Keeps the first entry's position.
    static func clusterByOwner(_ entries: [CatalogEntry]) -> [CatalogEntry] {
        var result: [CatalogEntry] = []
        var indexByOwner: [OwnerID: Int] = [:]
        for entry in entries {
            guard let owner = entry.owner else {
                result.append(entry)
                continue
            }
            guard let index = indexByOwner[owner] else {
                indexByOwner[owner] = result.count
                result.append(entry)
                continue
            }
            var merged = result[index]
            merged.itemCount += entry.itemCount
            merged.pids += entry.pids.filter { !merged.pids.contains($0) }
            merged.axIdentifiers += entry.axIdentifiers.filter { !merged.axIdentifiers.contains($0) }
            merged.slots += entry.slots
            merged.lastKnownFrames += entry.lastKnownFrames
            merged.runsOutsideApplications = merged.runsOutsideApplications || entry.runsOutsideApplications
            merged.isUnreadable = merged.isUnreadable || entry.isUnreadable
            merged.isOwn = merged.isOwn || entry.isOwn
            merged.isCarriedOver = merged.isCarriedOver && entry.isCarriedOver
            result[index] = merged
        }
        return result
    }

    /// The board narrowed to what matches `query` (see `LayoutEditorFilter`). Shelves keep
    /// their order; the marker is not an item and is never filtered out.
    func filtered(by query: String) -> LayoutEditorBoard {
        let tokens = LayoutEditorFilter.tokens(query)
        guard !tokens.isEmpty else { return self }
        var copy = self
        copy.shown = shown.filter { LayoutEditorFilter.matches(name: $0.name, id: $0.id, tokens: tokens) }
        copy.hidden = hidden.filter { LayoutEditorFilter.matches(name: $0.name, id: $0.id, tokens: tokens) }
        copy.alwaysHidden = alwaysHidden.filter { LayoutEditorFilter.matches(name: $0.name, id: $0.id, tokens: tokens) }
        copy.managed = managed.filter { LayoutEditorFilter.matches(name: $0.name, id: $0.id, tokens: tokens) }
        copy.unidentified = unidentified.filter { LayoutEditorFilter.matches(name: $0.name, id: $0.id, tokens: tokens) }
        copy.notRunning = notRunning.filter { LayoutEditorFilter.matches(name: $0.name, id: $0.id, tokens: tokens) }
        return copy
    }
}

// MARK: - Ordering

/// Order within a shelf follows the real menu bar, left to right. Status items are
/// trailing-aligned on every display, so the distance from the bar's trailing edge
/// compares positions across displays (global x does not: displays sit side by side).
nonisolated enum LayoutEditorOrdering {
    /// How far left of its bar's trailing edge the owner sits (larger = further left), or
    /// nil when nothing places it.
    /// 1. Slots on the main display, visible ones first (overflowed slots stack under the
    ///    chevron, the leftmost place in the status area).
    /// 2. Slots on another display.
    /// 3. The last frame the app reported (hidden items keep their last position there),
    ///    measured against the display whose bar spans it.
    static func trailingOffset(of entry: CatalogEntry, in drawn: DrawnSnapshot) -> CGFloat? {
        let displays = drawn.displays.sorted { $0.isMain && !$1.isMain }
        for display in displays {
            let slots = entry.slots.filter { $0.displayID == display.displayID }
            let candidates = slots.contains { !$0.isOverflowed } ? slots.filter { !$0.isOverflowed } : slots
            if let minX = candidates.map(\.frame.minX).min() {
                return display.barFrame.maxX - minX
            }
        }
        // Slots on a display the snapshot does not describe: no common reference.
        guard let frame = entry.lastKnownFrames.min(by: { $0.minX < $1.minX }) else { return nil }
        let bar = displays.first { $0.barFrame.minX <= frame.midX && frame.midX < $0.barFrame.maxX }
        return bar.map { $0.barFrame.maxX - frame.minX }
    }

    /// Placed entries left to right, then unplaced ones in their incoming (catalog) order.
    static func sorted(_ entries: [CatalogEntry], drawn: DrawnSnapshot) -> [CatalogEntry] {
        let keyed = entries.enumerated().map { (index: $0.offset, entry: $0.element, offset: trailingOffset(of: $0.element, in: drawn)) }
        return keyed.sorted { lhs, rhs in
            switch (lhs.offset, rhs.offset) {
            case let (l?, r?) where l != r: return l > r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.index < rhs.index
            }
        }
        .map(\.entry)
    }
}

// MARK: - Drag payload and drops

/// What can be dragged between shelves. Travels as a plain string (a custom type would
/// need an exported UTType in Info.plist), so drops validate the prefix.
nonisolated enum LayoutEditorPayload: Hashable, Sendable {
    case owner(OwnerID)
    /// The "New items appear here" marker.
    case marker

    static let prefix = "rolltop-layout-editor:"
    private static let markerValue = "new-items"

    var stringValue: String {
        switch self {
        case .owner(let owner): Self.prefix + "owner:" + owner.stringValue
        case .marker: Self.prefix + Self.markerValue
        }
    }

    init?(stringValue: String) {
        guard stringValue.hasPrefix(Self.prefix) else { return nil }
        let rest = stringValue.dropFirst(Self.prefix.count)
        if rest == Self.markerValue {
            self = .marker
        } else if rest.hasPrefix("owner:"), let owner = OwnerID(stringValue: String(rest.dropFirst("owner:".count))) {
            self = .owner(owner)
        } else {
            return nil
        }
    }
}

/// A change to the layout, decided by `LayoutEditorDrop` and applied by the view.
nonisolated enum LayoutEditorEdit: Equatable, Sendable {
    case none
    case setSection(OwnerID, RolltopCore.Section)
    /// Present owners are frozen first, so items already in the bar keep their section.
    case setDefaultSection(RolltopCore.Section, freezing: Set<OwnerID>)

    /// The layout after the edit, exactly as `LayoutStore` computes it.
    func applied(to layout: Layout) -> Layout {
        var copy = layout
        switch self {
        case .none:
            break
        case .setSection(let owner, let section):
            copy.setSection(section, for: owner)
        case .setDefaultSection(let section, let owners):
            copy = copy.freezingSections(of: owners)
            copy.defaultSection = section
        }
        return copy
    }
}

nonisolated enum LayoutEditorDrop {
    /// What dropping `payload` on the shelf of `section` does.
    /// - An item dropped where it already is changes nothing (no explicit entry is written).
    /// - Rolltop's own items cannot move.
    /// - The marker sets the section for new items and freezes `presentOwners` first.
    static func edit(dropping payload: LayoutEditorPayload, on section: RolltopCore.Section, layout: Layout,
                     presentOwners: Set<OwnerID>, ownOwners: Set<OwnerID>) -> LayoutEditorEdit {
        switch payload {
        case .owner(let owner):
            guard !ownOwners.contains(owner), layout.section(for: owner) != section else { return .none }
            return .setSection(owner, section)
        case .marker:
            // Same freeze as `layout.set-default-section` and the General pane.
            guard layout.defaultSection != section else { return .none }
            return .setDefaultSection(section, freezing: presentOwners)
        }
    }
}

// MARK: - Filter

nonisolated enum LayoutEditorFilter {
    static func tokens(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Every token must appear in the name or the id (bundle id / `system:wifi`), ignoring
    /// case and diacritics.
    static func matches(name: String, id: String, tokens: [String]) -> Bool {
        tokens.allSatisfy { token in
            name.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || id.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

// MARK: - Selection

/// The selected thing: an owner (on a shelf or not running) or the marker. Keyed by owner,
/// never by position, so it survives catalog refreshes and reordering.
nonisolated enum LayoutEditorSelection: Hashable, Sendable {
    case owner(OwnerID)
    case marker

    enum Direction: Sendable { case left, right, up, down }

    /// The selection after the board changed: kept while its owner is listed anywhere
    /// (a quitting app moves to "Not running" and stays selected), dropped once it is gone.
    static func surviving(_ selection: LayoutEditorSelection?, in board: LayoutEditorBoard) -> LayoutEditorSelection? {
        switch selection {
        case nil: nil
        case .marker: .marker
        case .owner(let owner):
            board.cluster(for: owner) != nil || board.savedOwner(for: owner) != nil ? selection : nil
        }
    }

    /// Selectable things on one shelf, left to right: its clusters, then the marker on the
    /// shelf of the default section.
    static func row(_ section: RolltopCore.Section, in board: LayoutEditorBoard) -> [LayoutEditorSelection] {
        var row = board.clusters(in: section).map { LayoutEditorSelection.owner($0.owner) }
        if board.defaultSection == section { row.append(.marker) }
        return row
    }

    /// Arrow keys: left/right step through the shelves in reading order, up/down jump to
    /// the nearest position on the shelf above/below (empty shelves are skipped). Without a
    /// selection, any arrow selects the first thing on the focused shelf.
    static func moved(_ selection: LayoutEditorSelection?, _ direction: Direction, in board: LayoutEditorBoard,
                      focusedShelf: RolltopCore.Section) -> LayoutEditorSelection? {
        let rows = RolltopCore.Section.allCases.map { row($0, in: board) }
        let position: (row: Int, column: Int)? = selection.flatMap { selection in
            for (r, row) in rows.enumerated() {
                if let c = row.firstIndex(of: selection) { return (r, c) }
            }
            return nil
        }
        guard let position else {
            let focused = RolltopCore.Section.allCases.firstIndex(of: focusedShelf) ?? 0
            return rows[focused].first ?? rows.first { !$0.isEmpty }?.first
        }
        switch direction {
        case .left, .right:
            let flat = rows.flatMap { $0 }
            guard let index = flat.firstIndex(of: rows[position.row][position.column]) else { return selection }
            let next = direction == .left ? index - 1 : index + 1
            return flat.indices.contains(next) ? flat[next] : selection
        case .up, .down:
            let step = direction == .up ? -1 : 1
            var r = position.row + step
            while rows.indices.contains(r) {
                if !rows[r].isEmpty { return rows[r][min(position.column, rows[r].count - 1)] }
                r += step
            }
            return selection
        }
    }

    /// The shelf a selection sits on (for focus), nil for owners that are not running.
    static func shelf(of selection: LayoutEditorSelection?, in board: LayoutEditorBoard) -> RolltopCore.Section? {
        switch selection {
        case nil: nil
        case .marker: board.defaultSection
        case .owner(let owner): board.cluster(for: owner)?.section
        }
    }
}
