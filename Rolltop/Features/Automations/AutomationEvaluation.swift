import Foundation
import RolltopCore

// The state every condition is evaluated against, and the pure evaluation functions.
// Live monitors fill an `AutomationEnvironment`; tests build one by hand.

nonisolated struct AutomationPowerState: Hashable, Sendable {
    enum Source: String, Sendable {
        case ac, battery, ups, unknown
    }
    var source: Source = .unknown
    /// Nil when no battery reports it.
    var isCharging: Bool?
    /// Percent of the internal battery, nil without one.
    var level: Int?
}

nonisolated struct AutomationWiFiState: Hashable, Sendable {
    var isConnected = false
    /// Whether the network name can be read (Location permission granted).
    var canReadNetworkName = false
    /// The current network name, when connected and readable.
    var networkName: String?
}

nonisolated struct AutomationAppsState: Hashable, Sendable {
    var running: Set<String> = []
    var frontmost: String?
}

nonisolated struct AutomationDisplaysState: Hashable, Sendable {
    var count = 1
    var builtInCount = 1

    var externalCount: Int { count - builtInCount }
}

/// The last run of one script condition.
nonisolated struct AutomationScriptOutcome: Hashable, Sendable {
    var finishedAt: Date
    var exitStatus: Int32?
    var timedOut = false
    var output = ""
    var duration: TimeInterval = 0
    /// Could not start (missing shell…).
    var launchError: String?

    var succeeded: Bool { exitStatus == 0 && !timedOut && launchError == nil }
}

nonisolated struct AutomationEnvironment: Hashable, Sendable {
    var now = Date()
    /// Follows time zone and locale changes.
    var calendar = Calendar.autoupdatingCurrent
    var power = AutomationPowerState()
    var wifi = AutomationWiFiState()
    var apps = AutomationAppsState()
    var displays = AutomationDisplaysState()
    /// By condition id. A script that has not run yet counts as false.
    var scripts: [String: AutomationScriptOutcome] = [:]
    /// Extension point (planned "item changed" condition): when each owner's item image
    /// last changed. Nothing fills it in this milestone.
    var itemChanges: [OwnerID: Date] = [:]
    /// The last location fix; nil while unknown (not allowed, no fix yet, no place rule).
    var location: AutomationLocationFix?
    /// Inside or not, by place condition id, as of `location` (keeps the hysteresis state).
    var placeStates: [String: Bool] = [:]

    /// The place condition's value, or nil while the location is unknown.
    func placeHolds(_ condition: AutomationPlaceCondition, id: String) -> Bool? {
        let inside = AutomationPlaceDecision.isInside(previous: placeStates[id], fix: location, place: condition.place)
        return AutomationPlaceDecision.holds(condition, inside: inside)
    }
}

nonisolated enum AutomationEvaluator {
    /// A rule with no conditions is never active.
    static func evaluate(_ rule: AutomationRule, in environment: AutomationEnvironment) -> Bool {
        guard !rule.conditions.isEmpty else { return false }
        switch rule.match {
        case .all: return rule.conditions.allSatisfy { evaluate($0, in: environment) }
        case .any: return rule.conditions.contains { evaluate($0, in: environment) }
        }
    }

    static func evaluate(_ condition: AutomationCondition, in environment: AutomationEnvironment) -> Bool {
        switch condition.kind {
        case .power(let power): evaluate(power, environment.power)
        case .wifi(let wifi): evaluate(wifi, environment.wifi)
        case .app(let app): evaluate(app, environment.apps)
        case .time(let time): contains(time, date: environment.now, calendar: environment.calendar)
        case .displays(let displays): evaluate(displays, environment.displays)
        case .script: environment.scripts[condition.id]?.succeeded ?? false
        case .place(let place): environment.placeHolds(place, id: condition.id) ?? false
        case .itemChanged(let item):
            environment.itemChanges[item.owner].map { environment.now.timeIntervalSince($0) < Double(item.holdSeconds) } ?? false
        case .unsupported: false
        }
    }

    static func evaluate(_ condition: AutomationPowerCondition, _ state: AutomationPowerState) -> Bool {
        switch condition.test {
        case .onBattery: state.source == .battery
        case .onAC: state.source == .ac
        case .charging: state.isCharging == true
        case .notCharging: state.isCharging == false
        case .levelBelow: state.level.map { $0 < condition.percent } ?? false
        case .levelAbove: state.level.map { $0 > condition.percent } ?? false
        }
    }

    /// Network names are compared exactly after trimming spaces (names are case-sensitive).
    /// Without Location permission the name is unknown and the condition is false.
    static func evaluate(_ condition: AutomationWiFiCondition, _ state: AutomationWiFiState) -> Bool {
        switch condition.test {
        case .connected: return state.isConnected
        case .notConnected: return !state.isConnected
        case .connectedTo:
            guard state.isConnected, state.canReadNetworkName, let name = state.networkName else { return false }
            let wanted = Set(condition.networks.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            return wanted.contains(name)
        }
    }

    static func evaluate(_ condition: AutomationAppCondition, _ state: AutomationAppsState) -> Bool {
        guard !condition.bundleID.isEmpty else { return false }
        switch condition.test {
        case .running: return state.running.contains(condition.bundleID)
        case .notRunning: return !state.running.contains(condition.bundleID)
        case .frontmost: return state.frontmost == condition.bundleID
        case .notFrontmost: return state.frontmost != condition.bundleID
        }
    }

    static func evaluate(_ condition: AutomationDisplayCondition, _ state: AutomationDisplaysState) -> Bool {
        switch condition.test {
        case .builtInOnly: state.count > 0 && state.externalCount == 0
        case .externalConnected: state.externalCount > 0
        case .countAtLeast: state.count >= condition.count
        case .countExactly: state.count == condition.count
        }
    }

    /// Whether `date` falls in the time window. A window crossing midnight belongs to the
    /// day it starts on; start == end covers whole selected days.
    static func contains(_ window: AutomationTimeCondition, date: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute else { return false }
        let now = hour * 60 + minute
        let days = Set(window.weekdays)
        let yesterday = (weekday + 5) % 7 + 1
        let start = clampMinutes(window.start)
        let end = clampMinutes(window.end)
        if start == end { return days.contains(weekday) }
        if start < end { return days.contains(weekday) && now >= start && now < end }
        return (days.contains(weekday) && now >= start) || (days.contains(yesterday) && now < end)
    }

    static func clampMinutes(_ minutes: Int) -> Int { min(max(0, minutes), 24 * 60 - 1) }

    /// The next whole minute after `date`: time windows can only change state then.
    static func nextMinuteBoundary(after date: Date, calendar: Calendar) -> Date {
        let start = calendar.dateInterval(of: .minute, for: date)?.start ?? date
        return start.addingTimeInterval(60)
    }
}
