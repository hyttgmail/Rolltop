import Foundation
import RolltopCore

// Rolltop's own menu bar items: spacers, groups and widgets. Every model type is Codable with
// stable keys and decodes leniently (missing keys take defaults, unknown keys are ignored,
// unknown enum values fall back, list elements this version cannot read are kept verbatim
// and written back), because profiles and backups carry these models between versions.

// MARK: - Glyph

/// What a spacer or a group icon shows.
nonisolated enum CustomItemGlyphKind: String, Codable, Sendable, CaseIterable {
    case none
    case text
    case emoji
    case symbol
}

nonisolated struct CustomItemGlyph: Codable, Hashable, Sendable {
    var kind: CustomItemGlyphKind
    var value: String

    init(kind: CustomItemGlyphKind, value: String) {
        self.kind = kind
        self.value = value
    }

    static let none = CustomItemGlyph(kind: .none, value: "")
    static func symbol(_ name: String) -> Self { .init(kind: .symbol, value: name) }
    static func text(_ text: String) -> Self { .init(kind: .text, value: text) }
    static func emoji(_ emoji: String) -> Self { .init(kind: .emoji, value: emoji) }

    /// Short texts only: the bar is not a place for sentences.
    static let maximumTextLength = 12

    /// Nothing to draw (`.none`, or an empty value).
    var isBlank: Bool { kind == .none || value.trimmingCharacters(in: .whitespaces).isEmpty }

    private enum CodingKeys: String, CodingKey { case kind, value }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = container.customItemsValue(CustomItemGlyphKind.self, .kind) ?? .none
        value = container.customItemsValue(String.self, .value) ?? ""
    }
}

// MARK: - Spacer

nonisolated struct CustomItemSpacer: Codable, Hashable, Sendable, Identifiable {
    static let widthRange: ClosedRange<Double> = 4...64
    static let defaultWidth: Double = 16

    var id: String
    /// Points, clamped to `widthRange` when read.
    var width: Double
    var glyph: CustomItemGlyph
    var isEnabled: Bool

    init(id: String, width: Double = defaultWidth, glyph: CustomItemGlyph = .none, isEnabled: Bool = true) {
        self.id = id
        self.width = width
        self.glyph = glyph
        self.isEnabled = isEnabled
    }

    var clampedWidth: Double { min(max(width.isFinite ? width : Self.defaultWidth, Self.widthRange.lowerBound), Self.widthRange.upperBound) }

    private enum CodingKeys: String, CodingKey { case id, width, glyph, isEnabled = "enabled" }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        width = container.customItemsValue(Double.self, .width) ?? Self.defaultWidth
        glyph = container.customItemsValue(CustomItemGlyph.self, .glyph) ?? .none
        isEnabled = container.customItemsValue(Bool.self, .isEnabled) ?? true
    }
}

// MARK: - Group

nonisolated struct CustomItemGroup: Codable, Hashable, Sendable, Identifiable {
    static let defaultIcon = CustomItemGlyph.symbol("square.grid.2x2")

    var id: String
    var name: String
    var icon: CustomItemGlyph
    /// `OwnerID.stringValue`s, in the order the panel shows them. Kept as strings so an
    /// owner this version cannot parse survives a round trip.
    var members: [String]
    var opensOnHover: Bool
    var isEnabled: Bool

    init(id: String, name: String, icon: CustomItemGlyph = defaultIcon, members: [String] = [],
         opensOnHover: Bool = false, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.icon = icon
        self.members = members
        self.opensOnHover = opensOnHover
        self.isEnabled = isEnabled
    }

    var memberOwners: [OwnerID] { members.compactMap(OwnerID.init(stringValue:)) }

    private enum CodingKeys: String, CodingKey { case id, name, icon, members, opensOnHover = "openOnHover", isEnabled = "enabled" }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = container.customItemsValue(String.self, .name) ?? ""
        icon = container.customItemsValue(CustomItemGlyph.self, .icon) ?? Self.defaultIcon
        members = container.customItemsValue([String].self, .members) ?? []
        opensOnHover = container.customItemsValue(Bool.self, .opensOnHover) ?? false
        isEnabled = container.customItemsValue(Bool.self, .isEnabled) ?? true
    }
}

