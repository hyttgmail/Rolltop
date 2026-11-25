import AppKit
import RolltopCore

/// Fixed, localizable names of menu bar item owners. The catalog uses them for system
/// modules and for the Apple agents whose process names nobody recognises; everything that
/// shows an owner's name goes through `ItemCatalog.displayName(for:)` or `entry.displayName`.
enum ItemNames {
    /// The user-facing name of a system module (never its live state).
    static func module(_ module: SystemModule) -> String {
        switch module {
        case .battery: String(localized: "Battery", table: "UI")
        case .bluetooth: String(localized: "Bluetooth", table: "UI")
        case .clock: String(localized: "Clock", table: "UI")
        case .displays: String(localized: "Displays", table: "UI")
        case .keyboard: String(localized: "Keyboard Brightness", table: "UI")
        case .sound: String(localized: "Sound", table: "UI")
        case .wifi: String(localized: "Wi-Fi", table: "UI")
        case .screenMirroring: String(localized: "Screen Mirroring", table: "UI")
        case .controlCenter: String(localized: "Control Center", table: "UI")
        }
    }

    /// Apple agents that own status items under a process name nobody recognises.
    static func agent(bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.TextInputMenuAgent": String(localized: "Input menu", table: "UI")
        case "com.apple.systemuiserver": String(localized: "Time Machine and other system items", table: "UI")
        case "com.apple.campo", "com.apple.Spotlight": String(localized: "Spotlight", table: "UI")
        default: nil
        }
    }

    /// macOS-managed extras whose spoken description comes in the system's language
    /// ("隔空投送" in an English app). Only identifiers seen on this machine are listed.
    static func managed(id: String) -> String? {
        switch id {
        case "managed:com.apple.menuextra.airdrop": String(localized: "AirDrop", table: "UI")
        default: nil
        }
    }

    /// The name of an installed app that is not running (Finder's display name, no `.app`).
    static func installedApp(bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
