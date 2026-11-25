import Foundation
import RolltopCore
import Testing
@testable import Rolltop

/// Link parsing, command tiers, the sender policy, the rate limiter, and the gate.
@Suite struct InteropLinkPolicyTests {
    private let app = LinkSender(kind: .app, bundleID: "com.example.Launcher", name: "Launcher", pid: 42)
    private let tool = LinkSender(kind: .tool, path: "/usr/bin/open", pid: 43)

    private func decide(_ id: CommandID?, allows: Bool = true, effect: CommandEffect? = .display, sender: LinkSender,
                        settings: InteropLinkPolicySettings = .init(), debug: Bool = false, rate: Bool = true) -> InteropLinkDecision {
        InteropLinkPolicy.decide(InteropLinkRequest(command: id, commandAllowsLinks: allows, effect: effect, sender: sender),
                                 settings: settings, isDebugBuild: debug, rateAllowed: rate)
    }

    @Test func undeclaredEffectCountsAsDestructive() {
        let open = InteropLinkPolicySettings(allowSettingsCommands: true, apps: ["com.example.Launcher": .allowed])
        #expect(decide("future.command", effect: nil, sender: app, settings: open) == .refuse(.restricted))
        #expect(decide("future.command", effect: nil, sender: tool, debug: true) == .refuse(.restricted))
    }

    @Test func knownAllowedAppRunsDisplayCommands() {
        let settings = InteropLinkPolicySettings(apps: ["com.example.Launcher": .allowed])
        #expect(decide(.toggleHidden, sender: app, settings: settings) == .run)
    }

    @Test func unseenAppIsAskedOnce() {
        #expect(decide(.toggleHidden, sender: app) == .ask)
    }

    @Test func blockedAppIsRefused() {
        let settings = InteropLinkPolicySettings(apps: ["com.example.Launcher": .blocked])
        #expect(decide(.toggleHidden, sender: app, settings: settings) == .refuse(.blockedApp))
    }

    @Test func unknownSendersFollowTheirSwitch() {
        #expect(decide(.showHidden, sender: .unknown) == .run)
        #expect(decide(.showHidden, sender: tool) == .run)
        let off = InteropLinkPolicySettings(allowUnknownSenders: false)
        #expect(decide(.showHidden, sender: .unknown, settings: off) == .refuse(.unknownSenderOff))
        #expect(decide(.showHidden, sender: tool, settings: off) == .refuse(.unknownSenderOff))
    }

