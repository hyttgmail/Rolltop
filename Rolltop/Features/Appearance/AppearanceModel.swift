import CoreGraphics
import Foundation

// Pure data for menu bar styling. Everything here is Codable (stored under
// `rolltop.appearance.` and snapshotted by Profiles) and decodes leniently: a missing field
// takes its default, so older stored values keep working when fields are added.

/// An sRGB colour with alpha, components in 0…1.
nonisolated struct RGBA: Codable, Equatable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    static let white = RGBA(1, 1, 1)
    static let black = RGBA(0, 0, 0)

    func withAlpha(_ alpha: Double) -> RGBA { RGBA(red, green, blue, alpha) }

    /// Multiplies alpha by `factor`, clamped to 0…1.
    func fading(_ factor: Double) -> RGBA { withAlpha(min(1, max(0, alpha * factor))) }
}

/// Whether the menu bar currently shows dark content on a light background (`light`) or
/// light content on a dark background (`dark`). On macOS 27 the transparent bar picks
/// its text colour from the wallpaper, not from the system appearance, so this is
/// measured per bar (see `MenuBarAppearanceProbe`).
nonisolated enum BarAppearance: String, Codable, Sendable, CaseIterable {
    case light
    case dark
}

/// A colour that adapts to the bar's appearance.
nonisolated struct AdaptiveColor: Codable, Equatable, Hashable, Sendable {
    enum Mode: String, Codable, Sendable, CaseIterable {
        /// A system colour that always contrasts with the bar's text.
        case matchSystem = "match-system"
        /// `light` in both appearances.
        case single
        /// `light` on a light bar, `dark` on a dark bar.
        case lightAndDark = "light-and-dark"
    }

    var mode: Mode
    var light: RGBA
    var dark: RGBA

    init(mode: Mode, light: RGBA, dark: RGBA) {
        self.mode = mode
        self.light = light
        self.dark = dark
    }

    static func single(_ color: RGBA) -> AdaptiveColor { AdaptiveColor(mode: .single, light: color, dark: color) }
    static func lightAndDark(_ light: RGBA, _ dark: RGBA) -> AdaptiveColor { AdaptiveColor(mode: .lightAndDark, light: light, dark: dark) }
    static let matchSystem = AdaptiveColor(mode: .matchSystem, light: RGBA(0.96, 0.96, 0.97), dark: RGBA(0.10, 0.10, 0.12))
}

/// What a colour is used for; decides the "match system" value.
nonisolated enum ColorRole: Sendable {
    case fill
    case border
    case glassTint
}

nonisolated enum ColorResolver {
    /// The concrete colour for `color` in `appearance`. "Match system" picks a background
    /// that keeps the bar's own text legible: light behind dark text, dark behind light text.
    static func resolve(_ color: AdaptiveColor, role: ColorRole, appearance: BarAppearance) -> RGBA {
        switch color.mode {
        case .single:
            return color.light
        case .lightAndDark:
            return appearance == .dark ? color.dark : color.light
        case .matchSystem:
            switch (role, appearance) {
            case (.fill, .light): return RGBA(0.97, 0.97, 0.98)
            case (.fill, .dark): return RGBA(0.09, 0.09, 0.11)
            case (.border, .light): return RGBA(0, 0, 0, 0.18)
            case (.border, .dark): return RGBA(1, 1, 1, 0.24)
            case (.glassTint, .light): return RGBA(1, 1, 1, 0.25)
            case (.glassTint, .dark): return RGBA(0, 0, 0, 0.25)
            }
        }
    }

    /// Start and end points (unit square, top-left origin, y down) of a linear gradient
    /// at `degrees`: 0 runs left to right, 90 top to bottom, 180 right to left.
    static func gradientPoints(degrees: Double) -> (start: CGPoint, end: CGPoint) {
        let radians = degrees * .pi / 180
        let dx = cos(radians) / 2
        let dy = sin(radians) / 2
        func clean(_ value: Double) -> Double { (value * 1e9).rounded() / 1e9 }
        return (CGPoint(x: clean(0.5 - dx), y: clean(0.5 - dy)), CGPoint(x: clean(0.5 + dx), y: clean(0.5 + dy)))
    }
}

/// The look of the bar.
nonisolated enum StyleKind: String, Codable, Sendable, CaseIterable {
    /// No overlay at all.
    case system
    case tint
    case gradient
    case material
    case glass
    case outline
}

/// System material thickness (SwiftUI `Material`).
nonisolated enum MaterialThickness: String, Codable, Sendable, CaseIterable {
    case ultraThin = "ultra-thin"
    case thin
    case regular
    case thick
    case ultraThick = "ultra-thick"
}

/// `NSGlassEffectView.Style`.
nonisolated enum GlassVariant: String, Codable, Sendable, CaseIterable {
    case regular
    case clear
}

/// The outline of the styled area.
nonisolated enum BarShape: String, Codable, Sendable, CaseIterable {
    /// The whole strip.
    case fullWidth = "full-width"
    /// A rounded bar inset from the screen edges.
    case inset
    /// One pill around the app menus, one around the status items.
    case split
}

nonisolated struct BorderOptions: Codable, Equatable, Hashable, Sendable {
    var isEnabled = false
    var color = AdaptiveColor.matchSystem
    /// Points.
    var width = 1.0
}

