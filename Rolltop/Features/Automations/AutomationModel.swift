import Foundation
import RolltopCore

// Pure, Codable model of automation rules. Stable keys; decoding never fails because of
// one unknown or broken element: unknown condition types are kept verbatim (and evaluate
// to false), unreadable rules are skipped.

// MARK: - JSON passthrough

/// Arbitrary JSON, used to keep condition types this build does not know.
nonisolated indirect enum AutomationJSON: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AutomationJSON])
    case object([String: AutomationJSON])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([AutomationJSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: AutomationJSON].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Conditions

nonisolated struct AutomationPowerCondition: Codable, Hashable, Sendable {
    enum Test: String, Codable, CaseIterable, Sendable {
        case onBattery = "on-battery"
        case onAC = "on-ac"
        case charging
        case notCharging = "not-charging"
        case levelBelow = "level-below"
        case levelAbove = "level-above"
    }
    var test: Test
    /// For `levelBelow` / `levelAbove`, 1–99.
    var percent: Int = 20

    init(test: Test, percent: Int = 20) {
        self.test = test
        self.percent = percent
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        test = try container.decode(Test.self, forKey: .test)
        percent = try container.decodeIfPresent(Int.self, forKey: .percent) ?? 20
    }
}

nonisolated struct AutomationWiFiCondition: Codable, Hashable, Sendable {
    enum Test: String, Codable, CaseIterable, Sendable {
        case connected
        case notConnected = "not-connected"
        /// Needs Location permission to read the network name; without it the condition
        /// is unknown and treated as false.
        case connectedTo = "connected-to"
    }
    var test: Test
    var networks: [String] = []

    init(test: Test, networks: [String] = []) {
        self.test = test
        self.networks = networks
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        test = try container.decode(Test.self, forKey: .test)
        networks = try container.decodeIfPresent([String].self, forKey: .networks) ?? []
    }
}

nonisolated struct AutomationAppCondition: Codable, Hashable, Sendable {
    enum Test: String, Codable, CaseIterable, Sendable {
        case running
        case notRunning = "not-running"
        case frontmost
        case notFrontmost = "not-frontmost"
    }
    var bundleID: String
    /// Shown when the app is not installed any more.
    var name: String?
    var test: Test
}

/// Days of the week plus a time range. A range whose end is before its start crosses
/// midnight and belongs to the day it starts on (Fri 22:00–02:00 holds until Sat 02:00).
/// Start equal to end means the whole day.
nonisolated struct AutomationTimeCondition: Codable, Hashable, Sendable {
    /// `Calendar` weekday numbers: 1 = Sunday … 7 = Saturday.
    var weekdays: [Int]
    /// Minutes after midnight, 0..<1440.
    var start: Int
    var end: Int

    static let workdays = [2, 3, 4, 5, 6]

    init(weekdays: [Int], start: Int, end: Int) {
        self.weekdays = weekdays
        self.start = start
        self.end = end
    }

    /// Missing days mean every day; a missing start or end means midnight.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        weekdays = (try container.decodeIfPresent([Int].self, forKey: .weekdays) ?? Array(1...7)).filter { (1...7).contains($0) }
        start = try container.decodeIfPresent(Int.self, forKey: .start) ?? 0
        end = try container.decodeIfPresent(Int.self, forKey: .end) ?? 0
    }
}

nonisolated struct AutomationDisplayCondition: Codable, Hashable, Sendable {
    enum Test: String, Codable, CaseIterable, Sendable {
        case builtInOnly = "built-in-only"
        case externalConnected = "external-connected"
        case countAtLeast = "count-at-least"
        case countExactly = "count-exactly"
    }
    var test: Test
    var count: Int = 2

    init(test: Test, count: Int = 2) {
        self.test = test
        self.count = count
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        test = try container.decode(Test.self, forKey: .test)
        count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 2
    }
}

