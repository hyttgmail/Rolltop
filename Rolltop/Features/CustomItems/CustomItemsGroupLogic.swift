import Foundation
import RolltopCore

/// Group membership and panel toggling decisions. Pure, unit-tested.
nonisolated enum CustomItemsGroupLogic {
    /// The members the panel shows, in the group's order: running apps (an app started
    /// while hidden has no catalog entry yet but can still be revealed and pressed) and
    /// system modules that are present. Rolltop itself, unparsable ids and duplicates are
    /// skipped.
    static func presentableMembers(_ members: [String], runningBundleIDs: Set<String>, presentOwners: Set<OwnerID>,
                                   ownBundleIDs: Set<String>) -> [OwnerID] {
        var seen: Set<OwnerID> = []
        var result: [OwnerID] = []
        for raw in members {
            guard let owner = OwnerID(stringValue: raw), seen.insert(owner).inserted else { continue }
            switch owner {
            case .app(let bundleID):
                guard !ownBundleIDs.contains(bundleID), runningBundleIDs.contains(bundleID) else { continue }
            case .system:
                guard presentOwners.contains(owner) else { continue }
            }
            result.append(owner)
        }
        return result
    }

    /// Owners a member picker offers: assignable catalog owners that are not Rolltop's own and
    /// not members yet, in catalog (left-to-right) order.
    static func candidates(entries: [CatalogEntry], members: [String]) -> [OwnerID] {
        let taken = Set(members)
        var seen: Set<OwnerID> = []
        return entries.compactMap { entry in
            guard let owner = entry.owner, !entry.isOwn, !taken.contains(owner.stringValue), seen.insert(owner).inserted else { return nil }
            return owner
        }
    }

    /// Adding a member shown in the bar offers to move it to Hidden, so the group actually
    /// tidies the bar.
    static func suggestsHiding(section: Section) -> Bool { section == .shown }

    /// The "Hidden apps" template: owners explicitly in the hidden section, present ones
    /// first in bar order, then the rest by name.
    static func hiddenAppsMembers(layout: Layout, entries: [CatalogEntry]) -> [String] {
        let hidden = Set(layout.explicitOwners(in: .hidden))
        var ordered: [OwnerID] = []
        for entry in entries {
            if let owner = entry.owner, hidden.contains(owner), !ordered.contains(owner) { ordered.append(owner) }
        }
        ordered += hidden.subtracting(ordered).sorted()
        return ordered.map(\.stringValue)
    }

    // MARK: Toggling

    /// What a group does when macOS begins an expanded-interface session for its item
    /// (a click on it).
    enum SessionDecision: Equatable {
        /// Show the panel (or the empty state) and keep the session.
        case present
        /// The same click just closed this group's panel (the panel's click-outside monitor
        /// saw the mouse-down first): end the new session instead of reopening.
        case cancel
    }

    /// Clicks that close a panel are seen by its click-outside monitor on mouse-down, before
    /// the item's session begins on mouse-up; anything closer than this counts as one click.
    static let reopenGuard: TimeInterval = 0.5

    static func decideSessionBegin(group: String, panelVisibleFor visibleGroup: String?,
                                   lastClosed: (group: String, secondsAgo: TimeInterval)?) -> SessionDecision {
        if visibleGroup == group { return .cancel }
        if let lastClosed, lastClosed.group == group, lastClosed.secondsAgo < reopenGuard { return .cancel }
        return .present
    }
}
