#if DEBUG
import AppKit
import Foundation
import RolltopCore
import SwiftUI

/// Debug-build commands for live tests: backups without panels (the real commands refuse
/// links), a link from a pretend app (prompt and app-list paths), forgetting the link
/// policy, and a JSON dump (`debug/interop.json`).
enum InteropDebugCommands {
    static func commands(context: AppContext, gate: InteropLinkGate, backups: InteropBackupController) -> [Command] {
        [
            Command(id: "interop.debug-export-backup", title: "Export Backup to Path (Debug)", symbol: "ladybug",
                    arguments: [CommandArgument(name: "path", title: "Path")], allowedFromURL: true) { invocation in
                try await context.commands.run("interop.export-backup", arguments: ["path": try invocation.require("path")], source: .internal)
            },
            Command(id: "interop.debug-import-backup", title: "Import Backup from Path (Debug)", symbol: "ladybug",
                    arguments: [CommandArgument(name: "path", title: "Path"), CommandArgument(name: "parts", title: "Parts", isRequired: false)],
                    allowedFromURL: true) { invocation in
                try await context.commands.run("interop.import-backup", arguments: invocation.arguments, source: .internal)
            },
            Command(id: "interop.debug-reset", title: "Reset (Debug)", symbol: "ladybug",
                    arguments: [CommandArgument(name: "scope", title: "Scope", allowedValues: ["layout", "everything"])],
                    allowedFromURL: true) { invocation in
                guard let scope = InteropBackupController.ResetScope(rawValue: try invocation.require("scope")) else { return }
                try await backups.reset(scope)
            },
            // Restores the automatic backup at `index` (0 = newest), as the pane's Restore button
            // does after its confirmation.
            Command(id: "interop.debug-restore", title: "Restore an Automatic Backup (Debug)", symbol: "ladybug",
                    arguments: [CommandArgument(name: "index", title: "Index (0 = newest)")], allowedFromURL: true) { invocation in
                await backups.refreshLocalBackups()
                guard let index = Int(try invocation.require("index")), backups.localBackups.indices.contains(index) else {
                    throw CommandError.invalidArgument("index", invocation.string("index") ?? "")
                }
                try await backups.restore(backups.localBackups[index])
            },
            // `rolltop-cmd.sh interop.debug-link url=rolltop://toggle sender=com.example.App name=Example`
            Command(id: "interop.debug-link", title: "Handle a Link as if Sent by an App (Debug)", symbol: "ladybug",
                    arguments: [CommandArgument(name: "url", title: "Link"),
                                CommandArgument(name: "sender", title: "Bundle id (empty: unknown sender)", isRequired: false),
                                CommandArgument(name: "name", title: "App name", isRequired: false)],
                    allowedFromURL: true) { invocation in
                guard let url = URL(string: try invocation.require("url")) else { throw CommandError.invalidArgument("url", "") }
                let sender: LinkSender = invocation.string("sender").flatMap { $0.isEmpty ? nil : $0 }.map {
                    LinkSender(kind: .app, bundleID: $0, name: invocation.string("name") ?? $0)
                } ?? .unknown
                gate.handle(url, sender: sender, asRelease: true)
            },
            Command(id: "interop.debug-answer", title: "Answer a Link Prompt (Debug)", symbol: "ladybug",
                    arguments: [CommandArgument(name: "sender", title: "Bundle id"),
                                CommandArgument(name: "answer", title: "Answer", allowedValues: ["allow", "block", "none"])],
                    allowedFromURL: true) { invocation in
                let bundleID = try invocation.require("sender")
                let answer: InteropLinkAppRecord.Decision? = switch try invocation.require("answer") {
                case "allow": .allowed
                case "block": .blocked
                default: nil
                }
                gate.prompter?.dismiss(bundleID: bundleID)
                gate.answer(answer, for: LinkSender(kind: .app, bundleID: bundleID, name: bundleID))
            },
            Command(id: "interop.debug-forget-links", title: "Forget Link Policy (Debug)", symbol: "ladybug",
                    allowedFromURL: true) { _ in
                gate.prompter?.closeAll()
                InteropSettings.resetLinkPolicy(in: context.settings)
                gate.clearRecent()
            },
            // The import preview in a plain window, for captures (the pane shows it as a sheet).
            Command(id: "interop.debug-import-window", title: "Show Import Preview in a Window (Debug)", symbol: "ladybug",
                    arguments: [CommandArgument(name: "path", title: "Path"),
                                CommandArgument(name: "appearance", title: "Appearance", isRequired: false, allowedValues: ["light", "dark"])],
                    allowedFromURL: true) { invocation in
                let url = try InteropCommands.backupURL(try invocation.require("path"), mustExist: true)
                let file = try await backups.read(url)
                let appearance = invocation.string("appearance").map { NSAppearance(named: $0 == "dark" ? .darkAqua : .aqua) } ?? nil
                InteropDebugWindow.shared.show(InteropPendingImport(url: url, file: file, preview: backups.preview(of: file)),
                                               backups: backups, appearance: appearance)
            },
            Command(id: "interop.debug-import-window-close", title: "Close Import Preview Window (Debug)", symbol: "ladybug",
                    allowedFromURL: true) { _ in
                InteropDebugWindow.shared.close()
            },
            Command(id: "interop.debug-dump", title: "Dump Interop State (Debug)", symbol: "ladybug", allowedFromURL: true) { _ in
                await backups.refreshLocalBackups()
                try DebugFiles.writeJSON(InteropDebugDump(context: context, gate: gate, backups: backups), name: "interop.json")
            },
            // `on=1 [label=Work]`, `off=1` or `unknown=1` sets the Focus state widgets read; any
            // call writes what `.focusState` answers to `debug/interop-focus.json`.
            Command(id: "interop.debug-focus", title: "Set Focus State (Debug)", symbol: "ladybug",
                    arguments: [CommandArgument(name: "on", title: "On", isRequired: false),
                                CommandArgument(name: "off", title: "Off", isRequired: false),
                                CommandArgument(name: "unknown", title: "Unknown", isRequired: false),
                                CommandArgument(name: "label", title: "Label", isRequired: false)],
                    allowedFromURL: true) { invocation in
                let state = context.services[.focusState]
                if let own = state as? InteropFocusState {
                    if invocation.string("on") == "1" {
                        own.debugSet(isFocused: true, label: invocation.string("label"))
                    } else if invocation.string("off") == "1" {
                        own.debugSet(isFocused: false, label: nil)
                    } else if invocation.string("unknown") == "1" {
                        own.debugSet(isFocused: nil, label: nil)
                    }
                }
                try DebugFiles.writeJSON(InteropFocusDump(isFocused: state.isFocused, label: state.label, sourceNote: state.sourceNote,
                                                          provider: String(describing: type(of: state))), name: "interop-focus.json")
            },
        ]
    }

