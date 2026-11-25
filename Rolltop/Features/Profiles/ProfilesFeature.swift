import Foundation
import RolltopCore

/// Named menu bar setups ("work", "home", "screen sharing"): the full section layout plus,
/// optionally, other features' settings chosen by key prefix. Applied by command, status
/// menu, automations, display changes or at launch; registers the `ProfileApplying`
/// service (`.profiles`) and `.profileLayoutRestorer`.
final class ProfilesFeature: FeatureModule {
    static let id: FeatureID = "profiles"
    /// How many profiles appear in Rolltop's status menu.
    static let statusMenuSlots = 5

    private unowned let context: AppContext
    let controller: ProfilesController
    private var displayWatcher: ProfileDisplayWatcher?
    private var menuSettingObserver: ChangeObserver?
    private let log = Log.logger("profiles")

    init(context: AppContext) {
        self.context = context
        controller = ProfilesController(settings: context.settings, layout: context.layout,
                                        store: ProfileFileStore(directory: ProfileFileStore.defaultDirectory))
        context.services.register(controller, for: .profiles)
        context.services.register(controller, for: .profileLayoutRestorer)
        context.services[.backupParticipants].register(ProfilesBackupParticipant(controller: controller))
    }

    func start() {
        controller.onListChange = { [weak self] in self?.registerDynamicCommands() }
        controller.load()
        controller.applyAtLaunch(configuration: ProfileDisplayWatcher.current())
        let watcher = ProfileDisplayWatcher { [weak self] configuration in
            guard let self else { return }
            if let id = self.controller.displayConfigurationChanged(configuration) {
                self.log.notice("displays changed: applied profile \(id)")
            }
        }
        watcher.start()
        displayWatcher = watcher
        menuSettingObserver = ChangeObserver(track: { [weak self] in
            _ = self?.context.settings[ProfilesSettings.showInStatusMenu]
        }) { [weak self] in
            self?.registerDynamicCommands()
        }
    }

    func stop() {
        displayWatcher?.stop()
        menuSettingObserver?.cancel()
        controller.store.flush()
    }

    var settingsPanes: [SettingsPane] {
        [SettingsPane(id: "profiles", title: LocalizedStringResource("Profiles", table: "Profiles"),
                      symbol: "rectangle.stack", sortOrder: 150,
                      keywords: [LocalizedStringResource("presets, layouts, setups, displays, switch", table: "Profiles", comment: "Settings search keywords, comma separated")]) { [context, controller] in
            ProfilesSettingsView(context: context, controller: controller)
        }]
    }

    var commands: [Command] {
        let controller = controller
        var commands = [
            Command(id: "profiles.next", title: LocalizedStringResource("Apply Next Profile", table: "Profiles"),
                    symbol: "chevron.forward", allowedFromURL: true,
                    effect: .display) { _ in
                try controller.applyNeighbor(step: 1)
            },
            Command(id: "profiles.previous", title: LocalizedStringResource("Apply Previous Profile", table: "Profiles"),
                    symbol: "chevron.backward", allowedFromURL: true,
                    effect: .display) { _ in
                try controller.applyNeighbor(step: -1)
            },
            Command(id: "profiles.save-current", title: LocalizedStringResource("Save Current Setup as Profile", table: "Profiles"),
                    symbol: "square.and.arrow.down",
                    arguments: [CommandArgument(name: "name", title: LocalizedStringResource("Name", table: "Profiles"))],
                    allowedFromURL: true,
                    effect: .changesSettings) { invocation in
                controller.saveCurrent(name: try invocation.require("name"))
            },
        ]
        // Placeholders until start() knows the profiles; replaced in place.
        commands += Self.applyCommands(controller: controller, ids: [])
        #if DEBUG
        commands += ProfilesDebugCommands.commands(controller: controller, context: context)
        #endif
        return commands
    }

    // MARK: Dynamic commands

    /// Re-registers the commands whose allowed values or titles depend on the profiles:
    /// `profiles.apply`, `profiles.delete` and the status menu slots `profiles.apply-1`…`-5`.
    private func registerDynamicCommands() {
        let showInMenu = context.settings[ProfilesSettings.showInStatusMenu]
        // The active profile is read live by `isOn`; only re-register when what the
        // commands capture changed.
        let signature = controller.all.map { "\($0.id)\u{1}\($0.name)\u{1}\($0.symbol)" } + ["\(showInMenu)"]
        guard signature != registeredSignature else { return }
        registeredSignature = signature
        context.commands.register(Self.applyCommands(controller: controller, ids: controller.all.map(\.id)))
        context.commands.register(Self.slotCommands(controller: controller, profiles: controller.all, showInMenu: showInMenu))
    }

    private var registeredSignature: [String]?

    private static func applyCommands(controller: ProfilesController, ids: [String]) -> [Command] {
        [
            Command(id: "profiles.apply", title: LocalizedStringResource("Apply Profile", table: "Profiles"),
                    symbol: "rectangle.stack",
                    arguments: [CommandArgument(name: "id", title: LocalizedStringResource("Profile", table: "Profiles"),
                                                allowedValues: ids)],
                    allowedFromURL: true,
                    effect: .display) { invocation in
                try controller.applyProfile(id: try invocation.require("id"),
                                            reason: invocation.source == .automation ? .automation : .command)
            },
            // Destructive: never from a URL.
            Command(id: "profiles.delete", title: LocalizedStringResource("Delete Profile", table: "Profiles"),
                    symbol: "trash",
                    arguments: [CommandArgument(name: "id", title: LocalizedStringResource("Profile", table: "Profiles"),
                                                allowedValues: ids)],
                    allowedFromURL: false,
                    effect: .destructive) { invocation in
                controller.delete(id: try invocation.require("id"))
            },
        ]
    }

    /// The status menu only takes flat commands, so each of the first five profiles gets a
    /// fixed slot command whose title is the profile's name and whose checkmark shows the
    /// active profile. Empty slots stay registered but unavailable (hidden).
    static func slotCommands(controller: ProfilesController, profiles: [RolltopProfile], showInMenu: Bool) -> [Command] {
        (1...statusMenuSlots).map { slot in
            let profile = profiles.indices.contains(slot - 1) ? profiles[slot - 1] : nil
            let title: LocalizedStringResource = profile.map { LocalizedStringResource("\($0.name)", table: "Profiles") }
                ?? LocalizedStringResource("Profile \(slot)", table: "Profiles")
            let id = profile?.id
            return Command(id: CommandID("profiles.apply-\(slot)"), title: title,
                           symbol: profile?.symbol ?? RolltopProfile.defaultSymbol,
                           showInStatusMenu: showInMenu, showsSymbolInMenu: true, allowedFromURL: true,
                           effect: .display,
                           isOn: { [weak controller] in id != nil && controller?.activeProfileID == id },
                           isAvailable: { id != nil }) { [weak controller] _ in
                guard let id, let controller else { throw CommandError.unavailable(CommandID("profiles.apply-\(slot)")) }
                try controller.applyProfile(id: id, reason: .user)
            }
        }
    }
}
