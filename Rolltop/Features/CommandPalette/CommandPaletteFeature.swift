import Foundation
import RolltopCore

/// Search: a Spotlight-style panel to find and trigger menu bar items, profiles, commands
/// and settings from the keyboard (Bartender's Quick Search). Milestone W2-B.
///
/// Opened by `palette.toggle` / `palette.show` (no default shortcut: the user assigns one in
/// the Shortcuts pane; "Search Menu Bar Items…" is in Rolltop's menu). Other features add rows
/// through `services[.paletteResultProviders]` (Contracts/FeatureServices.swift).
final class CommandPaletteFeature: FeatureModule {
    static let id: FeatureID = "palette"

    unowned let context: AppContext
    /// Created on first use, so instantiating the feature (tests) creates no window.
    private var storedController: PaletteController?
    private let log = Log.logger("palette")

    init(context: AppContext) {
        self.context = context
        // Usage history is runtime state: keep it out of exports and profiles from the start.
        context.settings.markTransient(PaletteSettings.usage)
    }

    var controller: PaletteController {
        if let storedController { return storedController }
        let controller = PaletteController(context: context)
        storedController = controller
        return controller
    }

    func stop() {
        storedController?.stop()
    }

    var settingsPanes: [SettingsPane] {
        [SettingsPane(id: PaletteCommandIDs.paneID, title: LocalizedStringResource("Search", table: "CommandPalette"),
                      symbol: "magnifyingglass", sortOrder: 230,
                      keywords: [LocalizedStringResource("command palette, quick search, find, keyboard, launcher, history",
                                                         table: "CommandPalette", comment: "Settings search keywords, comma separated")]) { [weak self] in
            if let self {
                PaletteSettingsView(context: self.context, usage: self.controller.usage)
            }
        }]
    }

    var commands: [Command] {
        var commands = [
            Command(id: PaletteCommandIDs.toggle,
                    title: LocalizedStringResource("Search Menu Bar Items…", table: "CommandPalette"),
                    symbol: "magnifyingglass", showInStatusMenu: true, allowedFromURL: true,
                    effect: .display) { [weak self] _ in
                self?.controller.toggle()
            },
            Command(id: PaletteCommandIDs.show,
                    title: LocalizedStringResource("Show Search", table: "CommandPalette"),
                    symbol: "magnifyingglass", allowedFromURL: true,
                    effect: .display) { [weak self] _ in
                self?.controller.show()
            },
            Command(id: PaletteCommandIDs.clearHistory,
                    title: LocalizedStringResource("Clear Search History", table: "CommandPalette"),
                    symbol: "clock.arrow.circlepath", allowedFromURL: true,
                    effect: .destructive) { [weak self] _ in
                self?.controller.usage.clear()
            },
        ]
        #if DEBUG
        commands += PaletteDebugCommands.commands(feature: self)
        #endif
        return commands
    }
}