    @Test func restrictedCommandsNeverRunFromLinks() {
        let open = InteropLinkPolicySettings(allowSettingsCommands: true, apps: ["com.example.Launcher": .allowed])
        #expect(decide("capture.clear-cache", effect: .destructive, sender: app, settings: open) == .refuse(.restricted))
        #expect(decide("automations.resume-all", effect: .destructive, sender: .unknown, settings: open) == .refuse(.restricted))
        #expect(decide("profiles.delete", effect: .destructive, sender: LinkSender(kind: .rolltop), settings: open) == .refuse(.restricted),
                "not even Rolltop's own Test buttons")
        // Commands that do not allow URLs at all are refused first, also in Debug builds.
        #expect(decide("profiles.delete", allows: false, sender: tool, debug: true) == .refuse(.notAllowedFromLinks))
        #expect(decide("interop.import-backup", allows: false, sender: .unknown, debug: true) == .refuse(.notAllowedFromLinks))
        #expect(decide(nil, sender: tool) == .refuse(.unknownCommand))
    }

    @Test func settingsCommandsNeedTheirSwitch() {
        let allowed = InteropLinkPolicySettings(apps: ["com.example.Launcher": .allowed])
        #expect(decide(.setSection, effect: .changesSettings, sender: app, settings: allowed) == .refuse(.settingsCommandsOff))
        #expect(decide(.setSection, effect: .changesSettings, sender: .unknown) == .refuse(.settingsCommandsOff))
        var on = allowed
        on.allowSettingsCommands = true
        #expect(decide(.setSection, effect: .changesSettings, sender: app, settings: on) == .run)
    }

    @Test func linksOffRefusesEverythingButRolltop() {
        let off = InteropLinkPolicySettings(linksEnabled: false, apps: ["com.example.Launcher": .allowed])
        #expect(decide(.toggleHidden, sender: app, settings: off) == .refuse(.linksOff))
        #expect(decide(.toggleHidden, sender: LinkSender(kind: .rolltop), settings: off) == .run)
    }

    @Test func debugHooksOnlyFromAnonymousSendersInDebugBuilds() {
        let allowed = InteropLinkPolicySettings(apps: ["com.example.Launcher": .allowed])
        #expect(decide("profiles.debug-dump", sender: app, settings: allowed, debug: true) == .refuse(.testHook))
        #expect(decide("profiles.debug-dump", sender: tool, debug: true) == .run)
        #expect(decide("profiles.debug-dump", sender: tool, debug: false) == .refuse(.testHook))
        #expect(decide("profiles.debug-dump", effect: nil, sender: LinkSender(kind: .rolltop), debug: true) == .run)
        // Debug builds: scripts keep every URL-allowed command but destructive ones, without
        // the settings switch or rate limit.
        #expect(decide("capture.clear-cache", effect: .destructive, sender: .unknown, debug: true, rate: false) == .refuse(.restricted))
        #expect(decide(.setSection, effect: .changesSettings, sender: tool, debug: true, rate: false) == .run)
    }

    @Test func rateLimitedLinksAreRefused() {
        let allowed = InteropLinkPolicySettings(apps: ["com.example.Launcher": .allowed])
        #expect(decide(.toggleHidden, sender: app, settings: allowed, rate: false) == .refuse(.rateLimited))
        #expect(decide(.toggleHidden, sender: .unknown, rate: false) == .refuse(.rateLimited))
        #expect(decide(.toggleHidden, sender: app, rate: false) == .refuse(.rateLimited), "no prompt for a flood")
    }

    @Test func rateLimiterAllowsABurstThenRefills() {
        var limiter = InteropRateLimiter(capacity: 10, refillPerSecond: 2)
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let burst = (0..<15).map { _ in limiter.allow("a", now: start) }
        #expect(burst.filter { $0 }.count == 10)
        let other = limiter.allow("b", now: start)
        #expect(other, "buckets are per sender")
        let tooSoon = limiter.allow("a", now: start.addingTimeInterval(0.2))
        #expect(!tooSoon)
        let refilled = limiter.allow("a", now: start.addingTimeInterval(0.6))
        #expect(refilled)
    }

    @Test func aliasesParse() {
        func target(_ string: String, palette: CommandID? = nil) -> InteropLinkTarget {
            InteropLinkRoutes.target(of: URL(string: string)!, paletteCommand: palette, routeHosts: ["shelf"])
        }
        #expect(target("rolltop://toggle") == .command(.toggleHidden, [:]))
        #expect(target("rolltop://show") == .command(.showHidden, [:]))
        #expect(target("rolltop://show-all") == .command(.showAll, [:]))
        #expect(target("rolltop://hide") == .command(.collapse, [:]))
        #expect(target("rolltop://profile/work") == .command("profiles.apply", ["id": "work"]))
        #expect(target("rolltop://item/com.example.App?button=right") == .command(.activateItem, ["owner": "com.example.App", "button": "right"]))
        #expect(target("rolltop://item/system:wifi") == .command(.activateItem, ["owner": "system:wifi"]))
        #expect(target("rolltop://settings/backup") == .command(.openSettings, ["pane": "backup"]))
        #expect(target("rolltop://settings") == .command(.openSettings, [:]))
        #expect(target("rolltop://search") == .unavailable("search"))
        #expect(target("rolltop://search", palette: "command-palette.toggle") == .command("command-palette.toggle", [:]))
        #expect(target("rolltop://command/layout.set-section?owner=a&section=hidden")
                == .command(.setSection, ["owner": "a", "section": "hidden"]))
        #expect(target("rolltop://SHELF/x") == .route("shelf"))
        #expect(target("rolltop://profile") == .invalid)
        #expect(target("rolltop://nope") == .invalid)
        #expect(target("https://toggle") == .invalid)
        #expect(InteropLinkRoutes.paletteCommand(in: ["command-palette.show", "command-palette.toggle"]) == nil)
        #expect(InteropLinkRoutes.paletteCommand(in: ["palette.debug-query", "palette.clear-history", "palette.show", "palette.toggle"])
                == "palette.show")
    }

    @Test func runCommandArgumentsParse() throws {
        #expect(try InteropActions.arguments(from: ["owner=com.foo", " button=right", "", "q=a=b"]) == ["owner": "com.foo", "button": "right", "q": "a=b"])
        #expect(throws: InteropActionError.self) { try InteropActions.arguments(from: ["nope"]) }
    }
}

