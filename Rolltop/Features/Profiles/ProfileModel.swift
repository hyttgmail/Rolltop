import CoreFoundation
import Foundation
import RolltopCore

// Pure model of the Profiles feature: no AppKit, no side effects. Everything here is
// `nonisolated` so tests and background queues can use it.

// MARK: - Settings values

/// One `UserDefaults` value in a JSON form that round-trips every property-list type.
/// Encoded as a single-key object (`{"int": 3}`, `{"data": "<base64>"}`) so nothing is
/// ambiguous (a string and a date, an int and a double).
nonisolated enum ProfileSettingValue: Hashable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case date(Date)
    case data(Data)
    case array([ProfileSettingValue])
    case dictionary([String: ProfileSettingValue])

    /// Converts a property-list object read from `UserDefaults`; nil for anything else.
    init?(plist: Any) {
        switch plist {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        case let string as String:
            self = .string(string)
        case let date as Date:
            self = .date(date)
        case let data as Data:
            self = .data(data)
        case let array as [Any]:
            var values: [ProfileSettingValue] = []
            for element in array {
                guard let value = ProfileSettingValue(plist: element) else { return nil }
                values.append(value)
            }
            self = .array(values)
        case let dictionary as [String: Any]:
            var values: [String: ProfileSettingValue] = [:]
            for (key, element) in dictionary {
                guard let value = ProfileSettingValue(plist: element) else { return nil }
                values[key] = value
            }
            self = .dictionary(values)
        default:
            return nil
        }
    }

    /// The property-list object to hand to `UserDefaults`.
    var plistObject: Any {
        switch self {
        case .bool(let value): value
        case .int(let value): value
        case .double(let value): value
        case .string(let value): value
        case .date(let value): value
        case .data(let value): value
        case .array(let values): values.map(\.plistObject)
        case .dictionary(let values): values.mapValues(\.plistObject)
        }
    }
}

nonisolated extension ProfileSettingValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case bool, int, double, string, date, data, array, dictionary
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(Bool.self, forKey: .bool) { self = .bool(value) }
        else if let value = try container.decodeIfPresent(Int.self, forKey: .int) { self = .int(value) }
        else if let value = try container.decodeIfPresent(Double.self, forKey: .double) { self = .double(value) }
        else if let value = try container.decodeIfPresent(String.self, forKey: .string) { self = .string(value) }
        else if let value = try container.decodeIfPresent(Double.self, forKey: .date) {
            self = .date(Date(timeIntervalSinceReferenceDate: value))
        }
        else if let value = try container.decodeIfPresent(String.self, forKey: .data) {
            guard let data = Data(base64Encoded: value) else {
                throw DecodingError.dataCorruptedError(forKey: .data, in: container, debugDescription: "Invalid base64")
            }
            self = .data(data)
        }
        else if let value = try container.decodeIfPresent([ProfileSettingValue].self, forKey: .array) { self = .array(value) }
        else if let value = try container.decodeIfPresent([String: ProfileSettingValue].self, forKey: .dictionary) {
            self = .dictionary(value)
        }
        else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown setting value"))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bool(let value): try container.encode(value, forKey: .bool)
        case .int(let value): try container.encode(value, forKey: .int)
        case .double(let value): try container.encode(value, forKey: .double)
        case .string(let value): try container.encode(value, forKey: .string)
        case .date(let value): try container.encode(value.timeIntervalSinceReferenceDate, forKey: .date)
        case .data(let value): try container.encode(value.base64EncodedString(), forKey: .data)
        case .array(let values): try container.encode(values, forKey: .array)
        case .dictionary(let values): try container.encode(values, forKey: .dictionary)
        }
    }
}

/// A group of other features' settings a profile can carry, chosen by key prefix so this
/// feature needs no compile-time knowledge of those features.
nonisolated struct ProfileSettingsGroup: Identifiable, Hashable, Sendable {
    let id: String
    /// Every key starting with this is part of the group (`rolltop.appearance.`).
    let prefix: String

    static let appearance = ProfileSettingsGroup(id: "appearance", prefix: "rolltop.appearance.")
    static let secondaryBar = ProfileSettingsGroup(id: "secondary-bar", prefix: "rolltop.secondary-bar.")
    static let all: [ProfileSettingsGroup] = [.appearance, .secondaryBar]
}

