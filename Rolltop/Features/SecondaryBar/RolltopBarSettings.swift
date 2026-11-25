import AppKit
import RolltopCore

/// Settings of the Rolltop Bar (`rolltop.secondary-bar.*`).
enum RolltopBarSettings {
    /// "Show hidden items in the Rolltop Bar": the reveal commands present the panel instead
    /// of revealing hidden items inline.
    static let enabled = SettingsKey<Bool>("rolltop.secondary-bar.enabled", default: false)
    /// Item size preset, see `RolltopBarItemSize`.
    static let itemSize = SettingsKey<String>("rolltop.secondary-bar.item-size", default: RolltopBarItemSize.regular.rawValue)
    /// How always-hidden items appear, see `AlwaysHiddenPresentation`.
    static let alwaysHidden = SettingsKey<String>("rolltop.secondary-bar.always-hidden",
                                                  default: AlwaysHiddenPresentation.disclosure.rawValue)
    /// Seconds without pointer activity before a panel that was not opened by hover closes;
    /// 0 = never.
    static let idleTimeout = SettingsKey<Double>("rolltop.secondary-bar.idle-timeout", default: 10)
    /// Look of the panel, see `RolltopBarStyle`.
    static let style = SettingsKey<String>("rolltop.secondary-bar.style", default: RolltopBarStyle.adaptive.rawValue)
    /// "Use the Rolltop Bar only on displays with a notch": elsewhere hidden items appear inline.
    static let onlyWithNotch = SettingsKey<Bool>("rolltop.secondary-bar.only-with-notch", default: false)
    /// "Use the Rolltop Bar when the menu bar is full": a reveal on a display whose bar shows
    /// macOS's overflow chevron opens the Rolltop Bar, even where it is otherwise off.
    static let whenFull = SettingsKey<Bool>("rolltop.secondary-bar.when-full", default: false)
}

/// Style presets of the panel. Template images and labels take the surface's label colour
/// in every preset; system materials follow Reduce Transparency and Increase Contrast.
nonisolated enum RolltopBarStyle: String, CaseIterable, Sendable {
    /// Glass, light or dark following the backdrop (`BackdropSampler`).
    case adaptive
    /// Glass forced light.
    case light
    /// Glass forced dark.
    case dark
    /// Glass whose background is tinted with the system accent colour.
    case accent
    /// A more opaque blurred material instead of clear glass.
    case frosted

    init(setting: String) { self = RolltopBarStyle(rawValue: setting) ?? .adaptive }

    /// The appearance this preset forces; nil follows the backdrop.
    var forcedAppearance: NSAppearance.Name? {
        switch self {
        case .light: .aqua
        case .dark: .darkAqua
        case .adaptive, .accent, .frosted: nil
        }
    }
}

/// Item size presets. `regular` matches the menu bar: 18 pt images on 24 pt rows.
nonisolated enum RolltopBarItemSize: String, CaseIterable, Sendable {
    case small
    case regular
    case large

    var imageHeight: CGFloat {
        switch self {
        case .small: 15
        case .regular: 18
        case .large: 22
        }
    }

    var rowHeight: CGFloat {
        switch self {
        case .small: 21
        case .regular: 24
        case .large: 29
        }
    }

    init(setting: String) { self = RolltopBarItemSize(rawValue: setting) ?? .regular }
}

nonisolated enum AlwaysHiddenPresentation: String, CaseIterable, Sendable {
    /// Behind a trailing disclosure (or Option held while opening).
    case disclosure
    /// Always listed after the hidden items.
    case always

    init(setting: String) { self = AlwaysHiddenPresentation(rawValue: setting) ?? .disclosure }
}
