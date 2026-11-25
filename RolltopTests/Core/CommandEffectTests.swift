import Foundation
import RolltopCore
import Testing
@testable import Rolltop

/// `Command.effect`: every command declares what it can change, and every consumer (links,
/// Shortcuts' and AppleScript's generic run command, automations, custom items, the
/// palette) decides by it. Docs: CONTRACTS.md, "Commands".
@MainActor
@Suite struct CommandEffectTests {
    /// Every non-Debug command of the core and of every feature, including the commands
    /// Profiles and Automations register again once they know their profiles and rules.
    private func allCommands() throws -> [Command] {
        let context = try TestContext.make()
        let features = FeatureRegistry.all.map { $0.init(context: context) }
        var commands = context.commands.commands
        for feature in features { commands += feature.commands }
        // Registered only once start() knows the profiles.
        if let profiles = features.compactMap({ $0 as? ProfilesFeature }).first {
            commands += ProfilesFeature.slotCommands(controller: profiles.controller, profiles: [], showInMenu: false)
        }
        return commands.filter { !$0.id.isDebugOnly }
    }

    @Test func everyCommandDeclaresItsEffect() throws {
        let undeclared = try allCommands().filter { $0.effect == nil }.map(\.id.rawValue)
        #expect(undeclared.isEmpty, "commands without an effect: \(undeclared)")
    }

    /// At least as strict as the link tiers before effects existed (restricted → destructive,
    /// settings → changes settings), except the commands the integration named as display.
    @Test func effectsOfKnownCommands() throws {
        let effects = Dictionary(try allCommands().map { ($0.id.rawValue, $0.resolvedEffect) }, uniquingKeysWith: { $1 })
        let display = ["visibility.toggle-hidden", "visibility.toggle-all", "visibility.show-hidden", "visibility.show-all",
                       "visibility.collapse", "item.activate", "app.settings", "app.quit", "profiles.apply", "profiles.next",
                       "profiles.previous", "profiles.apply-1", "reveal.keep-revealed", "reveal.toggle-hide-everything",
                       "palette.toggle", "palette.show", "shelf.toggle", "shelf.show", "custom-items.open-group",
                       "onboarding.allow-accessibility"]
        let settings = ["layout.set-section", "layout.set-default-section", "app.toggle-menu-bar-icon",
                        "appearance.toggle", "appearance.apply-preset",
                        "spacing.apply-preset", "automations.pause-all", "reveal.toggle-make-room", "profiles.save-current",
                        "custom-items.toggle", "custom-items.refresh-widget", "shelf.pause-clipboard"]
        let destructive = ["profiles.delete", "capture.clear-cache", "automations.toggle-rule", "automations.resume-all",
                           "interop.export-backup", "interop.import-backup", "palette.clear-history", "shelf.clear-clipboard"]
        for id in display { #expect(effects[id] == .display, "\(id)") }
        for id in settings { #expect(effects[id] == .changesSettings, "\(id)") }
        for id in destructive { #expect(effects[id] == .destructive, "\(id)") }
    }

    @Test func policyKeepsDestructiveCommandsAwayFromExternalSources() {
        for source in [CommandSource.url, .shortcuts, .appleScript, .automation, .customItem] {
            #expect(!CommandEffectPolicy.allows(.destructive, from: source), "\(source)")
            #expect(CommandEffectPolicy.allows(.changesSettings, from: source), "\(source)")
        }
        for source in [CommandSource.statusMenu, .hotkey, .palette, .internal] {
            #expect(CommandEffectPolicy.allows(.destructive, from: source), "\(source)")
        }
    }

    @Test func registryRefusesDestructiveAndUndeclaredFromExternalSources() async throws {
        let registry = CommandRegistry()
        var ran: [String] = []
        registry.register(Command(id: "test.wipe", title: "Wipe", symbol: "trash", allowedFromURL: true,
                                  effect: .destructive) { ran.append("wipe \($0.source.rawValue)") })
        registry.register(Command(id: "test.future", title: "Future", symbol: "circle", allowedFromURL: true) { _ in ran.append("future") })
        registry.register(Command(id: "test.debug-wipe", title: "Debug", symbol: "ladybug", allowedFromURL: true) { _ in ran.append("debug") })
        await #expect(throws: CommandError.notAllowed("test.wipe", .automation)) {
            try await registry.run("test.wipe", source: .automation)
        }
        await #expect(throws: CommandError.notAllowed("test.wipe", .customItem)) {
            try await registry.run("test.wipe", source: .customItem)
        }
        await #expect(throws: CommandError.notAllowed("test.future", .url)) {
            try await registry.run("test.future", source: .url)
        }
        try await registry.run("test.wipe", source: .palette)
        try await registry.run("test.debug-wipe", source: .url)
        #expect(ran == ["wipe palette", "debug"])
    }
}