nonisolated struct ShadowOptions: Codable, Equatable, Hashable, Sendable {
    var isEnabled = false
    /// 0…1.
    var strength = 0.5
}

/// A complete bar style. Options that do not apply to `kind` are kept so switching back
/// restores them.
nonisolated struct AppearanceStyle: Codable, Equatable, Hashable, Sendable {
    var kind: StyleKind = .system
    /// Tint fill; also the glass tint.
    var tint = AdaptiveColor.matchSystem
    /// Opacity of the tint fill, 0…1.
    var tintOpacity = 0.35
    var gradientStart = AdaptiveColor.lightAndDark(RGBA(0.99, 0.80, 0.62), RGBA(0.36, 0.16, 0.38))
    var gradientEnd = AdaptiveColor.lightAndDark(RGBA(0.73, 0.83, 0.99), RGBA(0.10, 0.22, 0.42))
    /// Degrees; 0 runs left to right.
    var gradientAngle = 0.0
    /// Opacity of the gradient, 0…1.
    var gradientOpacity = 0.6
    var material = MaterialThickness.regular
    var glass = GlassVariant.regular
    var glassIsTinted = false
    var border = BorderOptions()
    var shadow = ShadowOptions()
    /// Points; capped at half the bar height.
    var cornerRadius = 8.0
    var shape = BarShape.fullWidth
    /// On a display with a camera housing, draw full-width and inset shapes as two parts
    /// on either side of it.
    var splitAroundNotch = true

    init() {}

    static let system = AppearanceStyle()

    /// Whether the style draws anything.
    var drawsOverlay: Bool { kind != .system }

    /// Outline always draws a border, even when the border option is off.
    var effectiveBorder: BorderOptions {
        guard kind == .outline, !border.isEnabled else { return border }
        var forced = border
        forced.isEnabled = true
        forced.width = max(1, forced.width)
        return forced
    }

    private enum CodingKeys: String, CodingKey {
        case kind, tint, tintOpacity, gradientStart, gradientEnd, gradientAngle, gradientOpacity, material, glass,
             glassIsTinted, border, shadow, cornerRadius, shape, splitAroundNotch
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppearanceStyle()
        kind = (try? c.decodeIfPresent(StyleKind.self, forKey: .kind)) ?? d.kind
        tint = (try? c.decodeIfPresent(AdaptiveColor.self, forKey: .tint)) ?? d.tint
        tintOpacity = (try? c.decodeIfPresent(Double.self, forKey: .tintOpacity)) ?? d.tintOpacity
        gradientStart = (try? c.decodeIfPresent(AdaptiveColor.self, forKey: .gradientStart)) ?? d.gradientStart
        gradientEnd = (try? c.decodeIfPresent(AdaptiveColor.self, forKey: .gradientEnd)) ?? d.gradientEnd
        gradientAngle = (try? c.decodeIfPresent(Double.self, forKey: .gradientAngle)) ?? d.gradientAngle
        gradientOpacity = (try? c.decodeIfPresent(Double.self, forKey: .gradientOpacity)) ?? d.gradientOpacity
        material = (try? c.decodeIfPresent(MaterialThickness.self, forKey: .material)) ?? d.material
        glass = (try? c.decodeIfPresent(GlassVariant.self, forKey: .glass)) ?? d.glass
        glassIsTinted = (try? c.decodeIfPresent(Bool.self, forKey: .glassIsTinted)) ?? d.glassIsTinted
        border = (try? c.decodeIfPresent(BorderOptions.self, forKey: .border)) ?? d.border
        shadow = (try? c.decodeIfPresent(ShadowOptions.self, forKey: .shadow)) ?? d.shadow
        cornerRadius = (try? c.decodeIfPresent(Double.self, forKey: .cornerRadius)) ?? d.cornerRadius
        shape = (try? c.decodeIfPresent(BarShape.self, forKey: .shape)) ?? d.shape
        splitAroundNotch = (try? c.decodeIfPresent(Bool.self, forKey: .splitAroundNotch)) ?? d.splitAroundNotch
    }
}

/// A style remembered for one display.
nonisolated struct DisplayStyleEntry: Codable, Equatable, Hashable, Sendable {
    /// The display's name when it was last seen, for displays that are not connected.
    var name: String
    var style: AppearanceStyle
}

/// The stored configuration, read from settings as one value.
nonisolated struct AppearanceConfiguration: Equatable, Sendable {
    var isEnabled = false
    var style = AppearanceStyle.system
    var perDisplay = false
    /// Keyed by `DisplayIdentity.key`.
    var displayStyles: [String: DisplayStyleEntry] = [:]

    /// The style to draw on the display with `displayKey`, or nil when nothing is drawn.
    func style(forDisplay displayKey: String) -> AppearanceStyle? {
        guard isEnabled else { return nil }
        let chosen = perDisplay ? (displayStyles[displayKey]?.style ?? style) : style
        return chosen.drawsOverlay ? chosen : nil
    }

    /// Whether any of `displayKeys` gets an overlay (no overlay = nothing runs).
    func drawsAnything(on displayKeys: [String]) -> Bool {
        displayKeys.contains { style(forDisplay: $0) != nil }
    }
}
