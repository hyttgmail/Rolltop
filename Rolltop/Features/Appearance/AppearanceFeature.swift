import AppKit
import Foundation
import RolltopCore
import SwiftUI

/// Menu bar styling: one click-through overlay per display behind the menu bar
/// (tint, gradient, material, glass, outline; full width, rounded bar or two pills;
/// border, shadow; per display). See `BarOverlayPanel` for the measured stacking.
final class AppearanceFeature: FeatureModule {
    static let id: FeatureID = "appearance"

    private unowned let context: AppContext
    private let store: AppearanceStore
    private let controller: AppearanceController

    init(context: AppContext) {
        self.context = context
        store = AppearanceStore(settings: context.settings)
        controller = AppearanceController(context: context, store: store)
    }

    func start() {
        controller.start()
    }

    func stop() {
        controller.stop()
    }

    var settingsPanes: [SettingsPane] {
        let controller = controller
        let store = store
        return [
            SettingsPane(id: "appearance", title: LocalizedStringResource("Menu Bar Appearance", table: "Appearance"),
                         symbol: "paintbrush", sortOrder: 310,
                         keywords: [LocalizedStringResource("style, color, tint, gradient, glass, material, outline, border, shadow, rounded, pills, notch", table: "Appearance", comment: "Settings search keywords, comma separated")]) {
                AppearanceSettingsView(controller: controller, store: store)
            },
        ]
    }

    var commands: [Command] {
        let store = store
        var commands = [
            Command(id: "appearance.toggle", title: LocalizedStringResource("Style the Menu Bar", table: "Appearance"),
                    symbol: "paintbrush", allowedFromURL: true, effect: .changesSettings,
                    isOn: { store.isEnabled }) { _ in
                store.toggle()
            },
            Command(id: "appearance.apply-preset", title: LocalizedStringResource("Apply Menu Bar Style", table: "Appearance"),
                    symbol: "paintpalette",
                    arguments: [CommandArgument(name: "id", title: LocalizedStringResource("Style", table: "Appearance"),
                                                allowedValues: AppearancePresets.ids)],
                    allowedFromURL: true,
                    effect: .changesSettings) { invocation in
                try store.applyPreset(id: try invocation.require("id"))
            },
        ]
        #if DEBUG
        commands += AppearanceDebugCommands.make(context: context, store: store, controller: controller)
        #endif
        return commands
    }
}