/// Pure helpers for settings snapshots.
nonisolated enum ProfileSettingsSnapshot {
    /// The values under `prefixes` in `all` (an `exportAll()` dictionary). Values that are
    /// not property-list types are skipped.
    static func capture(from all: [String: Any], prefixes: [String]) -> [String: ProfileSettingValue] {
        var result: [String: ProfileSettingValue] = [:]
        for (key, raw) in all where prefixes.contains(where: key.hasPrefix) {
            if let value = ProfileSettingValue(plist: raw) { result[key] = value }
        }
        return result
    }

    /// What to remove and what to write so that, under `prefixes`, the store holds exactly
    /// the snapshot's values. Keys outside `prefixes` are never touched.
    static func changes(currentKeys: some Sequence<String>, snapshot: [String: ProfileSettingValue],
                        prefixes: [String]) -> (remove: [String], set: [String: ProfileSettingValue]) {
        let inScope = { (key: String) in prefixes.contains(where: key.hasPrefix) }
        let wanted = snapshot.filter { inScope($0.key) }
        let remove = currentKeys.filter { inScope($0) && wanted[$0] == nil }.sorted()
        return (remove, wanted)
    }

    /// Whether the current values under `prefixes` equal the snapshot. Compared as
    /// Foundation objects, so `1` and `1.0` (or `true` and `1`) count as equal.
    static func matches(current all: [String: Any], snapshot: [String: ProfileSettingValue], prefixes: [String]) -> Bool {
        guard !prefixes.isEmpty else { return true }
        let current = all.filter { key, _ in prefixes.contains(where: key.hasPrefix) }
        let stored = snapshot.filter { key, _ in prefixes.contains(where: key.hasPrefix) }.mapValues(\.plistObject)
        return NSDictionary(dictionary: current).isEqual(to: stored)
    }
}

// MARK: - Displays

/// One display as profiles see it: a stable id (ColorSync display UUID, else
/// vendor-model-serial) and the name macOS shows.
nonisolated struct ProfileDisplay: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var isBuiltIn: Bool

    init(id: String, name: String, isBuiltIn: Bool) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
    }
}

/// The displays connected right now.
nonisolated struct ProfileDisplayConfiguration: Hashable, Sendable {
    var displays: [ProfileDisplay]

    var ids: Set<String> { Set(displays.map(\.id)) }
    var hasExternal: Bool { displays.contains { !$0.isBuiltIn } }
    var isBuiltInOnly: Bool { !displays.isEmpty && displays.allSatisfy(\.isBuiltIn) }
}

/// When a profile applies itself because of the connected displays.
nonisolated enum ProfileDisplayRule: Hashable, Sendable {
    /// Only the built-in display is connected (no external display).
    case builtInOnly
    /// At least one external display is connected.
    case externalConnected
    /// Exactly this set of displays is connected.
    case displays([ProfileDisplay])

    func matches(_ configuration: ProfileDisplayConfiguration) -> Bool {
        switch self {
        case .builtInOnly: configuration.isBuiltInOnly
        case .externalConnected: configuration.hasExternal
        case .displays(let wanted): !wanted.isEmpty && Set(wanted.map(\.id)) == configuration.ids
        }
    }

    /// Higher wins when several profiles match.
    var specificity: Int {
        switch self {
        case .displays: 2
        case .builtInOnly, .externalConnected: 1
        }
    }

    /// The profile whose rule matches best: the most specific rule, then list order.
    /// Nil when nothing matches (things are left as they are).
    static func bestMatch(in profiles: [RolltopProfile], for configuration: ProfileDisplayConfiguration) -> RolltopProfile? {
        var best: (profile: RolltopProfile, specificity: Int)?
        for profile in profiles {
            guard let rule = profile.displayRule, rule.matches(configuration) else { continue }
            if best == nil || rule.specificity > best!.specificity { best = (profile, rule.specificity) }
        }
        return best?.profile
    }
}

nonisolated extension ProfileDisplayRule: Codable {
    private enum CodingKeys: String, CodingKey { case kind, displays }
    private enum Kind: String, Codable {
        case builtInOnly = "built-in-only"
        case externalConnected = "external-connected"
        case displays
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .builtInOnly: self = .builtInOnly
        case .externalConnected: self = .externalConnected
        case .displays: self = .displays(try container.decodeIfPresent([ProfileDisplay].self, forKey: .displays) ?? [])
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtInOnly: try container.encode(Kind.builtInOnly, forKey: .kind)
        case .externalConnected: try container.encode(Kind.externalConnected, forKey: .kind)
        case .displays(let displays):
            try container.encode(Kind.displays, forKey: .kind)
            try container.encode(displays, forKey: .displays)
        }
    }
}

// MARK: - Profile

