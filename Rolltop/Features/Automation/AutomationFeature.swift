import AppKit
import Foundation
import RolltopCore

/// How other tools drive Rolltop, and how settings travel: `rolltop://` links with a sender
/// policy, Shortcuts (App Intents, a Focus filter), AppleScript (`Rolltop.sdef` in this
/// directory), and backups (export, import, reset, automatic local backups).
///
/// The feature id is `interop` (its directory keeps the planned name `Automation`; the
/// neighbouring `Automations` feature owns rules and triggers): settings keys
/// `rolltop.interop.*`, commands `interop.*`, strings in the `Automation` table.
final class AutomationFeature: FeatureModule {
    static let id: FeatureID = "interop"

    private unowned let context: AppContext
    let gate: InteropLinkGate
    let backups: InteropBackupController
    private let log = Log.logger("interop")

    init(context: AppContext) {
        self.context = context
        InteropSettings.markTransient(in: context.settings)
        gate = InteropLinkGate(context: context)
        // Every link, also the one that launched Rolltop, comes here (App/LinkIntake.swift).
        context.services.register(gate as any LinkGating, for: .linkGate)
        // Fed by the Focus filter (`InteropActions.focusChanged`); unknown until it runs.
        context.services.register(InteropFocusState() as any FocusStateProviding, for: .focusState)
        backups = InteropBackupController(context: context, directory: InteropBackupController.defaultDirectory)
    }

    func start() {
        gate.prompter = InteropLinkPrompter(statusItemFrame: context.statusItemFrame)
        gate.registerAliases()
    }

    func stop() {
        gate.prompter?.closeAll()
    }

    var settingsPanes: [SettingsPane] {
        let context = context
        let gate = gate
        let backups = backups
        return [
            SettingsPane(id: "integrations", title: LocalizedStringResource("Integrations", table: "Automation"),
                         symbol: "link", sortOrder: 420,
                         keywords: [LocalizedStringResource("links, url, url scheme, shortcuts, siri, focus, focus filter, applescript, script, automation, apps",
                                                            table: "Automation", comment: "Settings search keywords, comma separated")]) {
                InteropIntegrationsPane(context: context, gate: gate)
            },
            SettingsPane(id: "backup", title: LocalizedStringResource("Backup", table: "Automation"),
                         symbol: "externaldrive.badge.timemachine", sortOrder: 915,
                         keywords: [LocalizedStringResource("export, import, backup, restore, reset, transfer, settings file",
                                                            table: "Automation", comment: "Settings search keywords, comma separated")]) {
                InteropBackupPane(context: context, backups: backups)
            },
        ]
    }

    var commands: [Command] {
        var commands = InteropCommands.commands(context: context, backups: backups)
        #if DEBUG
        commands += InteropDebugCommands.commands(context: context, gate: gate, backups: backups)
        #endif
        return commands
    }
}