// MARK: - Widget

nonisolated enum CustomItemWidgetSource: String, Codable, Sendable, CaseIterable {
    case cpu
    case memory
    case network
    case battery
    case disk
    case clock
    case label
    case script
    case gpu
    /// What plays in Music or Spotify (`.nowPlaying`).
    case music
    /// The next calendar event (`.upNext`).
    case calendar
    /// Whether a Focus is on (`.focusState`).
    case focus
    /// Current weather (`.weather`).
    case weather

    /// Sampling period when the widget does not set one. Clocks tick on the second or the
    /// minute (see `CustomItemsClock`), labels never.
    var defaultInterval: Double {
        switch self {
        case .cpu, .network, .gpu, .music: 2
        case .memory, .focus: 5
        case .battery, .disk: 30
        case .clock: 60
        case .label: 0
        case .script, .calendar: 30
        case .weather: 60
        }
    }

    var defaultSymbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .network: "network"
        case .battery: "battery.100percent"
        case .disk: "internaldrive"
        case .clock: "clock"
        case .label: "star"
        case .script: "terminal"
        case .gpu: "square.3.layers.3d"
        case .music: "music.note"
        case .calendar: "calendar"
        case .focus: "moon"
        case .weather: "cloud.sun"
        }
    }

    /// Sources read from another feature's service on the main thread.
    var isAmbient: Bool { [.music, .calendar, .focus, .weather].contains(self) }
    /// Sources whose widget leaves the bar while there is nothing to show.
    var hidesWhenEmpty: Bool { [.music, .calendar, .weather].contains(self) }

    /// Sources with a history sparkline option.
    var supportsHistory: Bool { self == .cpu || self == .network }
    /// Sources one shared sampler serves (scripts run per widget, labels never sample).
    var isShared: Bool { self != .script && self != .label }
}

nonisolated enum CustomItemWidgetStyle: String, Codable, Sendable, CaseIterable {
    case symbolAndText = "symbol-text"
    case textOnly = "text"
    case symbolOnly = "symbol"
}

nonisolated enum CustomItemMemoryFigure: String, Codable, Sendable, CaseIterable {
    case used
    case pressure
}

nonisolated enum CustomItemNetworkDirection: String, Codable, Sendable, CaseIterable {
    case both
    case down
    case up
}

nonisolated enum CustomItemBatteryFigure: String, Codable, Sendable, CaseIterable {
    case percent
    case timeRemaining = "time"
}

nonisolated enum CustomItemWidgetActionKind: String, Codable, Sendable, CaseIterable {
    case none
    /// Open an app, a file or a URL (`target`).
    case open
    /// Run a Rolltop command (`command`, `arguments`).
    case command
    /// Show the details menu with "Edit…".
    case menu
}

nonisolated struct CustomItemWidgetAction: Codable, Hashable, Sendable {
    var kind: CustomItemWidgetActionKind
    /// A file path (app or document) or a URL string.
    var target: String
    var command: String
    var arguments: [String: String]

    init(kind: CustomItemWidgetActionKind, target: String = "", command: String = "", arguments: [String: String] = [:]) {
        self.kind = kind
        self.target = target
        self.command = command
        self.arguments = arguments
    }

    static let menu = CustomItemWidgetAction(kind: .menu)
    static let none = CustomItemWidgetAction(kind: .none)

    private enum CodingKeys: String, CodingKey { case kind, target, command, arguments }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = container.customItemsValue(CustomItemWidgetActionKind.self, .kind) ?? .menu
        target = container.customItemsValue(String.self, .target) ?? ""
        command = container.customItemsValue(String.self, .command) ?? ""
        arguments = container.customItemsValue([String: String].self, .arguments) ?? [:]
    }
}

