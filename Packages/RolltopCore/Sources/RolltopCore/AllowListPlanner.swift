import Foundation

/// What the engine should ask macOS for.
public enum AllowList: Hashable, Sendable {
    /// Hold no restriction at all (macOS-managed items such as AirDrop stay visible).
    case unrestricted
    /// Keep only these system item ids and bundle ids visible. Both arrays are sorted.
    case restricted(systemIDs: [Int], bundleIDs: [String])

    public var isRestricted: Bool {
        if case .restricted = self { return true }
        return false
    }
}

extension AllowList: Codable {
    private enum CodingKeys: String, CodingKey { case restricted, systemIDs, bundleIDs }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(Bool.self, forKey: .restricted) {
            self = .restricted(systemIDs: try container.decode([Int].self, forKey: .systemIDs),
                               bundleIDs: try container.decode([String].self, forKey: .bundleIDs))
        } else {
            self = .unrestricted
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unrestricted:
            try container.encode(false, forKey: .restricted)
        case .restricted(let ids, let bundles):
            try container.encode(true, forKey: .restricted)
            try container.encode(ids, forKey: .systemIDs)
            try container.encode(bundles, forKey: .bundleIDs)
        }
    }
}

/// Everything the planner looks at. A plain value so it can be logged and tested.
public struct AllowListInput: Hashable, Sendable {
    public var layout: Layout
    public var level: PresentationLevel
    /// Conceal the shown section too (except `pinned`): "swap" mode when combined
    /// with a revealed level, "hide everything" when combined with `.collapsed`.
    public var concealShown: Bool
    /// Owners that `concealShown` never conceals (typically clock and Control Center).
    public var pinned: Set<OwnerID>
    /// Owners revealed temporarily (item activation, a hover preview…).
    public var temporaryAllows: Set<OwnerID>
    /// Owners forced visible, keyed by the source that forces them (an automation rule…).
    public var forcedVisible: [String: Set<OwnerID>]
    /// Owners that currently have at least one item in the menu bar (drawn or not).
    public var presentOwners: Set<OwnerID>
    /// Bundle ids that are allowed unless concealed (running apps, present owners).
    public var knownBundleIDs: Set<String>
    /// Our own bundle ids: always allowed.
    public var ownBundleIDs: Set<String>

    public init(layout: Layout = .empty,
                level: PresentationLevel = .collapsed,
                concealShown: Bool = false,
                pinned: Set<OwnerID> = [],
                temporaryAllows: Set<OwnerID> = [],
                forcedVisible: [String: Set<OwnerID>] = [:],
                presentOwners: Set<OwnerID> = [],
                knownBundleIDs: Set<String> = [],
                ownBundleIDs: Set<String> = []) {
        self.layout = layout
        self.level = level
        self.concealShown = concealShown
        self.pinned = pinned
        self.temporaryAllows = temporaryAllows
        self.forcedVisible = forcedVisible
        self.presentOwners = presentOwners
        self.knownBundleIDs = knownBundleIDs
        self.ownBundleIDs = ownBundleIDs
    }
}

/// Pure decision: which owners to conceal and which allow-list to request.
public enum AllowListPlanner {
    /// Whether `owner` must be hidden under `input`. Precedence, highest first:
    /// own bundle → temporary allow → forced visible → section and level.
    public static func isConcealed(_ owner: OwnerID, in input: AllowListInput) -> Bool {
        if let bundle = owner.bundleID, input.ownBundleIDs.contains(bundle) { return false }
        if input.temporaryAllows.contains(owner) { return false }
        if input.forcedVisible.values.contains(where: { $0.contains(owner) }) { return false }
        let section = input.layout.section(for: owner)
        if !input.level.reveals(section) { return true }
        if section == .shown, input.concealShown, !input.pinned.contains(owner) { return true }
        return false
    }

    /// Present owners that must be hidden, sorted.
    public static func concealedPresentOwners(_ input: AllowListInput) -> [OwnerID] {
        input.presentOwners.filter { isConcealed($0, in: input) }.sorted()
    }

    public static func plan(_ input: AllowListInput) -> AllowList {
        // Any restriction also hides macOS-managed items (AirDrop, Focus…), so hold
        // none unless something that is actually in the bar has to go.
        guard !concealedPresentOwners(input).isEmpty else { return .unrestricted }

        let systemIDs = SystemModule.allCases
            .filter { !isConcealed(.system($0), in: input) }
            .map(\.systemItemID)
            .sorted()

        var candidates = input.knownBundleIDs.union(input.ownBundleIDs)
        for owner in input.presentOwners { if let bundle = owner.bundleID { candidates.insert(bundle) } }
        for owner in input.layout.sections.keys { if let bundle = owner.bundleID { candidates.insert(bundle) } }
        for owner in input.temporaryAllows { if let bundle = owner.bundleID { candidates.insert(bundle) } }
        for set in input.forcedVisible.values {
            for owner in set { if let bundle = owner.bundleID { candidates.insert(bundle) } }
        }
        let bundleIDs = candidates
            .filter { !$0.isEmpty && !isConcealed(.app($0), in: input) }
            .sorted()
        return .restricted(systemIDs: systemIDs, bundleIDs: bundleIDs)
    }
}
