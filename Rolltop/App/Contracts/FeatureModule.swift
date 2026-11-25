import Foundation

/// Stable id of a feature (`reveal`, `secondary-bar`…), used in logs and settings keys.
struct FeatureID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { self.rawValue = value }
    var description: String { rawValue }
}

/// One feature. Lives in `Rolltop/Features/<Name>/` and edits nothing outside it.
///
/// Lifecycle (driven by `AppState`): every feature is created with `init(context:)`, then
/// `commands` and `settingsPanes` of all features are registered, then `start()` is called
/// on each in `FeatureRegistry` order. `stop()` runs in reverse order at quit.
/// Register services in `init`, resolve them in `start()` or later.
protocol FeatureModule: AnyObject {
    static var id: FeatureID { get }
    init(context: AppContext)
    func start()
    func stop()
    /// Read once, after every feature is created.
    var settingsPanes: [SettingsPane] { get }
    /// Sections added to another feature's pane. Read once, after every feature is created.
    var settingsSections: [SettingsPaneSection] { get }
    /// Read once, after every feature is created. Commands can also be registered later
    /// through `context.commands`.
    var commands: [Command] { get }
}

extension FeatureModule {
    func start() {}
    func stop() {}
    var settingsPanes: [SettingsPane] { [] }
    var settingsSections: [SettingsPaneSection] { [] }
    var commands: [Command] { [] }
}