nonisolated struct CustomItemWidget: Codable, Hashable, Sendable, Identifiable {
    static let fixedWidthRange: ClosedRange<Double> = 16...240
    static let minimumScriptInterval: Double = 5
    static let scriptTimeoutRange: ClosedRange<Double> = 1...30
    static let defaultClockFormat = "HH:mm"

    var id: String
    var source: CustomItemWidgetSource
    var isEnabled: Bool
    var style: CustomItemWidgetStyle
    var symbol: String
    /// nil: automatic width (sized for the widest value the format can produce).
    var fixedWidth: Double?
    var showsHistory: Bool
    /// Seconds; nil = the source's default. Shared sources sample at the shortest interval
    /// any of their widgets asks for.
    var interval: Double?
    var memoryFigure: CustomItemMemoryFigure
    var networkDirection: CustomItemNetworkDirection
    var batteryFigure: CustomItemBatteryFigure
    var clockFormat: String
    /// A `TimeZone` identifier; nil = the system time zone.
    var timeZone: String?
    /// The text of a label widget, or a short prefix shown before other values.
    var label: String
    var scriptCommand: String
    var scriptTimeout: Double
    var action: CustomItemWidgetAction

    init(id: String, source: CustomItemWidgetSource, isEnabled: Bool = true, style: CustomItemWidgetStyle? = nil,
         symbol: String? = nil, fixedWidth: Double? = nil, showsHistory: Bool = false, interval: Double? = nil,
         memoryFigure: CustomItemMemoryFigure = .used, networkDirection: CustomItemNetworkDirection = .both,
         batteryFigure: CustomItemBatteryFigure = .percent, clockFormat: String = defaultClockFormat,
         timeZone: String? = nil, label: String = "", scriptCommand: String = "", scriptTimeout: Double = 3,
         action: CustomItemWidgetAction = .menu) {
        self.id = id
        self.source = source
        self.isEnabled = isEnabled
        self.style = style ?? Self.defaultStyle(for: source)
        self.symbol = symbol ?? source.defaultSymbol
        self.fixedWidth = fixedWidth
        self.showsHistory = showsHistory
        self.interval = interval
        self.memoryFigure = memoryFigure
        self.networkDirection = networkDirection
        self.batteryFigure = batteryFigure
        self.clockFormat = clockFormat
        self.timeZone = timeZone
        self.label = label
        self.scriptCommand = scriptCommand
        self.scriptTimeout = scriptTimeout
        self.action = action
    }

    static func defaultStyle(for source: CustomItemWidgetSource) -> CustomItemWidgetStyle {
        switch source {
        case .clock, .label, .script: .textOnly
        default: .symbolAndText
        }
    }

    /// The sampling period actually used, seconds (0 for labels).
    var effectiveInterval: Double {
        switch source {
        case .label: return 0
        case .clock: return CustomItemsClock.showsSeconds(format: clockFormat) ? 1 : 60
        case .script: return max(interval ?? source.defaultInterval, Self.minimumScriptInterval)
        default:
            guard let interval, interval.isFinite else { return source.defaultInterval }
            return min(max(interval, 1), 3600)
        }
    }

    var effectiveScriptTimeout: Double {
        let timeout = min(max(scriptTimeout, Self.scriptTimeoutRange.lowerBound), Self.scriptTimeoutRange.upperBound)
        return min(timeout, effectiveInterval - 1)
    }

    var clampedFixedWidth: Double? {
        fixedWidth.map { min(max($0, Self.fixedWidthRange.lowerBound), Self.fixedWidthRange.upperBound) }
    }

    var showsSymbol: Bool { style != .textOnly && !symbol.isEmpty }
    var showsText: Bool { style != .symbolOnly }
    var drawsHistory: Bool { showsHistory && source.supportsHistory }

    private enum CodingKeys: String, CodingKey {
        case id, source, isEnabled = "enabled", style, symbol, fixedWidth, showsHistory = "history", interval
        case memoryFigure = "memory", networkDirection = "network", batteryFigure = "battery"
        case clockFormat, timeZone, label, scriptCommand = "script", scriptTimeout, action
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        // An unknown source cannot be shown: the model keeps the element verbatim instead.
        source = try container.decode(CustomItemWidgetSource.self, forKey: .source)
        isEnabled = container.customItemsValue(Bool.self, .isEnabled) ?? true
        style = container.customItemsValue(CustomItemWidgetStyle.self, .style) ?? Self.defaultStyle(for: source)
        symbol = container.customItemsValue(String.self, .symbol) ?? source.defaultSymbol
        fixedWidth = container.customItemsValue(Double.self, .fixedWidth)
        showsHistory = container.customItemsValue(Bool.self, .showsHistory) ?? false
        interval = container.customItemsValue(Double.self, .interval)
        memoryFigure = container.customItemsValue(CustomItemMemoryFigure.self, .memoryFigure) ?? .used
        networkDirection = container.customItemsValue(CustomItemNetworkDirection.self, .networkDirection) ?? .both
        batteryFigure = container.customItemsValue(CustomItemBatteryFigure.self, .batteryFigure) ?? .percent
        clockFormat = container.customItemsValue(String.self, .clockFormat) ?? Self.defaultClockFormat
        timeZone = container.customItemsValue(String.self, .timeZone)
        label = container.customItemsValue(String.self, .label) ?? ""
        scriptCommand = container.customItemsValue(String.self, .scriptCommand) ?? ""
        scriptTimeout = container.customItemsValue(Double.self, .scriptTimeout) ?? 3
        action = container.customItemsValue(CustomItemWidgetAction.self, .action) ?? .menu
    }
}

