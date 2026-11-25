import Foundation
import RolltopCore

// Pure bookkeeping of the rule engine: debouncing, forced-visible sources, and the
// "restore the previous profile" ledger. No side effects; the controller applies results.

// MARK: - Debounce

/// Per-rule state: the committed (acted upon) value and a pending change.
nonisolated struct AutomationRuleRuntime: Hashable, Sendable {
    var isActive = false
    var pendingValue: Bool?
    var pendingSince: Date?

    var isPending: Bool { pendingValue != nil }
}

nonisolated struct AutomationTransition: Hashable, Sendable {
    var ruleID: String
    var isActive: Bool
}

nonisolated enum AutomationDebouncer {
    /// Feeds the raw evaluation of every rule (in rule order). A change is committed only
    /// after the raw value held for `stability` seconds; a value that flips back before
    /// then cancels the change, so a flapping condition never flickers the bar.
    /// Rules in `immediate` (disabled, paused) commit at once. Rules missing from `raw`
    /// (deleted) end at once and are forgotten.
    ///
    /// Returns the committed transitions (in rule order, then deleted rules) and the
    /// earliest time a pending change could commit.
    static func step(_ runtimes: inout [String: AutomationRuleRuntime],
                     raw: [(id: String, value: Bool)],
                     immediate: Set<String> = [],
                     now: Date,
                     stability: TimeInterval) -> (transitions: [AutomationTransition], nextDeadline: Date?) {
        var transitions: [AutomationTransition] = []
        var deadline: Date?
        let present = Set(raw.map(\.id))

        for (id, value) in raw {
            var runtime = runtimes[id] ?? AutomationRuleRuntime()
            if value == runtime.isActive {
                runtime.pendingValue = nil
                runtime.pendingSince = nil
            } else if immediate.contains(id) || stability <= 0 {
                runtime = AutomationRuleRuntime(isActive: value)
                transitions.append(AutomationTransition(ruleID: id, isActive: value))
            } else if runtime.pendingValue == value, let since = runtime.pendingSince {
                let due = since.addingTimeInterval(stability)
                if now >= due {
                    runtime = AutomationRuleRuntime(isActive: value)
                    transitions.append(AutomationTransition(ruleID: id, isActive: value))
                } else {
                    deadline = min(deadline ?? due, due)
                }
            } else {
                runtime.pendingValue = value
                runtime.pendingSince = now
                let due = now.addingTimeInterval(stability)
                deadline = min(deadline ?? due, due)
            }
            runtimes[id] = runtime
        }

        for id in runtimes.keys.sorted() where !present.contains(id) {
            if runtimes[id]?.isActive == true { transitions.append(AutomationTransition(ruleID: id, isActive: false)) }
            runtimes[id] = nil
        }
        return (transitions, deadline)
    }
}

// MARK: - Forced visibility

nonisolated enum AutomationForcedVisibility {
    static let sourcePrefix = "automations."

    static func source(for ruleID: String) -> String { sourcePrefix + ruleID }

    /// One source per active rule that shows items. Overlapping rules keep separate
    /// sources; the engine unions them, so an owner stays forced while any rule wants it.
    static func plan(rules: [AutomationRule], active: Set<String>) -> [String: Set<OwnerID>] {
        var plan: [String: Set<OwnerID>] = [:]
        for rule in rules where active.contains(rule.id) && !rule.actions.showItems.isEmpty {
            plan[source(for: rule.id)] = Set(rule.actions.showItems)
        }
        return plan
    }

    /// The `setForcedVisible` calls that turn `applied` into `planned` (an empty set
    /// removes a source), sorted by source.
    static func updates(from applied: [String: Set<OwnerID>],
                        to planned: [String: Set<OwnerID>]) -> [(source: String, owners: Set<OwnerID>)] {
        var updates: [(source: String, owners: Set<OwnerID>)] = []
        for source in Set(applied.keys).union(planned.keys).sorted() {
            let new = planned[source] ?? []
            if (applied[source] ?? []) != new { updates.append((source, new)) }
        }
        return updates
    }
}

// MARK: - Restore previous profile

/// A stack of profile overrides made by rules with "restore the previous profile".
///
/// - A rule that applies a profile records what was in effect before (profile id and
///   layout), unless it already has an entry (e.g. still active from before a relaunch).
/// - When the top rule ends and its profile is still the active one, the previous state
///   comes back. If the user (or a rule without restore) switched profiles meanwhile,
///   nothing is restored.
/// - When a rule below the top ends, nothing changes now; the rule above it inherits its
///   "previous", so the state before both rules comes back when the last one ends.
nonisolated struct AutomationProfileLedger: Codable, Hashable, Sendable {
    struct Entry: Codable, Hashable, Sendable {
        var ruleID: String
        var appliedProfileID: String
        var previousProfileID: String?
        var previousLayout: Layout
    }

    enum Restore: Hashable, Sendable {
        case nothing
        /// Apply this profile again.
        case profile(String)
        /// No profile was active (or it was deleted): put the layout back, no active profile.
        case layout(Layout)
    }

    var entries: [Entry] = []

    mutating func recordApply(ruleID: String, profileID: String, previousProfileID: String?, previousLayout: Layout) {
        if let index = entries.firstIndex(where: { $0.ruleID == ruleID }) {
            entries[index].appliedProfileID = profileID
            return
        }
        entries.append(Entry(ruleID: ruleID, appliedProfileID: profileID, previousProfileID: previousProfileID,
                             previousLayout: previousLayout))
    }

    func hasEntry(for ruleID: String) -> Bool { entries.contains { $0.ruleID == ruleID } }

    mutating func ruleEnded(_ ruleID: String, activeProfileID: String?, existingProfileIDs: Set<String>) -> Restore {
        guard let index = entries.firstIndex(where: { $0.ruleID == ruleID }) else { return .nothing }
        let entry = entries.remove(at: index)
        if index < entries.count {
            entries[index].previousProfileID = entry.previousProfileID
            entries[index].previousLayout = entry.previousLayout
            return .nothing
        }
        guard activeProfileID == entry.appliedProfileID else { return .nothing }
        if let previous = entry.previousProfileID, existingProfileIDs.contains(previous) {
            return .profile(previous)
        }
        return .layout(entry.previousLayout)
    }

    /// Drops entries of rules that no longer exist, without restoring anything.
    mutating func prune(keeping ruleIDs: Set<String>) {
        entries.removeAll { !ruleIDs.contains($0.ruleID) }
    }
}

// MARK: - Log

nonisolated struct AutomationLogEntry: Hashable, Sendable, Identifiable {
    enum Kind: String, Sendable {
        case activated, deactivated, note, error
    }
    let id = UUID()
    var date: Date
    var kind: Kind
    var message: String?

    static let limit = 12
}
