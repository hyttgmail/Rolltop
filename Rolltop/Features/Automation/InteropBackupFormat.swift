import Foundation
import RolltopCore

// The `.rolltopbackup` file: JSON, versioned, readable. Pure types; no file or settings I/O.
//
//     {
//       "format": "com.alphapengwang.rolltop.backup", "version": 1,
//       "createdAt": "2026-11-24T21:00:00Z", "appVersion": "0.1.0 (1)", "reason": "export",
//       "settings": { "rolltop.reveal.hover": { "bool": true }, … },
//       "layout": { … },
//       "sections": { "profiles": { "title": "Profiles", "summary": "2 profiles", "json": { … } }, … }
//     }
//
// Readers ignore fields they do not know, skip setting values whose type tag they do not
// know, and list sections no running feature takes as skipped, so a file from a newer Rolltop
// still imports what this version understands.

/// Any JSON value.
nonisolated indirect enum InteropJSON: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([InteropJSON])
    case object([String: InteropJSON])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([InteropJSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: InteropJSON].self)) }
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

    /// Parses JSON bytes holding an object or an array (not a bare fragment).
    static func container(from data: Data) -> InteropJSON? {
        guard let first = data.first(where: { !$0.isWhitespace }), first == UInt8(ascii: "{") || first == UInt8(ascii: "[") else { return nil }
        guard let value = try? JSONDecoder().decode(InteropJSON.self, from: data) else { return nil }
        // JSONDecoder reads 1 and true alike as Bool first; make sure a re-encode gives
        // the same meaning by comparing with JSONSerialization's reading.
        guard let reencoded = try? JSONEncoder().encode(value),
              let a = try? JSONSerialization.jsonObject(with: data), let b = try? JSONSerialization.jsonObject(with: reencoded),
              NSDictionary(dictionary: ["v": a]).isEqual(to: ["v": b]) else { return nil }
        return value
    }

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

nonisolated private extension UInt8 {
    var isWhitespace: Bool { self == 0x20 || self == 0x0A || self == 0x0D || self == 0x09 }
}

/// A settings value (a property-list object) with its type, so JSON keeps Bool/Int/Double,
/// dates and data apart. JSON data (Codable settings) is embedded readable.
nonisolated indirect enum InteropSettingValue: Codable, Hashable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case date(Date)
    case data(Data)
    /// `Data` holding a JSON object or array.
    case json(InteropJSON)
    case array([InteropSettingValue])
    case dictionary([String: InteropSettingValue])

    struct UnknownTag: Error {}

    private enum Tag: String, CodingKey, CaseIterable { case bool, int, double, string, date, data, json, array, dictionary }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Tag.self)
        guard let tag = container.allKeys.first else { throw UnknownTag() }
        switch tag {
        case .bool: self = .bool(try container.decode(Bool.self, forKey: tag))
        case .int: self = .int(try container.decode(Int.self, forKey: tag))
        case .double: self = .double(try container.decode(Double.self, forKey: tag))
        case .string: self = .string(try container.decode(String.self, forKey: tag))
        case .date: self = .date(try container.decode(Date.self, forKey: tag))
        case .data: self = .data(try container.decode(Data.self, forKey: tag))
        case .json: self = .json(try container.decode(InteropJSON.self, forKey: tag))
        case .array: self = .array(try container.decode([InteropSettingValue].self, forKey: tag))
        case .dictionary: self = .dictionary(try container.decode([String: InteropSettingValue].self, forKey: tag))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Tag.self)
        switch self {
        case .bool(let value): try container.encode(value, forKey: .bool)
        case .int(let value): try container.encode(value, forKey: .int)
        case .double(let value): try container.encode(value, forKey: .double)
        case .string(let value): try container.encode(value, forKey: .string)
        case .date(let value): try container.encode(value, forKey: .date)
        case .data(let value): try container.encode(value, forKey: .data)
        case .json(let value): try container.encode(value, forKey: .json)
        case .array(let value): try container.encode(value, forKey: .array)
        case .dictionary(let value): try container.encode(value, forKey: .dictionary)
        }
    }

    init?(plist: Any) {
        switch plist {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) }
            else if CFNumberIsFloatType(number) { self = .double(number.doubleValue) }
            else { self = .int(number.intValue) }
        case let string as String: self = .string(string)
        case let date as Date: self = .date(date)
        case let data as Data: self = InteropJSON.container(from: data).map(InteropSettingValue.json) ?? .data(data)
        case let array as [Any]:
            let values = array.compactMap(InteropSettingValue.init(plist:))
            guard values.count == array.count else { return nil }
            self = .array(values)
        case let dictionary as [String: Any]:
            var values: [String: InteropSettingValue] = [:]
            for (key, value) in dictionary {
                guard let converted = InteropSettingValue(plist: value) else { return nil }
                values[key] = converted
            }
            self = .dictionary(values)
        default: return nil
        }
    }

    /// The property-list object to store.
    var plist: Any? {
        switch self {
        case .bool(let value): value
        case .int(let value): value
        case .double(let value): value
        case .string(let value): value
        case .date(let value): value
        case .data(let value): value
        case .json(let value): try? value.data()
        case .array(let values):
            values.compactMap(\.plist)
        case .dictionary(let values):
            values.compactMapValues(\.plist)
        }
    }
}