// MARK: - Whole model

nonisolated enum CustomItemKind: String, Codable, Sendable, CaseIterable {
    case spacer
    case group
    case widget

    var listKey: String {
        switch self {
        case .spacer: "spacers"
        case .group: "groups"
        case .widget: "widgets"
        }
    }
}

nonisolated struct CustomItemsModel: Codable, Equatable, Sendable {
    /// Bump when the stored shape changes incompatibly; readers of an older version still
    /// decode what they understand.
    static let currentVersion = 1

    var spacers: [CustomItemSpacer] = []
    var groups: [CustomItemGroup] = []
    var widgets: [CustomItemWidget] = []
    /// List elements this version could not read (a newer widget source, say), per list
    /// key. Written back unchanged after the readable ones.
    var unreadable: [String: [CustomItemsJSONValue]] = [:]

    init(spacers: [CustomItemSpacer] = [], groups: [CustomItemGroup] = [], widgets: [CustomItemWidget] = []) {
        self.spacers = spacers
        self.groups = groups
        self.widgets = widgets
    }

    static let empty = CustomItemsModel()

    var isEmpty: Bool { spacers.isEmpty && groups.isEmpty && widgets.isEmpty }
    var unreadableCount: Int { unreadable.values.reduce(0) { $0 + $1.count } }

    var allIDs: Set<String> { Set(spacers.map(\.id) + groups.map(\.id) + widgets.map(\.id)) }

    func kind(of id: String) -> CustomItemKind? {
        if spacers.contains(where: { $0.id == id }) { return .spacer }
        if groups.contains(where: { $0.id == id }) { return .group }
        if widgets.contains(where: { $0.id == id }) { return .widget }
        return nil
    }

    func spacer(_ id: String) -> CustomItemSpacer? { spacers.first { $0.id == id } }
    func group(_ id: String) -> CustomItemGroup? { groups.first { $0.id == id } }
    func widget(_ id: String) -> CustomItemWidget? { widgets.first { $0.id == id } }

    /// Whether the item is switched on in the model (scripts also need approval, see
    /// `CustomItemsStore.isActive`).
    func isEnabled(_ id: String) -> Bool? {
        spacer(id)?.isEnabled ?? group(id)?.isEnabled ?? widget(id)?.isEnabled
    }

    private enum CodingKeys: String, CodingKey { case version, spacers, groups, widgets }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var unreadable: [String: [CustomItemsJSONValue]] = [:]
        func list<Element: Decodable>(_ key: CodingKeys, _ type: Element.Type) -> [Element] {
            guard var items = try? container.nestedUnkeyedContainer(forKey: key) else { return [] }
            var result: [Element] = []
            while !items.isAtEnd {
                // A failed decode does not advance the container: read the same element raw.
                if let element = try? items.decode(Element.self) {
                    result.append(element)
                } else if let raw = try? items.decode(CustomItemsJSONValue.self) {
                    unreadable[key.stringValue, default: []].append(raw)
                } else {
                    break
                }
            }
            return result
        }
        spacers = list(.spacers, CustomItemSpacer.self)
        groups = list(.groups, CustomItemGroup.self)
        widgets = list(.widgets, CustomItemWidget.self)
        self.unreadable = unreadable
        // Duplicate ids would share one status item: keep the first.
        var seen: Set<String> = []
        spacers.removeAll { !seen.insert($0.id).inserted }
        groups.removeAll { !seen.insert($0.id).inserted }
        widgets.removeAll { !seen.insert($0.id).inserted }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        var spacerList = container.nestedUnkeyedContainer(forKey: .spacers)
        for spacer in spacers { try spacerList.encode(spacer) }
        for raw in unreadable[CodingKeys.spacers.stringValue] ?? [] { try spacerList.encode(raw) }
        var groupList = container.nestedUnkeyedContainer(forKey: .groups)
        for group in groups { try groupList.encode(group) }
        for raw in unreadable[CodingKeys.groups.stringValue] ?? [] { try groupList.encode(raw) }
        var widgetList = container.nestedUnkeyedContainer(forKey: .widgets)
        for widget in widgets { try widgetList.encode(widget) }
        for raw in unreadable[CodingKeys.widgets.stringValue] ?? [] { try widgetList.encode(raw) }
    }
}

