import Foundation
import RolltopCore

/// Settings of the Search panel (`rolltop.palette.*`).
enum PaletteSettings {
    static let includeItems = SettingsKey<Bool>("rolltop.palette.include-items", default: true)
    static let includeProfiles = SettingsKey<Bool>("rolltop.palette.include-profiles", default: true)
    static let includeCommands = SettingsKey<Bool>("rolltop.palette.include-commands", default: true)
    static let includeSettings = SettingsKey<Bool>("rolltop.palette.include-settings", default: true)
    /// Ids of other features' result providers the user turned off.
    static let disabledProviders = SettingsKey<[String]>("rolltop.palette.disabled-providers", default: [])
    /// Close the panel after running a command, profile or other row (items and settings
    /// panes always close it: a menu or a window takes over).
    static let closeAfterRunning = SettingsKey<Bool>("rolltop.palette.close-after-running", default: true)
    /// Which screen the panel appears on, see `PaletteScreenChoice`.
    static let screen = SettingsKey<String>("rolltop.palette.screen", default: PaletteScreenChoice.pointer.rawValue)
    /// Usage history for ranking. Runtime state: marked transient by `PaletteUsageStore`.
    static let usage = SettingsKey<PaletteUsage>("rolltop.palette.usage", default: PaletteUsage())
}

nonisolated enum PaletteScreenChoice: String, CaseIterable, Sendable {
    /// The screen that has the pointer.
    case pointer = "pointer-screen"
    /// The screen with the key window / menu bar focus (`NSScreen.main`).
    case main = "main-screen"

    init(setting: String) { self = PaletteScreenChoice(rawValue: setting) ?? .pointer }
}
