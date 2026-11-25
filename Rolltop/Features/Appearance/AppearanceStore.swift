import AppKit
import Foundation
import RolltopCore

/// Settings keys of the Appearance feature. Everything lives under `rolltop.appearance.`
/// (Profiles snapshots that prefix).
enum AppearanceSettings {
    static let enabled = SettingsKey<Bool>("rolltop.appearance.enabled", default: false)
    static let style = SettingsKey<AppearanceStyle>("rolltop.appearance.style", default: .system)
    static let perDisplay = SettingsKey<Bool>("rolltop.appearance.per-display", default: false)
    static let displayStyles = SettingsKey<[String: DisplayStyleEntry]>("rolltop.appearance.display-styles", default: [:])
}

/// A connected display as the appearance feature identifies it.
nonisolated struct DisplayIdentity: Equatable, Hashable, Sendable, Identifiable {
    /// Stable across reboots and reconnection: the display's UUID.
    var key: String
    var name: String
    var displayID: CGDirectDisplayID
    var id: String { key }

    static func key(for displayID: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) as String? else { return "display-\(displayID)" }
        return string
    }
}

extension NSScreen {
    var rolltopDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    var rolltopDisplayIdentity: DisplayIdentity? {
        guard let id = rolltopDisplayID else { return nil }
        return DisplayIdentity(key: DisplayIdentity.key(for: id), name: localizedName, displayID: id)
    }
}

/// Where an edit applies.
enum AppearanceScope: Hashable {
    case allDisplays
    case display(DisplayIdentity)
    /// One desktop Space of a display (falls back to `fallback` until it has its own style).
    case space(display: DisplayIdentity, spaceID: String, fallback: AppearanceScopeFallback)
}

/// What a desktop without its own style uses.
enum AppearanceScopeFallback: Hashable {
    case allDisplays
    case display
}

/// Reads and writes the appearance configuration through `SettingsStore`.
final class AppearanceStore {
    let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    var configuration: AppearanceConfiguration {
        AppearanceConfiguration(isEnabled: settings[AppearanceSettings.enabled],
                                style: settings[AppearanceSettings.style],
                                perDisplay: settings[AppearanceSettings.perDisplay],
                                displayStyles: settings[AppearanceSettings.displayStyles])
    }

    var isEnabled: Bool {
        get { settings[AppearanceSettings.enabled] }
        set { settings[AppearanceSettings.enabled] = newValue }
    }

    var perDisplay: Bool {
        get { settings[AppearanceSettings.perDisplay] }
        set {
            // Seed every connected display with the shared style so switching changes nothing visible.
            if newValue {
                var styles = settings[AppearanceSettings.displayStyles]
                let shared = settings[AppearanceSettings.style]
                for display in NSScreen.screens.compactMap(\.rolltopDisplayIdentity) where styles[display.key] == nil {
                    styles[display.key] = DisplayStyleEntry(name: display.name, style: shared)
                }
                settings[AppearanceSettings.displayStyles] = styles
            }
            settings[AppearanceSettings.perDisplay] = newValue
        }
    }

    func style(for scope: AppearanceScope) -> AppearanceStyle {
        switch scope {
        case .allDisplays:
            return settings[AppearanceSettings.style]
        case .display(let display):
            return settings[AppearanceSettings.displayStyles][display.key]?.style ?? settings[AppearanceSettings.style]
        case .space(let display, let spaceID, let fallback):
            if let own = spaceStyles[display.key]?[spaceID] { return own }
            return style(for: fallback == .display ? .display(display) : .allDisplays)
        }
    }

    var spaceStyles: [String: [String: AppearanceStyle]] {
        get { settings[AppearanceSpaceSettings.spaceStyles] }
        set { settings[AppearanceSpaceSettings.spaceStyles] = newValue }
    }

    var corners: AppearanceCorners {
        get { settings[AppearanceSpaceSettings.corners] }
        set { settings[AppearanceSpaceSettings.corners] = newValue }
    }

    func hasOwnStyle(displayKey: String, spaceID: String) -> Bool {
        spaceStyles[displayKey]?[spaceID] != nil
    }

    /// Removes a desktop's own style: it uses the display's style again.
    func removeSpaceStyle(displayKey: String, spaceID: String) {
        var styles = spaceStyles
        styles[displayKey]?[spaceID] = nil
        if styles[displayKey]?.isEmpty == true { styles[displayKey] = nil }
        spaceStyles = styles
    }

    func setStyle(_ style: AppearanceStyle, for scope: AppearanceScope) {
        switch scope {
        case .allDisplays:
            settings[AppearanceSettings.style] = style
        case .display(let display):
            var styles = settings[AppearanceSettings.displayStyles]
            styles[display.key] = DisplayStyleEntry(name: display.name, style: style)
            settings[AppearanceSettings.displayStyles] = styles
        case .space(let display, let spaceID, _):
            var styles = spaceStyles
            styles[display.key, default: [:]][spaceID] = style
            spaceStyles = styles
        }
    }

    /// Applies a preset to `scope` (nil: wherever the user is editing, i.e. the shared style,
    /// and every display's style when styles are per display) and switches styling on.
    func applyPreset(id: String, to scope: AppearanceScope? = nil) throws {
        guard let preset = AppearancePresets.preset(id: id) else { throw CommandError.invalidArgument("id", id) }
        if let scope {
            setStyle(preset.style, for: scope)
        } else {
            settings[AppearanceSettings.style] = preset.style
            if settings[AppearanceSettings.perDisplay] {
                var styles = settings[AppearanceSettings.displayStyles]
                for key in styles.keys { styles[key]?.style = preset.style }
                settings[AppearanceSettings.displayStyles] = styles
            }
        }
        isEnabled = true
    }

    /// `appearance.toggle`: switching on while every style is "system" starts from the
    /// default preset, so the command always has a visible effect.
    func toggle() {
        if isEnabled {
            isEnabled = false
            return
        }
        let config = configuration
        let anyDrawn = config.style.drawsOverlay || (config.perDisplay && config.displayStyles.values.contains { $0.style.drawsOverlay })
        if !anyDrawn {
            settings[AppearanceSettings.style] = AppearancePresets.preset(id: AppearancePresets.defaultID)?.style ?? .system
        }
        isEnabled = true
    }

    /// Removes every appearance key (Debug reset, tests).
    func removeAll() {
        settings.reset(AppearanceSettings.enabled)
        settings.reset(AppearanceSettings.style)
        settings.reset(AppearanceSettings.perDisplay)
        settings.reset(AppearanceSettings.displayStyles)
        settings.reset(AppearanceSpaceSettings.spaceStyles)
        settings.reset(AppearanceSpaceSettings.corners)
    }
}