// MARK: - Ids

nonisolated enum CustomItemsIDs {
    /// Prefix of every custom item's `autosaveName`. macOS keeps a layout row per autosave
    /// name for good (docs/PLATFORM.md §5), so ids are short, stable and reused.
    static let autosavePrefix = "rolltop.custom-items."

    static func autosaveName(for id: String) -> String { autosavePrefix + id }

    /// `<kind>-<n>` with the smallest unused n ≥ 1: deleting and adding again reuses the
    /// id and its autosave name instead of growing macOS's layout table. (Whether macOS
    /// then puts the item back where the deleted one was is not guaranteed: measured, the
    /// order of recreated items can differ.)
    static func next(for kind: CustomItemKind, existing: Set<String>) -> String {
        var n = 1
        while existing.contains("\(kind.rawValue)-\(n)") { n += 1 }
        return "\(kind.rawValue)-\(n)"
    }

    /// Lowercase letters, digits and dashes, 1–40 characters.
    static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 40 && id.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" }
    }
}

// MARK: - JSON passthrough

/// Any JSON value, to keep list elements this version cannot read.
nonisolated enum CustomItemsJSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CustomItemsJSONValue])
    case object([String: CustomItemsJSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([CustomItemsJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: CustomItemsJSONValue].self)) }
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

    /// The `id` of an unreadable element, when it has one (to keep ids unique).
    var id: String? {
        if case .object(let fields) = self, case .string(let id)? = fields["id"] { return id }
        return nil
    }
}

extension KeyedDecodingContainer {
    /// The value for `key`, or nil when it is missing, null or of another shape (an
    /// unknown enum case, say) — never an error.
    nonisolated func customItemsValue<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}
