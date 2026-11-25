import Foundation
import Observation
import RolltopCore

/// Typed, observable access to Rolltop's `UserDefaults`. Every key starts with `rolltop.`.
///
/// Scalars (Bool, Int, Double, String, Date, Data) are stored natively so `defaults read`
/// stays legible; other `Codable` values are stored as JSON data. Any change, also one
/// made outside the app, bumps `revision`, so a SwiftUI view or `withObservationTracking`
/// that reads a value through this store re-evaluates.
@Observable
final class SettingsStore {
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private var observer: NSObjectProtocol?
    /// Keys that hold runtime state, not settings (see `markTransient`).
    @ObservationIgnored private(set) var transientKeyNames: Set<String> = []
    private(set) var revision = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                          object: defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.revision += 1 }
        }
    }

    subscript<Value>(key: SettingsKey<Value>) -> Value {
        get { value(key) }
        set { set(newValue, for: key) }
    }

    func value<Value>(_ key: SettingsKey<Value>) -> Value {
        _ = revision
        guard let raw = defaults.object(forKey: key.name) else { return key.defaultValue }
        if Self.isNative(Value.self), let value = raw as? Value { return value }
        let data: Data? = (raw as? Data) ?? (raw as? String).map { Data($0.utf8) }
        guard let data, let decoded = try? JSONDecoder().decode(Value.self, from: data) else { return key.defaultValue }
        return decoded
    }

    func set<Value>(_ value: Value, for key: SettingsKey<Value>) {
        if Self.isNative(Value.self) {
            defaults.set(value, forKey: key.name)
        } else if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key.name)
        }
        revision += 1
    }

    func reset<Value>(_ key: SettingsKey<Value>) {
        defaults.removeObject(forKey: key.name)
        revision += 1
    }

    func hasValue<Value>(for key: SettingsKey<Value>) -> Bool {
        _ = revision
        return defaults.object(forKey: key.name) != nil
    }

    /// Marks a key as runtime state rather than a setting (which rules are active, the
    /// last pane shown, whether onboarding ran, what Rolltop last wrote elsewhere). Transient
    /// keys stay on this Mac: `exportAll()` leaves them out, `replaceAll(with:)` neither
    /// removes nor writes them, so exports, imports, profiles and "Reset all settings"
    /// never touch them. Call from `init(context:)`, before anything can export.
    func markTransient<Value>(_ key: SettingsKey<Value>) {
        transientKeyNames.insert(key.name)
    }

    func isTransient(_ name: String) -> Bool { transientKeyNames.contains(name) }

    /// Every stored `rolltop.*` setting, as property-list objects (for export, backups and
    /// profiles). Transient keys are left out.
    func exportAll() -> [String: Any] {
        defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("rolltop.") && !transientKeyNames.contains($0.key) }
    }

    /// Replaces every `rolltop.*` setting with `values` (keys without the prefix and
    /// transient keys are ignored; stored transient values stay as they are).
    func replaceAll(with values: [String: Any]) {
        for key in exportAll().keys { defaults.removeObject(forKey: key) }
        for (key, value) in values where key.hasPrefix("rolltop.") && !transientKeyNames.contains(key) {
            defaults.set(value, forKey: key)
        }
        revision += 1
    }

    private static func isNative<Value>(_ type: Value.Type) -> Bool {
        type == Bool.self || type == Int.self || type == Double.self || type == String.self
            || type == Date.self || type == Data.self
    }
}

/// Settings keys owned by the shared core. Features declare their own keys in their
/// own directory as `rolltop.<feature>.<name>`.
enum CoreSettings {
    static let layout = SettingsKey<Layout>("rolltop.layout", default: .empty)
    /// Owners that "conceal shown" (swap / hide everything) never hides.
    static let pinned = SettingsKey<[OwnerID]>("rolltop.visibility.pinned", default: [.system(.clock), .system(.controlCenter)])
    /// Idle refresh period of the item catalog, seconds.
    static let catalogRefreshInterval = SettingsKey<Double>("rolltop.catalog.refresh-interval", default: 20)
}
