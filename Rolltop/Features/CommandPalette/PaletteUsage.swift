import Foundation
import RolltopCore

/// Which rows the user ran and when: frequency with recency decay. Pure value; stored on
/// this Mac only (`PaletteSettings.usage`, a transient key that exports and profiles skip).
nonisolated struct PaletteUsage: Codable, Equatable, Sendable {
    nonisolated struct Entry: Codable, Equatable, Sendable {
        /// Decayed use count as of `lastUsed`.
        var score: Double
        var count: Int
        var lastUsed: Date
    }

    /// A use counts half after this long.
    static let halfLife: TimeInterval = 7 * 24 * 3600
    /// Entries kept; the weakest go first.
    static let limit = 200

    private(set) var entries: [String: Entry] = [:]

    var isEmpty: Bool { entries.isEmpty }

    mutating func record(_ key: String, at date: Date) {
        if var entry = entries[key] {
            entry.score = Self.decayed(entry.score, from: entry.lastUsed, to: date) + 1
            entry.count += 1
            entry.lastUsed = max(entry.lastUsed, date)
            entries[key] = entry
        } else {
            entries[key] = Entry(score: 1, count: 1, lastUsed: date)
        }
        if entries.count > Self.limit {
            let weakest = entries.min { score(for: $0.key, at: date) < score(for: $1.key, at: date) }
            if let weakest { entries[weakest.key] = nil }
        }
    }

    /// Frequency weighted by recency at `date`; 0 for rows never used.
    func score(for key: String, at date: Date) -> Double {
        guard let entry = entries[key] else { return 0 }
        return Self.decayed(entry.score, from: entry.lastUsed, to: date)
    }

    /// Used rows, most recent first.
    func recentKeys(at date: Date) -> [String] {
        entries.sorted { $0.value.lastUsed != $1.value.lastUsed ? $0.value.lastUsed > $1.value.lastUsed : $0.key < $1.key }
            .map(\.key)
    }

    mutating func clear() { entries.removeAll() }

    static func decayed(_ score: Double, from: Date, to: Date) -> Double {
        let elapsed = max(0, to.timeIntervalSince(from))
        return score * pow(0.5, elapsed / halfLife)
    }
}

/// Reads and writes the usage history through the settings store (observable through it).
final class PaletteUsageStore {
    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
        settings.markTransient(PaletteSettings.usage)
    }

    var usage: PaletteUsage { settings[PaletteSettings.usage] }

    func record(_ key: String, at date: Date = Date()) {
        var usage = usage
        usage.record(key, at: date)
        settings[PaletteSettings.usage] = usage
    }

    func clear() {
        settings.reset(PaletteSettings.usage)
    }
}