/// A named menu bar setup: the full section layout plus, optionally, other features'
/// settings chosen by key prefix.
nonisolated struct RolltopProfile: Hashable, Sendable, Identifiable {
    static let defaultSymbol = "square.stack.3d.up"

    /// Stable, URL-safe (`work`, `home-2`). Also the file name.
    var id: String
    var name: String
    /// SF Symbol name.
    var symbol: String
    var layout: Layout
    /// Key prefixes of other features' settings this profile carries.
    var settingsPrefixes: [String]
    /// Captured values under `settingsPrefixes`.
    var settings: [String: ProfileSettingValue]
    /// At most one profile has this on (enforced by the controller).
    var applyAtLaunch: Bool
    var displayRule: ProfileDisplayRule?
    var createdAt: Date
    var updatedAt: Date

    init(id: String, name: String, symbol: String = RolltopProfile.defaultSymbol, layout: Layout,
         settingsPrefixes: [String] = [], settings: [String: ProfileSettingValue] = [:],
         applyAtLaunch: Bool = false, displayRule: ProfileDisplayRule? = nil,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.layout = layout
        self.settingsPrefixes = settingsPrefixes
        self.settings = settings
        self.applyAtLaunch = applyAtLaunch
        self.displayRule = displayRule
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func includes(_ group: ProfileSettingsGroup) -> Bool { settingsPrefixes.contains(group.prefix) }
}

nonisolated extension RolltopProfile: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, symbol, layout, settingsPrefixes, settings, applyAtLaunch, displayRule, createdAt, updatedAt
    }

    /// Tolerant: unknown fields are ignored, missing ones take defaults, a broken
    /// display rule or setting value is dropped instead of failing the whole profile.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? ""
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
        symbol = (try? container.decodeIfPresent(String.self, forKey: .symbol)) ?? Self.defaultSymbol
        layout = (try? container.decodeIfPresent(Layout.self, forKey: .layout)) ?? .empty
        settingsPrefixes = ((try? container.decodeIfPresent([String].self, forKey: .settingsPrefixes)) ?? [])
            .filter { $0.hasPrefix(SettingsKey<Bool>.prefix) && $0.count > SettingsKey<Bool>.prefix.count }
        let lossy = (try? container.decodeIfPresent([String: ProfileLossyValue].self, forKey: .settings)) ?? [:]
        settings = lossy.compactMapValues(\.value)
        applyAtLaunch = (try? container.decodeIfPresent(Bool.self, forKey: .applyAtLaunch)) ?? false
        displayRule = (try? container.decodeIfPresent(ProfileDisplayRule.self, forKey: .displayRule)) ?? nil
        createdAt = (try? container.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? container.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? createdAt
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(symbol, forKey: .symbol)
        try container.encode(layout, forKey: .layout)
        try container.encode(settingsPrefixes, forKey: .settingsPrefixes)
        try container.encode(settings, forKey: .settings)
        try container.encode(applyAtLaunch, forKey: .applyAtLaunch)
        try container.encodeIfPresent(displayRule, forKey: .displayRule)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

/// Decodes a setting value or nothing, so one unreadable value does not drop the rest.
nonisolated private struct ProfileLossyValue: Decodable {
    let value: ProfileSettingValue?
    init(from decoder: any Decoder) throws { value = try? ProfileSettingValue(from: decoder) }
}

// MARK: - Files

/// `index.json` in the profiles directory: order and the active profile.
nonisolated struct ProfileIndexFile: Codable, Equatable, Sendable {
    var version = 1
    var order: [String] = []
    var activeProfileID: String?

    init(order: [String] = [], activeProfileID: String? = nil) {
        self.order = order
        self.activeProfileID = activeProfileID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        order = (try? container.decodeIfPresent([String].self, forKey: .order)) ?? []
        activeProfileID = (try? container.decodeIfPresent(String.self, forKey: .activeProfileID)) ?? nil
    }
}

/// What "Export…" writes: one profile in a small envelope.
nonisolated struct ProfileExportFile: Codable, Sendable {
    static let formatID = "com.alphapengwang.rolltop.profile"
    var format = ProfileExportFile.formatID
    var version = 1
    var profile: RolltopProfile

    init(profile: RolltopProfile) { self.profile = profile }
}

nonisolated enum ProfileFileError: LocalizedError, Equatable {
    case notAProfile
    case unknownProfile(String)

    var errorDescription: String? {
        switch self {
        case .notAProfile: String(localized: "The file is not a Rolltop profile.", table: "Profiles")
        case .unknownProfile(let id): String(localized: "There is no profile “\(id)”.", table: "Profiles")
        }
    }
}

// MARK: - Naming and ordering

nonisolated enum ProfileNaming {
    /// Characters allowed in ids (and file names).
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id != "index"
            && id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
            && !id.hasPrefix("-") && !id.hasSuffix("-")
    }

    /// A URL-safe id derived from `name`, unique among `existing` (`work`, `work-2`).
    static func makeID(for name: String, existing: Set<String>) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var slug = ""
        var lastWasDash = false
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !slug.isEmpty {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.count > 40 {
            slug = String(slug.prefix(40))
            while slug.hasSuffix("-") { slug.removeLast() }
        }
        if slug.isEmpty || slug == "index" { slug = "profile" }
        guard existing.contains(slug) else { return slug }
        var counter = 2
        while existing.contains("\(slug)-\(counter)") { counter += 1 }
        return "\(slug)-\(counter)"
    }

    /// `base`, or `base 2`, `base 3`… when taken (case-insensitive).
    static func uniqueName(_ base: String, existing: [String]) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(trimmed.lowercased()) else { return trimmed }
        var counter = 2
        while taken.contains("\(trimmed) \(counter)".lowercased()) { counter += 1 }
        return "\(trimmed) \(counter)"
    }

    /// The id `step` places after `activeID` in `order`, wrapping around. Without an
    /// active profile, `next` starts at the first and `previous` at the last.
    static func neighbor(of activeID: String?, in order: [String], step: Int) -> String? {
        guard !order.isEmpty else { return nil }
        guard let activeID, let index = order.firstIndex(of: activeID) else {
            return step >= 0 ? order.first : order.last
        }
        let count = order.count
        return order[((index + step) % count + count) % count]
    }
}
