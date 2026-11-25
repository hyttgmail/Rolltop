import Foundation
import Observation
import RolltopCore

/// Where the two keys live. Injectable so tests never touch the real global domain.
protocol SpacingPreferences: AnyObject {
    func integer(forKey key: String) -> Int?
    /// nil removes the key.
    func setInteger(_ value: Int?, forKey key: String)
    /// Flushes writes and drops cached values so the next read is fresh.
    func synchronize()
}

/// The global domain of the current user on the current host (`defaults -currentHost
/// -globalDomain`), through CFPreferences. Only the two spacing keys are ever written.
final class GlobalHostPreferences: SpacingPreferences {
    func integer(forKey key: String) -> Int? {
        let value = CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    func setInteger(_ value: Int?, forKey key: String) {
        precondition(SpacingStore.keys.contains(key), "Spacing writes only its own two keys")
        CFPreferencesSetValue(key as CFString, value.map { NSNumber(value: $0) }, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }

    func synchronize() {
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }
}

/// In-memory preferences for tests and previews.
final class InMemorySpacingPreferences: SpacingPreferences {
    var values: [String: Int] = [:]
    private(set) var synchronizeCount = 0
    /// Simulates a write the system does not keep (read-back failure).
    var dropsWrites = false

    init(values: [String: Int] = [:]) { self.values = values }

    func integer(forKey key: String) -> Int? { values[key] }

    func setInteger(_ value: Int?, forKey key: String) {
        guard !dropsWrites else { return }
        values[key] = value
    }

    func synchronize() { synchronizeCount += 1 }
}

enum SpacingSettings {
    /// What Rolltop last wrote ([spacing, padding]; absent when it removed the keys or never
    /// wrote), to tell values set by another tool apart.
    static let lastApplied = SettingsKey<[Int]>("rolltop.spacing.last-applied", default: [])
}

enum SpacingError: LocalizedError, Equatable {
    case readBackMismatch(expected: SpacingValues?, found: SpacingReading)

    var errorDescription: String? {
        switch self {
        case .readBackMismatch:
            String(localized: "The spacing could not be saved: macOS kept different values.", table: "Spacing")
        }
    }
}

/// Reads and writes the two spacing keys and remembers what Rolltop wrote.
@Observable
final class SpacingStore {
    static let spacingKey = "NSStatusItemSpacing"
    static let paddingKey = "NSStatusItemSelectionPadding"
    static let keys: Set<String> = [spacingKey, paddingKey]

    private(set) var reading = SpacingReading.absent
    @ObservationIgnored private let preferences: SpacingPreferences
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let log = Log.logger("spacing")

    init(preferences: SpacingPreferences, settings: SettingsStore) {
        self.preferences = preferences
        self.settings = settings
        reload()
    }

    /// Re-reads both keys (they can change outside Rolltop).
    func reload() {
        preferences.synchronize()
        let fresh = SpacingReading(spacing: preferences.integer(forKey: Self.spacingKey),
                                   padding: preferences.integer(forKey: Self.paddingKey))
        if fresh != reading { reading = fresh }
    }

    var lastApplied: SpacingValues? {
        let stored = settings[SpacingSettings.lastApplied]
        guard stored.count == 2 else { return nil }
        return SpacingValues(spacing: stored[0], padding: stored[1])
    }

    var isSetElsewhere: Bool { reading.isSetElsewhere(lastApplied: lastApplied) }

    func apply(_ preset: SpacingPreset) throws {
        try write(preset.values)
    }

    /// Writes both keys (nil removes them), then reads them back.
    func write(_ values: SpacingValues?) throws {
        let target = values?.clamped
        preferences.setInteger(target?.spacing, forKey: Self.spacingKey)
        preferences.setInteger(target?.padding, forKey: Self.paddingKey)
        preferences.synchronize()
        reload()
        let expected = SpacingReading(spacing: target?.spacing, padding: target?.padding)
        guard reading == expected else {
            log.error("spacing read-back mismatch")
            throw SpacingError.readBackMismatch(expected: target, found: reading)
        }
        if let target {
            settings[SpacingSettings.lastApplied] = [target.spacing, target.padding]
        } else {
            settings.reset(SpacingSettings.lastApplied)
        }
        log.notice(target.map { "spacing set to \($0.spacing)/\($0.padding)" } ?? "spacing keys removed")
    }

    func resetToDefault() throws {
        try write(nil)
    }
}