/// A shell command run every `interval` seconds; true while its last run exited 0.
/// Never runs until the user allowed it on this Mac (`AutomationScriptApprovals`).
nonisolated struct AutomationScriptCondition: Codable, Hashable, Sendable {
    static let minimumInterval = 5
    static let maximumTimeout = 60
    var command: String
    var interval: Int = 30
    var timeout: Int = 5

    init(command: String, interval: Int = 30, timeout: Int = 5) {
        self.command = command
        self.interval = interval
        self.timeout = timeout
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(String.self, forKey: .command)
        interval = try container.decodeIfPresent(Int.self, forKey: .interval) ?? 30
        timeout = try container.decodeIfPresent(Int.self, forKey: .timeout) ?? 5
    }

    var effectiveInterval: Int { max(Self.minimumInterval, interval) }
    var effectiveTimeout: Int { min(max(1, timeout), Self.maximumTimeout, effectiveInterval) }
}

/// Planned for a later milestone: true for `holdSeconds` after the image of `owner`'s
/// item changed. Extension point only: evaluated from `AutomationEnvironment.itemChanges`,
/// which the feature that observes item images (Capture) will fill through
/// `ServiceKey.automationItemChanges`. No editor UI yet.
nonisolated struct AutomationItemChangedCondition: Codable, Hashable, Sendable {
    var owner: OwnerID
    var holdSeconds: Int = 10

    init(owner: OwnerID, holdSeconds: Int = 10) {
        self.owner = owner
        self.holdSeconds = holdSeconds
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        owner = try container.decode(OwnerID.self, forKey: .owner)
        holdSeconds = try container.decodeIfPresent(Int.self, forKey: .holdSeconds) ?? 10
    }
}

/// A circle the user saved. Coordinates are the user's data: stored in the rules (and so in
/// exports and backups), never logged, never shown in the rule list.
nonisolated struct AutomationPlace: Codable, Hashable, Sendable {
    static let radiusRange: ClosedRange<Double> = 100...5000
    static let defaultRadius: Double = 200

    var name: String
    /// Nil until the user entered or fetched coordinates: the condition is then unknown.
    var latitude: Double?
    var longitude: Double?
    /// Metres, clamped to `radiusRange` when used.
    var radius: Double = AutomationPlace.defaultRadius

    init(name: String = "", latitude: Double? = nil, longitude: Double? = nil, radius: Double = AutomationPlace.defaultRadius) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
        radius = try container.decodeIfPresent(Double.self, forKey: .radius) ?? Self.defaultRadius
    }

    var effectiveRadius: Double { min(max(radius, Self.radiusRange.lowerBound), Self.radiusRange.upperBound) }

    /// Both coordinates present and in range.
    var hasCoordinates: Bool {
        guard let latitude, let longitude else { return false }
        return abs(latitude) <= 90 && abs(longitude) <= 180
    }
}

/// "At a place" holds while the Mac is inside the circle (reacts to arriving); "away from
/// a place" holds while it is outside (reacts to leaving). Unknown location: neither holds.
nonisolated struct AutomationPlaceCondition: Codable, Hashable, Sendable {
    enum Test: String, Codable, CaseIterable, Sendable {
        case at
        case awayFrom = "away-from"
    }
    var test: Test
    var place: AutomationPlace

    init(test: Test, place: AutomationPlace) {
        self.test = test
        self.place = place
    }
}

