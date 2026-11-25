import Foundation

/// A named starting point. Applying one replaces the style; the user edits from there.
nonisolated struct AppearancePreset: Identifiable, Sendable {
    let id: String
    let name: LocalizedStringResource
    let style: AppearanceStyle
}

nonisolated enum AppearancePresets {
    /// Used when styling is switched on while the style is "system".
    static let defaultID = "soft-tint"

    static let all: [AppearancePreset] = [
        AppearancePreset(id: "soft-tint", name: LocalizedStringResource("Soft tint", table: "Appearance"), style: make { style in
            style.kind = .tint
            style.tint = .matchSystem
            style.tintOpacity = 0.45
            style.shape = .fullWidth
        }),
        AppearancePreset(id: "frosted", name: LocalizedStringResource("Frosted", table: "Appearance"), style: make { style in
            style.kind = .material
            style.material = .thin
            style.shape = .fullWidth
        }),
        AppearancePreset(id: "glass-pills", name: LocalizedStringResource("Glass pills", table: "Appearance"), style: make { style in
            style.kind = .glass
            style.glass = .regular
            style.shape = .split
            style.cornerRadius = 13
            style.shadow = ShadowOptions(isEnabled: true, strength: 0.3)
        }),
        AppearancePreset(id: "rounded-bar", name: LocalizedStringResource("Rounded bar", table: "Appearance"), style: make { style in
            style.kind = .tint
            style.tint = .matchSystem
            style.tintOpacity = 0.6
            style.shape = .inset
            style.cornerRadius = 9
            style.border = BorderOptions(isEnabled: true, color: .matchSystem, width: 1)
        }),
        AppearancePreset(id: "dusk", name: LocalizedStringResource("Dusk", table: "Appearance"), style: make { style in
            style.kind = .gradient
            style.gradientStart = .lightAndDark(RGBA(0.99, 0.80, 0.62), RGBA(0.36, 0.16, 0.38))
            style.gradientEnd = .lightAndDark(RGBA(0.73, 0.83, 0.99), RGBA(0.10, 0.22, 0.42))
            style.gradientAngle = 0
            style.gradientOpacity = 0.75
            style.shape = .fullWidth
        }),
        AppearancePreset(id: "outline", name: LocalizedStringResource("Outline", table: "Appearance"), style: make { style in
            style.kind = .outline
            style.border = BorderOptions(isEnabled: true, color: .matchSystem, width: 1.5)
            style.shape = .split
            style.cornerRadius = 13
        }),
    ]

    static func preset(id: String) -> AppearancePreset? { all.first { $0.id == id } }

    static var ids: [String] { all.map(\.id) }

    private static func make(_ configure: (inout AppearanceStyle) -> Void) -> AppearanceStyle {
        var style = AppearanceStyle()
        configure(&style)
        return style
    }
}