/// One participant's data. JSON data is embedded readable, anything else as base64.
nonisolated struct InteropBackupSection: Codable, Hashable, Sendable {
    var title: String
    var summary: String
    var json: InteropJSON?
    var base64: Data?

    init(title: String, summary: String, data: Data) {
        self.title = title
        self.summary = summary
        if let value = InteropJSON.container(from: data) { json = value } else { base64 = data }
    }

    func payload() throws -> Data {
        if let json { return try json.data() }
        if let base64 { return base64 }
        throw InteropBackupError.unreadable
    }
}

nonisolated struct InteropBackupFile: Codable, Sendable {
    static let formatID = "com.alphapengwang.rolltop.backup"
    static let currentVersion = 1
    static let fileExtension = "rolltopbackup"

    var format = InteropBackupFile.formatID
    var version = InteropBackupFile.currentVersion
    var createdAt: Date
    var appVersion: String
    /// `export`, or why an automatic backup was taken (`before-import`, `before-reset`).
    var reason: String
    var settings: [String: InteropSettingValue]
    var layout: Layout?
    var sections: [String: InteropBackupSection]
    /// Setting keys whose value this version could not read (newer types).
    var skippedSettings: [String] = []

    private enum CodingKeys: String, CodingKey { case format, version, createdAt, appVersion, reason, settings, layout, sections }

    init(createdAt: Date, appVersion: String, reason: String, settings: [String: InteropSettingValue], layout: Layout?,
         sections: [String: InteropBackupSection]) {
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.reason = reason
        self.settings = settings
        self.layout = layout
        self.sections = sections
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(String.self, forKey: .format)
        guard format == Self.formatID else { throw InteropBackupError.notABackup }
        version = try container.decode(Int.self, forKey: .version)
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? .distantPast
        appVersion = (try? container.decode(String.self, forKey: .appVersion)) ?? "?"
        reason = (try? container.decode(String.self, forKey: .reason)) ?? "export"
        let lossy = (try? container.decode([String: InteropLossySetting].self, forKey: .settings)) ?? [:]
        settings = lossy.compactMapValues(\.value)
        skippedSettings = lossy.filter { $0.value.value == nil }.keys.sorted()
        layout = try? container.decodeIfPresent(Layout.self, forKey: .layout)
        let lossySections = (try? container.decode([String: InteropLossySection].self, forKey: .sections)) ?? [:]
        sections = lossySections.compactMapValues(\.value)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(version, forKey: .version)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(appVersion, forKey: .appVersion)
        try container.encode(reason, forKey: .reason)
        try container.encode(settings, forKey: .settings)
        try container.encodeIfPresent(layout, forKey: .layout)
        try container.encode(sections, forKey: .sections)
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Fractional seconds, so date settings survive a round trip.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Self.dateStyle))
        }
        encoder.dataEncodingStrategy = .base64
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = try? Date(string, strategy: Self.dateStyle) { return date }
            if let date = try? Date(string, strategy: .iso8601) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an ISO 8601 date")
        }
        decoder.dataDecodingStrategy = .base64
        return decoder
    }

    static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func read(_ data: Data) throws -> InteropBackupFile {
        do {
            return try decoder().decode(InteropBackupFile.self, from: data)
        } catch let error as InteropBackupError {
            throw error
        } catch {
            throw InteropBackupError.notABackup
        }
    }
}