nonisolated struct AutomationCondition: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case power(AutomationPowerCondition)
        case wifi(AutomationWiFiCondition)
        case app(AutomationAppCondition)
        case time(AutomationTimeCondition)
        case displays(AutomationDisplayCondition)
        case script(AutomationScriptCondition)
        case place(AutomationPlaceCondition)
        case itemChanged(AutomationItemChangedCondition)
        /// A type this build does not know: kept verbatim, evaluates to false.
        case unsupported(type: String, parameters: AutomationJSON)

        var typeName: String {
            switch self {
            case .power: "power"
            case .wifi: "wifi"
            case .app: "app"
            case .time: "time"
            case .displays: "displays"
            case .script: "script"
            case .place: "place"
            case .itemChanged: "item-changed"
            case .unsupported(let type, _): type
            }
        }
    }

    var id: String
    var kind: Kind

    init(id: String = AutomationIDs.make(), _ kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

nonisolated extension AutomationCondition: Codable {
    private enum CodingKeys: String, CodingKey { case id, type, parameters }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? AutomationIDs.make()
        let type = try container.decode(String.self, forKey: .type)
        func parameters<T: Decodable>(_ type: T.Type) -> T? { try? container.decode(T.self, forKey: .parameters) }
        let known: Kind? = switch type {
        case "power": parameters(AutomationPowerCondition.self).map(Kind.power)
        case "wifi": parameters(AutomationWiFiCondition.self).map(Kind.wifi)
        case "app": parameters(AutomationAppCondition.self).map(Kind.app)
        case "time": parameters(AutomationTimeCondition.self).map(Kind.time)
        case "displays": parameters(AutomationDisplayCondition.self).map(Kind.displays)
        case "script": parameters(AutomationScriptCondition.self).map(Kind.script)
        case "place": parameters(AutomationPlaceCondition.self).map(Kind.place)
        case "item-changed": parameters(AutomationItemChangedCondition.self).map(Kind.itemChanged)
        default: nil
        }
        kind = known ?? .unsupported(type: type, parameters: parameters(AutomationJSON.self) ?? .null)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind.typeName, forKey: .type)
        switch kind {
        case .power(let value): try container.encode(value, forKey: .parameters)
        case .wifi(let value): try container.encode(value, forKey: .parameters)
        case .app(let value): try container.encode(value, forKey: .parameters)
        case .time(let value): try container.encode(value, forKey: .parameters)
        case .displays(let value): try container.encode(value, forKey: .parameters)
        case .script(let value): try container.encode(value, forKey: .parameters)
        case .place(let value): try container.encode(value, forKey: .parameters)
        case .itemChanged(let value): try container.encode(value, forKey: .parameters)
        case .unsupported(_, let parameters): try container.encode(parameters, forKey: .parameters)
        }
    }
}

// MARK: - Actions

nonisolated struct AutomationProfileAction: Codable, Hashable, Sendable {
    var profileID: String
    /// When the rule ends, go back to the profile (or layout) in effect before it applied.
    var restorePrevious: Bool = false

    init(profileID: String, restorePrevious: Bool = false) {
        self.profileID = profileID
        self.restorePrevious = restorePrevious
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try container.decode(String.self, forKey: .profileID)
        restorePrevious = try container.decodeIfPresent(Bool.self, forKey: .restorePrevious) ?? false
    }
}

nonisolated struct AutomationCommandCall: Codable, Hashable, Sendable {
    var id: CommandID
    var arguments: [String: String] = [:]

    init(id: CommandID, arguments: [String: String] = [:]) {
        self.id = id
        self.arguments = arguments
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(CommandID.self, forKey: .id)
        arguments = try container.decodeIfPresent([String: String].self, forKey: .arguments) ?? [:]
    }
}

nonisolated struct AutomationActions: Hashable, Sendable {
    /// Forced visible while the rule is active (`setForcedVisible`, source `automations.<rule id>`).
    var showItems: [OwnerID] = []
    /// Applied when the rule becomes active.
    var profile: AutomationProfileAction?
    var commandOnStart: AutomationCommandCall?
    var commandOnEnd: AutomationCommandCall?

    var isEmpty: Bool { showItems.isEmpty && profile == nil && commandOnStart == nil && commandOnEnd == nil }
}

nonisolated extension AutomationActions: Codable {
    private enum CodingKeys: String, CodingKey { case showItems, profile, commandOnStart, commandOnEnd }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawOwners = (try? container.decodeIfPresent([String].self, forKey: .showItems)) ?? []
        showItems = rawOwners.compactMap(OwnerID.init(stringValue:))
        profile = (try? container.decodeIfPresent(AutomationProfileAction.self, forKey: .profile)) ?? nil
        commandOnStart = (try? container.decodeIfPresent(AutomationCommandCall.self, forKey: .commandOnStart)) ?? nil
        commandOnEnd = (try? container.decodeIfPresent(AutomationCommandCall.self, forKey: .commandOnEnd)) ?? nil
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(showItems.map(\.stringValue), forKey: .showItems)
        try container.encodeIfPresent(profile, forKey: .profile)
        try container.encodeIfPresent(commandOnStart, forKey: .commandOnStart)
        try container.encodeIfPresent(commandOnEnd, forKey: .commandOnEnd)
    }
}

