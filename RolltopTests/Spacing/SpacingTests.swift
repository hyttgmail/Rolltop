import Foundation
import RolltopCore
import Testing
@testable import Rolltop

// Every test uses InMemorySpacingPreferences: the real global domain is never touched.

@Suite struct SpacingPresetTests {
    @Test func presetValues() {
        #expect(SpacingPreset.default.values == nil)
        #expect(SpacingPreset.small.values == SpacingValues(spacing: 10, padding: 8))
        #expect(SpacingPreset.tiny.values == SpacingValues(spacing: 6, padding: 4))
        #expect(SpacingPreset.none.values == SpacingValues(spacing: 0, padding: 0))
        // Presets shrink monotonically.
        let spacings = SpacingPreset.allCases.map { ($0.values ?? .systemDefault).spacing }
        #expect(spacings == spacings.sorted(by: >))
    }

    @Test func readingsMapToChoices() {
        #expect(SpacingReading.absent.choice == .preset(.default))
        #expect(SpacingReading(spacing: 10, padding: 8).choice == .preset(.small))
        #expect(SpacingReading(spacing: 6, padding: 4).choice == .preset(.tiny))
        #expect(SpacingReading(spacing: 0, padding: 0).choice == .preset(.none))
        #expect(SpacingReading(spacing: 12, padding: 8).choice == .custom(SpacingValues(spacing: 12, padding: 8)))
        // One key alone: the other takes the system default.
        #expect(SpacingReading(spacing: 10, padding: nil).choice == .custom(SpacingValues(spacing: 10, padding: 16)))
        #expect(SpacingReading(spacing: 16, padding: 16).choice == .custom(.systemDefault))
    }

    @Test func valuesSetElsewhere() {
        #expect(!SpacingReading.absent.isSetElsewhere(lastApplied: nil))
        #expect(SpacingReading(spacing: 8, padding: 8).isSetElsewhere(lastApplied: nil))
        #expect(!SpacingReading(spacing: 10, padding: 8).isSetElsewhere(lastApplied: SpacingValues(spacing: 10, padding: 8)))
        #expect(SpacingReading(spacing: 10, padding: 6).isSetElsewhere(lastApplied: SpacingValues(spacing: 10, padding: 8)))
    }

    @Test func extraItemEstimate() {
        // 17 items, as on this machine's main bar.
        #expect(SpacingEstimate.extraItems(itemCount: 17, values: nil) == 0)
        #expect(SpacingEstimate.extraItems(itemCount: 17, values: SpacingPreset.small.values) == 3)
        #expect(SpacingEstimate.extraItems(itemCount: 17, values: SpacingPreset.tiny.values) == 6)
        #expect(SpacingEstimate.extraItems(itemCount: 17, values: SpacingPreset.none.values) == 12)
        #expect(SpacingEstimate.extraItems(itemCount: 17, values: SpacingValues(spacing: 20, padding: 16)) == 0)
        #expect(SpacingEstimate.extraItems(itemCount: 0, values: SpacingPreset.none.values) == 0)
    }
}

@Suite struct SpacingStoreTests {
    private func makeStore(_ values: [String: Int] = [:]) throws -> (SpacingStore, InMemorySpacingPreferences, UserDefaults, String) {
        let suite = "com.alphapengwang.rolltop.tests.spacing.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let preferences = InMemorySpacingPreferences(values: values)
        return (SpacingStore(preferences: preferences, settings: SettingsStore(defaults: defaults)), preferences, defaults, suite)
    }

    @Test func applyWritesBothKeysAndReadsBack() throws {
        let (store, preferences, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.reading == .absent)
        try store.apply(.small)
        #expect(preferences.values == ["NSStatusItemSpacing": 10, "NSStatusItemSelectionPadding": 8])
        #expect(store.reading.choice == .preset(.small))
        #expect(store.lastApplied == SpacingValues(spacing: 10, padding: 8))
        #expect(!store.isSetElsewhere)
        #expect(preferences.synchronizeCount >= 2)
    }

    @Test func resetRemovesBothKeys() throws {
        let (store, preferences, defaults, suite) = try makeStore(["NSStatusItemSpacing": 4, "NSStatusItemSelectionPadding": 2])
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.isSetElsewhere)
        try store.resetToDefault()
        #expect(preferences.values.isEmpty)
        #expect(store.reading.isAbsent)
        #expect(store.lastApplied == nil)
        try store.apply(.none)
        try store.apply(.default)
        #expect(preferences.values.isEmpty)
    }

    @Test func customValuesAreClamped() throws {
        let (store, preferences, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        try store.write(SpacingValues(spacing: 55, padding: -3))
        #expect(preferences.values == ["NSStatusItemSpacing": 40, "NSStatusItemSelectionPadding": 0])
    }

    @Test func readBackMismatchThrowsAndRemembersNothing() throws {
        let (store, preferences, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.dropsWrites = true
        #expect(throws: SpacingError.self) { try store.apply(.tiny) }
        #expect(store.lastApplied == nil)
    }

    @Test func externalChangesShowAfterReload() throws {
        let (store, preferences, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        try store.apply(.small)
        preferences.values["NSStatusItemSpacing"] = 3
        store.reload()
        #expect(store.reading.choice == .custom(SpacingValues(spacing: 3, padding: 8)))
        #expect(store.isSetElsewhere)
    }
}