/// The gate on a test context: decisions, the queue while asking, the app list, the log.
@MainActor
@Suite struct InteropLinkGateTests {
    private func makeGate() throws -> (AppContext, InteropLinkGate, () -> [String]) {
        let context = try TestContext.make()
        InteropSettings.markTransient(in: context.settings)
        let ran = InteropTestLog()
        for (id, effect) in [("visibility.show-hidden", CommandEffect.display), ("capture.clear-cache", .destructive)] {
            context.commands.unregister(CommandID(id))
            context.commands.register(Command(id: CommandID(id), title: "Test", symbol: "x", allowedFromURL: true,
                                              effect: effect) { _ in ran.entries.append(id) })
        }
        let gate = InteropLinkGate(context: context)
        return (context, gate, { ran.entries })
    }

    @Test func askingQueuesLinksAndAllowRunsThem() async throws {
        let (context, gate, ran) = try makeGate()
        let app = LinkSender(kind: .app, bundleID: "com.example.Launcher", name: "Launcher")
        gate.handle(URL(string: "rolltop://show")!, sender: app, asRelease: true)
        gate.handle(URL(string: "rolltop://show")!, sender: app, asRelease: true)
        #expect(gate.pending["com.example.Launcher"]?.count == 2)
        #expect(gate.recent.first?.outcome == .asked)
        gate.answer(.allowed, for: app)
        try await Task.sleep(for: .milliseconds(50))
        #expect(ran() == ["visibility.show-hidden", "visibility.show-hidden"])
        #expect(context.settings[InteropSettings.linkApps].map(\.decision) == [.allowed])
        gate.handle(URL(string: "rolltop://show")!, sender: app, asRelease: true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(ran().count == 3, "an allowed app is not asked again")
    }

    @Test func promptPanelHasItsContentSize() {
        let panel = InteropLinkPrompter.makePanel(sender: LinkSender(kind: .app, bundleID: "com.example.A", name: "Example"),
                                                  commandTitle: "Toggle Hidden Items", onAllow: {}, onBlock: {})
        let content = panel.contentView?.fittingSize ?? .zero
        #expect(content.width >= 380 && content.height > 100, "content measures \(content)")
        #expect(panel.frame.height >= content.height)
        #expect(!panel.isVisible)
    }

    @Test func answerKeepsTheNameTheAppAskedWith() throws {
        let (context, gate, _) = try makeGate()
        gate.handle(URL(string: "rolltop://show")!, sender: LinkSender(kind: .app, bundleID: "com.example.N", name: "Nice Name"),
                    asRelease: true)
        gate.answer(.allowed, for: LinkSender(kind: .app, bundleID: "com.example.N"))
        #expect(context.settings[InteropSettings.linkApps].first?.name == "Nice Name")
    }

    @Test func blockingDropsQueuedLinksAndRemembers() async throws {
        let (context, gate, ran) = try makeGate()
        let app = LinkSender(kind: .app, bundleID: "com.example.Spammer", name: "Spammer")
        gate.handle(URL(string: "rolltop://show")!, sender: app, asRelease: true)
        gate.answer(.blocked, for: app)
        gate.handle(URL(string: "rolltop://show")!, sender: app, asRelease: true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(ran().isEmpty)
        #expect(context.settings[InteropSettings.linkApps].first?.decision == .blocked)
        #expect(gate.recent.first?.reason == InteropLinkRefusal.blockedApp.rawValue)
        gate.forget(bundleID: "com.example.Spammer")
        #expect(context.settings[InteropSettings.linkApps].isEmpty)
    }

    @Test func restrictedLinkIsRefusedAndLogged() throws {
        let (_, gate, ran) = try makeGate()
        gate.handle(URL(string: "rolltop://command/profiles.delete?id=work")!, sender: .unknown, asRelease: true)
        gate.handle(URL(string: "rolltop://command/capture.clear-cache")!, sender: .unknown, asRelease: true)
        gate.handle(URL(string: "rolltop://command/layout.set-default-section?section=hidden")!, sender: .unknown, asRelease: true)
        #expect(ran().isEmpty)
        #expect(gate.recent.map(\.outcome) == [.refused, .refused, .refused])
        #expect(gate.recent.map(\.reason) == [InteropLinkRefusal.settingsCommandsOff.rawValue, InteropLinkRefusal.restricted.rawValue,
                                               InteropLinkRefusal.unknownCommand.rawValue])
    }

    @Test func floodIsRateLimited() throws {
        let (_, gate, _) = try makeGate()
        for _ in 0..<25 { gate.handle(URL(string: "rolltop://show")!, sender: .unknown, asRelease: true) }
        let refused = gate.recent.filter { $0.reason == InteropLinkRefusal.rateLimited.rawValue }.count
        #expect(refused == 15)
    }
}

/// Records what fake commands did.
@MainActor
final class InteropTestLog {
    var entries: [String] = []
}