// MARK: - Rule

nonisolated enum AutomationMatchMode: String, Codable, CaseIterable, Sendable {
    case all
    case any
}

nonisolated struct AutomationRule: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var isEnabled: Bool
    var match: AutomationMatchMode
    var conditions: [AutomationCondition]
    var actions: AutomationActions

    init(id: String = AutomationIDs.make(), name: String, isEnabled: Bool = true, match: AutomationMatchMode = .all,
         conditions: [AutomationCondition] = [], actions: AutomationActions = AutomationActions()) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.match = match
        self.conditions = conditions
        self.actions = actions
    }

    var scriptConditions: [(id: String, script: AutomationScriptCondition)] {
        conditions.compactMap { condition in
            if case .script(let script) = condition.kind { return (condition.id, script) }
            return nil
        }
    }

    var usesNetworkNames: Bool {
        conditions.contains { condition in
            if case .wifi(let wifi) = condition.kind { return wifi.test == .connectedTo }
            return false
        }
    }

    var usesTime: Bool {
        conditions.contains { if case .time = $0.kind { true } else { false } }
    }

    var placeConditions: [(id: String, condition: AutomationPlaceCondition)] {
        conditions.compactMap { condition in
            if case .place(let place) = condition.kind { return (condition.id, place) }
            return nil
        }
    }

    var usesPlaces: Bool { !placeConditions.isEmpty }
}

nonisolated extension AutomationRule: Codable {
    private enum CodingKeys: String, CodingKey { case id, name, isEnabled, match, conditions, actions }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
        isEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
        match = (try? container.decodeIfPresent(AutomationMatchMode.self, forKey: .match)) ?? .all
        conditions = ((try? container.decodeIfPresent([AutomationLossy<AutomationCondition>].self, forKey: .conditions)) ?? [])
            .compactMap(\.value)
        actions = (try? container.decodeIfPresent(AutomationActions.self, forKey: .actions)) ?? AutomationActions()
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(match, forKey: .match)
        try container.encode(conditions, forKey: .conditions)
        try container.encode(actions, forKey: .actions)
    }
}

/// The stored rule list (`rolltop.automations.rules`). Unreadable rules are skipped, so one
/// bad entry never loses the others.
nonisolated struct AutomationRuleList: Hashable, Sendable, Codable {
    var rules: [AutomationRule]

    init(rules: [AutomationRule] = []) { self.rules = rules }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rules = ((try? container.decodeIfPresent([AutomationLossy<AutomationRule>].self, forKey: .rules)) ?? [])
            .compactMap(\.value)
        // Ids must be unique: later duplicates are dropped.
        var seen: Set<String> = []
        rules = rules.filter { seen.insert($0.id).inserted }
    }
}

nonisolated struct AutomationLossy<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?
    init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
}

nonisolated enum AutomationIDs {
    static func make() -> String { UUID().uuidString.lowercased() }
}

// MARK: - Templates

nonisolated enum AutomationTemplate: String, CaseIterable, Sendable {
    case batteryOnBattery = "battery-on-battery"
    case wifiNotConnected = "wifi-not-connected"
    case appFrontmost = "app-frontmost"

    /// A new rule from the template. `appFrontmost` starts without an app: the editor
    /// asks for one and also shows that app's item.
    func makeRule(name: String) -> AutomationRule {
        switch self {
        case .batteryOnBattery:
            AutomationRule(name: name, conditions: [AutomationCondition(.power(.init(test: .onBattery)))],
                           actions: AutomationActions(showItems: [.system(.battery)]))
        case .wifiNotConnected:
            AutomationRule(name: name, conditions: [AutomationCondition(.wifi(.init(test: .notConnected)))],
                           actions: AutomationActions(showItems: [.system(.wifi)]))
        case .appFrontmost:
            AutomationRule(name: name, conditions: [AutomationCondition(.app(.init(bundleID: "", test: .frontmost)))])
        }
    }
}