    struct InteropFocusDump: Encodable {
        let isFocused: Bool?
        let label: String?
        let sourceNote: String
        let provider: String
    }
}

/// Hosts the import sheet in a titled window the size a sheet would get.
final class InteropDebugWindow {
    static let shared = InteropDebugWindow()
    private var window: NSWindow?

    func show(_ pending: InteropPendingImport, backups: InteropBackupController, appearance: NSAppearance?) {
        close()
        let controller = NSHostingController(rootView: InteropImportSheet(pending: pending, backups: backups) { [weak self] _ in
            self?.close()
        })
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.title = "Import preview (Debug)"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.setFrameTopLeftPoint(NSPoint(x: 120, y: (NSScreen.screens.first?.frame.maxY ?? 900) - 90))
        window.orderFrontRegardless()
        self.window = window
    }

    func close() {
        window?.close()
        window = nil
    }
}

struct InteropDebugDump: Encodable {
    struct Backup: Encodable {
        let file: String
        let createdAt: Date
        let reason: String
    }
    let writtenAt: Date
    let linksEnabled: Bool
    let allowUnknownSenders: Bool
    let allowSettingsCommands: Bool
    let apps: [InteropLinkAppRecord]
    let pendingApps: [String]
    let recent: [InteropLinkLogEntry]
    let aliasHosts: [String]
    let backupDirectory: String
    let localBackups: [Backup]
    let participants: [String]
    let reservedSettingsKeys: [String]

    init(context: AppContext, gate: InteropLinkGate, backups: InteropBackupController) {
        let settings = context.settings
        writtenAt = Date()
        linksEnabled = settings[InteropSettings.linksEnabled]
        allowUnknownSenders = settings[InteropSettings.allowUnknownSenders]
        allowSettingsCommands = settings[InteropSettings.allowSettingsCommands]
        apps = settings[InteropSettings.linkApps]
        pendingApps = gate.pending.keys.sorted()
        recent = gate.recent
        aliasHosts = InteropLinkRoutes.aliasHosts
        backupDirectory = backups.directory.path
        localBackups = backups.localBackups.map { Backup(file: $0.url.lastPathComponent, createdAt: $0.createdAt, reason: $0.reason) }
        participants = context.services[.backupParticipants].participants.map(\.backupID)
        reservedSettingsKeys = backups.reservedSettingsKeys.sorted()
    }
}
#endif
