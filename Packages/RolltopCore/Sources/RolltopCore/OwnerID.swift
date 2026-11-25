import Foundation

/// The unit of visibility on macOS 27: an app (all of its items together) or one
/// system module. See docs/PLATFORM.md §3.
public enum OwnerID: Hashable, Sendable, Comparable, CustomStringConvertible {
    case app(String)
    case system(SystemModule)

    /// Prefix of the string form of system owners.
    public static let systemPrefix = "system:"

    /// Stable string form used in URLs and storage: `com.foo.bar` or `system:wifi`.
    public var stringValue: String {
        switch self {
        case .app(let bundleID): bundleID
        case .system(let module): Self.systemPrefix + module.name
        }
    }

    /// Parses the string form. Rejects empty strings, whitespace and unknown modules.
    public init?(stringValue: String) {
        let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == stringValue else { return nil }
        if trimmed.hasPrefix(Self.systemPrefix) {
            guard let module = SystemModule(name: String(trimmed.dropFirst(Self.systemPrefix.count))) else { return nil }
            self = .system(module)
            return
        }
        guard !trimmed.contains(where: { $0.isWhitespace || $0 == "/" || $0 == ":" }) else { return nil }
        self = .app(trimmed)
    }

    public var bundleID: String? {
        if case .app(let id) = self { return id }
        return nil
    }

    public var systemModule: SystemModule? {
        if case .system(let module) = self { return module }
        return nil
    }

    public var description: String { stringValue }

    public static func < (lhs: OwnerID, rhs: OwnerID) -> Bool { lhs.stringValue < rhs.stringValue }
}

extension OwnerID: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let owner = OwnerID(stringValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid owner id \(raw)")
        }
        self = owner
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }
}
