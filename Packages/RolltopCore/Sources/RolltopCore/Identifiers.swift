import Foundation

/// A typed `UserDefaults` key. Every name starts with `rolltop.`; feature keys use
/// `rolltop.<feature>.<name>`.
public struct SettingsKey<Value: Codable & Sendable>: Sendable {
    public let name: String
    public let defaultValue: Value

    public init(_ name: String, default defaultValue: Value) {
        precondition(name.hasPrefix(Self.prefix), "Settings keys must start with \(Self.prefix)")
        self.name = name
        self.defaultValue = defaultValue
    }

    public static var prefix: String { "rolltop." }
}

/// Stable id of a command. Hotkeys, the palette, URLs and Shortcuts refer to commands by id.
/// Format: `<area>.<verb>` in lowercase with dashes, e.g. `visibility.toggle-hidden`.
public struct CommandID: RawRepresentable, Hashable, Sendable, Codable, Comparable,
    ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }

    /// Lowercase letters, digits, dashes and dots; at least one dot.
    public var isWellFormed: Bool {
        guard rawValue.contains("."), !rawValue.hasPrefix("."), !rawValue.hasSuffix(".") else { return false }
        return rawValue.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" || $0 == "." }
    }

    /// A Debug-build command (`debug.<verb>` in the core, `<feature-id>.debug-<verb>` in a
    /// feature). Release builds register none; pickers and menus never list them.
    public var isDebugOnly: Bool { rawValue.hasPrefix("debug.") || rawValue.contains(".debug-") }

    public static func < (lhs: CommandID, rhs: CommandID) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension CommandID {
    public static let toggleHidden: CommandID = "visibility.toggle-hidden"
    public static let toggleAll: CommandID = "visibility.toggle-all"
    public static let showHidden: CommandID = "visibility.show-hidden"
    public static let showAll: CommandID = "visibility.show-all"
    public static let collapse: CommandID = "visibility.collapse"
    public static let setSection: CommandID = "layout.set-section"
    public static let setDefaultSection: CommandID = "layout.set-default-section"
    public static let activateItem: CommandID = "item.activate"
    public static let openSettings: CommandID = "app.settings"
    public static let quit: CommandID = "app.quit"
    public static let dumpState: CommandID = "debug.dump-state"
}

/// Modifier keys of a keyboard shortcut.
public struct KeyModifiers: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let shift = KeyModifiers(rawValue: 1 << 3)
}

/// A keyboard shortcut declared as data. `keyCode` is a virtual key code (`kVK_*`),
/// layout independent; the Hotkeys feature registers it.
public struct KeyCombo: Hashable, Sendable, Codable {
    public var keyCode: UInt16
    public var modifiers: KeyModifiers

    public init(keyCode: UInt16, modifiers: KeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}