nonisolated private struct InteropLossySetting: Decodable {
    let value: InteropSettingValue?
    init(from decoder: any Decoder) throws { value = try? InteropSettingValue(from: decoder) }
}

nonisolated private struct InteropLossySection: Decodable {
    let value: InteropBackupSection?
    init(from decoder: any Decoder) throws { value = try? InteropBackupSection(from: decoder) }
}

nonisolated enum InteropBackupError: LocalizedError, Equatable {
    case notABackup
    case unreadable
    case nothingSelected
    case sectionFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .notABackup: String(localized: "The file is not a Rolltop backup.", table: "Automation")
        case .unreadable: String(localized: "Part of the backup is unreadable.", table: "Automation")
        case .nothingSelected: String(localized: "Choose at least one part of the backup to bring in.", table: "Automation")
        case .sectionFailed(let title, let reason): String(localized: "\(title): \(reason)", table: "Automation")
        }
    }
}

/// What can be brought in from a backup. Settings and layout are built in; every other
/// part is a participant's section id.
nonisolated enum InteropBackupPart: Hashable, Sendable, Comparable {
    case settings
    case layout
    case section(String)

    var id: String {
        switch self {
        case .settings: "settings"
        case .layout: "layout"
        case .section(let id): id
        }
    }

    init(id: String) {
        switch id {
        case "settings": self = .settings
        case "layout": self = .layout
        default: self = .section(id)
        }
    }
}

/// What the import sheet shows before anything changes.
nonisolated struct InteropBackupPreview: Sendable, Equatable {
    struct Part: Identifiable, Sendable, Equatable {
        let part: InteropBackupPart
        let title: String
        let summary: String
        /// False when no running feature takes this section (it is skipped).
        let isAvailable: Bool
        var id: String { part.id }
    }

    let createdAt: Date
    let appVersion: String
    let version: Int
    let isFromNewerVersion: Bool
    let parts: [Part]
    let skippedSettings: [String]
}

nonisolated enum InteropBackupMerge {
    /// The settings to write when importing: the file's settings without the reserved keys
    /// (layout, participant-owned keys), plus the current values of those reserved keys, so
    /// `replaceAll` keeps whatever is not being imported.
    static func settingsToWrite(imported: [String: Any], current: [String: Any], reserved: Set<String>) -> [String: Any] {
        var result = imported.filter { !reserved.contains($0.key) && $0.key.hasPrefix("rolltop.") }
        for key in reserved { if let value = current[key] { result[key] = value } }
        return result
    }

    /// The exportable settings section: everything `exportAll()` gives except reserved keys.
    static func settingsSection(from all: [String: Any], reserved: Set<String>) -> [String: InteropSettingValue] {
        var result: [String: InteropSettingValue] = [:]
        for (key, value) in all where !reserved.contains(key) {
            if let converted = InteropSettingValue(plist: value) { result[key] = converted }
        }
        return result
    }

    /// Newest first; everything after the first `keep` is removed.
    static func backupsToPrune(_ files: [(url: URL, date: Date)], keep: Int) -> [URL] {
        files.sorted { $0.date > $1.date }.dropFirst(keep).map(\.url)
    }
}
