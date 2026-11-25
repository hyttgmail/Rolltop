import Foundation
import RolltopCore

/// Status item spacing presets: writes `NSStatusItemSpacing` and
/// `NSStatusItemSelectionPadding` in the global domain of the current host. Apps read them
/// when they create their first status item, so a change applies after an app relaunches
/// or the user logs in again. Rolltop never relaunches other apps.
final class SpacingFeature: FeatureModule {
    static let id: FeatureID = "spacing"

    private unowned let context: AppContext
    /// Created on first use: unit tests (which start nothing) never touch the real domain.
    private var storage: SpacingStore?

    init(context: AppContext) {
        self.context = context
        // What Rolltop last wrote to the global domain, kept so it can be undone.
        context.settings.markTransient(SpacingSettings.lastApplied)
    }

    private var store: SpacingStore {
        if let storage { return storage }
        let store = SpacingStore(preferences: GlobalHostPreferences(), settings: context.settings)
        storage = store
        return store
    }

    var settingsPanes: [SettingsPane] {
        [
            SettingsPane(id: "spacing", title: LocalizedStringResource("Item Spacing", table: "Spacing"),
                         symbol: "arrow.left.and.right", sortOrder: 320,
                         keywords: [LocalizedStringResource("padding, gap, compact, distance between items", table: "Spacing", comment: "Settings search keywords, comma separated")]) { [unowned self] in
                SpacingSettingsView(store: store, itemCount: { [unowned self] in mainBarItemCount })
            },
        ]
    }

    var commands: [Command] {
        [
            Command(id: "spacing.apply-preset", title: LocalizedStringResource("Set Menu Bar Item Spacing", table: "Spacing"),
                    symbol: "arrow.left.and.right",
                    arguments: [CommandArgument(name: "id", title: LocalizedStringResource("Spacing", table: "Spacing"),
                                                allowedValues: SpacingPreset.allCases.map(\.rawValue))],
                    allowedFromURL: true,
                    effect: .changesSettings) { [unowned self] invocation in
                let raw = try invocation.require("id")
                guard let preset = SpacingPreset(rawValue: raw) else { throw CommandError.invalidArgument("id", raw) }
                try store.apply(preset)
            },
        ]
    }

    /// Visible items on the main display's bar; 15 when unknown.
    private var mainBarItemCount: Int {
        let bar = context.catalog.drawn.displays.first(where: \.isMain) ?? context.catalog.drawn.displays.first
        let count = bar?.slots.filter { !$0.isOverflowed }.count ?? 0
        return count > 0 ? count : 15
    }
}
