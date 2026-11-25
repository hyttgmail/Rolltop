import Foundation

/// Keys of MenuBarAgent's order table (`TrailingItemPreferredPositions`, PLATFORM §5):
/// `status:<bundle id or process name>::<autosave name or Item-N>` and `module:<Name>`,
/// mapped to weights. A larger weight sits further left (the weight is roughly the
/// distance from the right edge; `module:Clock` is 0).
public enum MenuBarOrderKeys {
    /// The table keys that belong to `owner`. An app owns every `status:<bundle id>::…` row
    /// (matched on the exact text before `::`, never as a prefix: `com.example.app` must not
    /// match `com.example.app.helper`). A system module owns its `module:<Name>` row.
    /// Rows a process published under its process name (no bundle id) are not matched.
    public static func keys(for owner: OwnerID, in table: [String: Double]) -> [String] {
        switch owner {
        case .app(let bundleID):
            return table.keys.filter { statusOwner(of: $0) == bundleID }.sorted()
        case .system(let module):
            guard let key = moduleKey(module), table[key] != nil else { return [] }
            return [key]
        }
    }

    /// `com.foo` for `status:com.foo::Item-0`; nil for anything else.
    public static func statusOwner(of key: String) -> String? {
        guard key.hasPrefix("status:"), let range = key.range(of: "::") else { return nil }
        let owner = key[key.index(key.startIndex, offsetBy: "status:".count)..<range.lowerBound]
        return owner.isEmpty ? nil : String(owner)
    }

    /// The `module:` row of a system module, where it is known (seen in the table on 27.2.1).
    public static func moduleKey(_ module: SystemModule) -> String? {
        switch module {
        case .clock: "module:Clock"
        case .controlCenter: "module:BentoBox-0"
        case .wifi: "module:WiFi"
        case .battery: "module:Battery"
        case .bluetooth: "module:Bluetooth"
        case .sound: "module:Sound"
        case .screenMirroring: "module:ScreenMirroring"
        case .displays, .keyboard: nil
        }
    }

    /// The clock and Control Center never move, and nothing goes right of them.
    public static func isFixed(_ owner: OwnerID) -> Bool {
        owner == .system(.clock) || owner == .system(.controlCenter)
    }
}

/// Plans the smallest change to the order table that moves one unit (all rows of one
/// owner) to a new place in the visual order.
public enum MenuBarOrderPlanner {
    public struct Unit: Sendable, Equatable {
        public var owner: OwnerID
        /// The owner's rows in the table, any order.
        public var keys: [String]

        public init(owner: OwnerID, keys: [String]) {
            self.owner = owner
            self.keys = keys
        }

        public var isFixed: Bool { MenuBarOrderKeys.isFixed(owner) }
    }

    /// The smallest spacing between two planned weights.
    public static let minimumSpacing = 0.5
    /// Room left of the leftmost unit when the moved unit goes to the left end.
    static let endRoom = 20.0

    /// New weights for a move. `order` is the visual order (left to right, as list B shows
    /// it) of the units concerned; `moving` goes to `destination`, an index into `order`
    /// with the moved unit removed (clamped so it stays left of every fixed unit).
    ///
    /// The moved unit gets weights between its new neighbours when there is room; only
    /// when there is none (ties, or neighbours closer than the spacing) a growing
    /// neighbourhood around it is renumbered evenly between the nearest units outside it.
    /// Fixed units never change. Returns only the rows whose weight changes; empty when
    /// the move changes nothing; nil when the move is impossible (fixed or unknown unit,
    /// no rows, no room even after renumbering every movable neighbour).
    public static func plan(table: [String: Double], order: [Unit], moving: OwnerID, to destination: Int) -> [String: Double]? {
        guard let from = order.firstIndex(where: { $0.owner == moving }), !order[from].isFixed,
              !order[from].keys.isEmpty else { return nil }
        var units = order
        let unit = units.remove(at: from)
        let firstFixed = units.firstIndex(where: \.isFixed) ?? units.count
        let target = min(max(destination, 0), firstFixed)
        units.insert(unit, at: target)
        if target == from { return [:] }

        func weights(_ unit: Unit) -> [Double] { unit.keys.compactMap { table[$0] } }
        // Left of `index` = larger weights; the lowest weight of the unit to the left bounds us.
        func upperBound(leftOf index: Int) -> Double? {
            index > 0 ? weights(units[index - 1]).min() : nil
        }
        func lowerBound(rightOf index: Int) -> Double? {
            index < units.count - 1 ? weights(units[index + 1]).max() : nil
        }

        var radius = 0
        while true {
            let low = target - radius, high = target + radius
            guard low >= 0 || high < units.count else { return nil }
            let window = Array(units[max(low, 0)...min(high, units.count - 1)])
            if window.contains(where: \.isFixed) { return nil }
            let keyCount = window.reduce(0) { $0 + $1.keys.count }
            let lower = lowerBound(rightOf: min(high, units.count - 1)) ?? 0
            let upper = upperBound(leftOf: max(low, 0)) ?? (lower + endRoom * Double(keyCount + 1))
            let step = (upper - lower) / Double(keyCount + 1)
            if step >= minimumSpacing {
                var changes: [String: Double] = [:]
                var next = upper
                for unit in window {
                    // Keep each unit's own rows in their current order (left to right).
                    let keys = unit.keys.sorted { (table[$0] ?? 0, $1) > (table[$1] ?? 0, $0) }
                    for key in keys {
                        next -= step
                        let weight = (next * 2).rounded() / 2
                        if table[key] != weight { changes[key] = weight }
                    }
                }
                if isStrictlyDescending(window.flatMap { u in
                    u.keys.sorted { (table[$0] ?? 0, $1) > (table[$1] ?? 0, $0) }.map { changes[$0] ?? table[$0] ?? 0 }
                }, upper: upper, lower: lower) {
                    return changes
                }
            }
            if low <= 0, high >= units.count - 1 { return nil }
            radius += 1
        }
    }

    private static func isStrictlyDescending(_ values: [Double], upper: Double, lower: Double) -> Bool {
        var previous = upper
        for value in values {
            guard value < previous else { return false }
            previous = value
        }
        return previous > lower
    }

    /// Whether list B shows the planned order: among the owners both lists know, the
    /// moved owner sits after the same left neighbour and before the same right neighbour.
    public static func landed(moving: OwnerID, planned: [OwnerID], drawn: [OwnerID]) -> Bool {
        let common = Set(planned).intersection(drawn)
        guard common.contains(moving) else { return false }
        let plannedOrder = planned.filter(common.contains)
        var seen = Set<OwnerID>()
        let drawnOrder = drawn.filter { common.contains($0) && seen.insert($0).inserted }
        guard let p = plannedOrder.firstIndex(of: moving), let d = drawnOrder.firstIndex(of: moving) else { return false }
        let plannedLeft = p > 0 ? plannedOrder[p - 1] : nil
        let plannedRight = p < plannedOrder.count - 1 ? plannedOrder[p + 1] : nil
        let drawnLeft = d > 0 ? drawnOrder[d - 1] : nil
        let drawnRight = d < drawnOrder.count - 1 ? drawnOrder[d + 1] : nil
        return plannedLeft == drawnLeft && plannedRight == drawnRight
    }
}
