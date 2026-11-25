import Foundation
import RolltopCore

/// Settings of the shelf (`rolltop.shelf.*`). Every section is off until the user turns it on.
enum ShelfSettings {
    // Clipboard history
    static let clipboardEnabled = SettingsKey<Bool>("rolltop.shelf.clipboard-enabled", default: false)
    static let clipboardLimit = SettingsKey<Int>("rolltop.shelf.clipboard-limit", default: 100)
    static let clipboardMaxAgeDays = SettingsKey<Int>("rolltop.shelf.clipboard-max-age-days", default: 7)
    static let clipboardClearOnQuit = SettingsKey<Bool>("rolltop.shelf.clipboard-clear-on-quit", default: false)
    static let clipboardIgnoredApps = SettingsKey<[String]>("rolltop.shelf.clipboard-ignored-apps", default: ShelfClipRules.defaultIgnoredApps)

    // File shelf
    static let filesEnabled = SettingsKey<Bool>("rolltop.shelf.files-enabled", default: false)
    /// Hours; 0 = until removed.
    static let filesLifetimeHours = SettingsKey<Int>("rolltop.shelf.files-lifetime-hours", default: ShelfFileLifetime.defaultHours)
    static let filesRemoveAfterDrag = SettingsKey<Bool>("rolltop.shelf.files-remove-after-drag", default: false)

    // Up next
    static let upNextEnabled = SettingsKey<Bool>("rolltop.shelf.up-next-enabled", default: false)
    static let upNextCount = SettingsKey<Int>("rolltop.shelf.up-next-count", default: 5)

    // Opening
    static let openOnHover = SettingsKey<Bool>("rolltop.shelf.open-on-hover", default: false)
    /// Seconds the pointer rests on the hot zone before the shelf opens.
    static let hoverDelay = SettingsKey<Double>("rolltop.shelf.hover-delay", default: 0.5)
    /// Only while the file shelf is on.
    static let openOnDrag = SettingsKey<Bool>("rolltop.shelf.open-on-drag", default: true)
    static let panelSize = SettingsKey<String>("rolltop.shelf.panel-size", default: ShelfPanelSize.medium.rawValue)

    // Hints (on while the shelf feature runs; each source can be switched off)
    static let hintsEnabled = SettingsKey<Bool>("rolltop.shelf.hints-enabled", default: true)
    static let hintsVolume = SettingsKey<Bool>("rolltop.shelf.hints-volume", default: true)
    static let hintsBrightness = SettingsKey<Bool>("rolltop.shelf.hints-brightness", default: true)
    static let hintsBattery = SettingsKey<Bool>("rolltop.shelf.hints-battery", default: true)

    // Cards (each appears only when its service has something to show)
    static let nowPlayingCard = SettingsKey<Bool>("rolltop.shelf.now-playing-card", default: true)
    static let weatherCard = SettingsKey<Bool>("rolltop.shelf.weather-card", default: true)

    // Choosing a clip
    static let chooseAction = SettingsKey<String>("rolltop.shelf.choose-action", default: ShelfChooseAction.copy.rawValue)

    static let clipboardLimitChoices = [25, 50, 100, 200, 500]
    static let clipboardAgeChoices = [1, 7, 30]
    static let hoverDelayChoices: [Double] = [0.2, 0.5, 1.0]
    static let upNextCountChoices = [3, 5, 8]
    static let pauseChoices = [15, 60, 240]
}

/// The effective configuration: settings, with Debug overrides applied (in memory only).
nonisolated struct ShelfConfig: Sendable, Equatable {
    var clipboardEnabled = false
    var clipboardLimit = 100
    var clipboardMaxAge: TimeInterval = 7 * 86_400
    var clipboardClearOnQuit = false
    var ignoredApps: Set<String> = Set(ShelfClipRules.defaultIgnoredApps)
    var filesEnabled = false
    var fileLifetime: TimeInterval? = 86_400
    var removeAfterDrag = false
    var upNextEnabled = false
    var upNextCount = 5
    var openOnHover = false
    var hoverDelay: TimeInterval = 0.5
    var openOnDrag = true
    var panelSize: ShelfPanelSize = .medium
    var hints = ShelfHintConfig()
    var nowPlayingCard = true
    var weatherCard = true
    var chooseAction: ShelfChooseAction = .copy

    var enabledSections: [ShelfSection] {
        ShelfSection.allCases.filter { section in
            switch section {
            case .clipboard: clipboardEnabled
            case .files: filesEnabled
            case .upNext: upNextEnabled
            }
        }
    }
}

/// What choosing a clip does. The other one is always one gesture away (Option-click in
/// the shelf, ⌘Return in Search).
nonisolated enum ShelfChooseAction: String, Sendable, CaseIterable {
    case copy
    case paste

    init(setting: String) { self = ShelfChooseAction(rawValue: setting) ?? .copy }

    static func resolve(setting: ShelfChooseAction, alternate: Bool) -> ShelfChooseAction {
        guard alternate else { return setting }
        return setting == .copy ? .paste : .copy
    }
}
