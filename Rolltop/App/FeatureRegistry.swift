import Foundation

/// Every planned feature, in start order. Each type lives in `Rolltop/Features/<Name>/`.
/// Feature authors never edit this file: their entry is already here.
enum FeatureRegistry {
    static let all: [any FeatureModule.Type] = [
        SettingsShellFeature.self,   // M1b
        OnboardingFeature.self,      // M1b
        CaptureFeature.self,         // W1-B (registers item images before panels start)
        ProfilesFeature.self,        // W1-C
        RevealFeature.self,          // W1-A
        HotkeysFeature.self,         // W1-A
        SecondaryBarFeature.self,    // W1-B
        AutomationsFeature.self,     // W1-C, W2-D
        AppearanceFeature.self,      // W1-D
        SpacingFeature.self,         // W1-D
        LayoutEditorFeature.self,    // W2-A
        CommandPaletteFeature.self,  // W2-B
        MediaFeature.self,           // round 2 (provides .nowPlaying)
        WeatherFeature.self,         // round 2 (provides .weather)
        CustomItemsFeature.self,     // W2-C
        AutomationFeature.self,      // W2-D
        ShelfFeature.self,           // W3-A
    ]
}
