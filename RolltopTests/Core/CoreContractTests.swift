import Foundation
import RolltopCore
import Testing
@testable import Rolltop

@Suite struct URLRouterTests {
    @Test func parsesCommandURLs() throws {
        let route = try #require(URLRouter.parse(URL(string: "rolltop://command/layout.set-section?owner=com.foo&section=hidden")!))
        #expect(route.command == .setSection)
        #expect(route.arguments == ["owner": "com.foo", "section": "hidden"])
        #expect(URLRouter.parse(URL(string: "rolltop://command/visibility.collapse")!)?.command == .collapse)
    }

    @Test func rejectsOtherShapes() {
        #expect(URLRouter.parse(URL(string: "rolltop://profile/work")!) == nil)
        #expect(URLRouter.parse(URL(string: "rolltop://command/")!) == nil)
        #expect(URLRouter.parse(URL(string: "rolltop://command/a/b")!) == nil)
        #expect(URLRouter.parse(URL(string: "other://command/visibility.collapse")!) == nil)
    }
}

@Suite struct CommandRegistryTests {
    private func registry(_ ran: @escaping (CommandInvocation) -> Void) -> CommandRegistry {
        let registry = CommandRegistry()
        registry.register(Command(id: "test.url-ok", title: "OK", symbol: "circle",
                                  arguments: [CommandArgument(name: "mode", title: "Mode", allowedValues: ["a", "b"])],
                                  allowedFromURL: true, effect: .display) { ran($0) })
        registry.register(Command(id: "test.internal", title: "Internal", symbol: "circle") { ran($0) })
        return registry
    }

    @Test func runsWithArgumentsAndSource() async throws {
        var seen: CommandInvocation?
        try await registry { seen = $0 }.run("test.url-ok", arguments: ["mode": "a"], source: .url)
        #expect(seen?.arguments == ["mode": "a"])
        #expect(seen?.source == .url)
    }

    @Test func refusesWhatIsNotAllowed() async {
        let commands = registry { _ in }
        await #expect(throws: CommandError.notAllowed("test.internal", .url)) {
            try await commands.run("test.internal", source: .url)
        }
        await #expect(throws: CommandError.unknownCommand("test.missing")) {
            try await commands.run("test.missing")
        }
        await #expect(throws: CommandError.missingArgument("mode")) {
            try await commands.run("test.url-ok", source: .url)
        }
        await #expect(throws: CommandError.invalidArgument("mode", "z")) {
            try await commands.run("test.url-ok", arguments: ["mode": "z"])
        }
    }

    @Test func replacesSameID() {
        let commands = registry { _ in }
        commands.register(Command(id: "test.internal", title: "Again", symbol: "square") { _ in })
        #expect(commands.commands.count == 2)
        #expect(commands.command("test.internal")?.symbol == "square")
    }
}

@Suite struct SettingsStoreTests {
    @Test func typedValuesRoundTrip() throws {
        let suite = "com.alphapengwang.rolltop.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let flag = SettingsKey<Bool>("rolltop.test.flag", default: false)
        let layoutKey = SettingsKey<Layout>("rolltop.test.layout", default: .empty)
        #expect(store[flag] == false)
        store[flag] = true
        #expect(store[flag] == true)
        #expect(defaults.object(forKey: "rolltop.test.flag") as? Bool == true)
        let layout = Layout(sections: [.app("com.foo"): .hidden], defaultSection: .shown)
        store[layoutKey] = layout
        #expect(store[layoutKey] == layout)
        #expect(store.exportAll().keys.sorted() == ["rolltop.test.flag", "rolltop.test.layout"])
    }
}

@Suite struct GeometryTests {
    @Test func conversionsAreInverse() {
        let rect = CGRect(x: 100, y: 0, width: 30, height: 24)
        #expect(ScreenGeometry.topLeftRect(fromAppKit: ScreenGeometry.appKitRect(fromTopLeft: rect)) == rect)
    }

    @Test func featureRegistryListsEveryPlannedFeature() {
        let ids = FeatureRegistry.all.map { $0.id.rawValue }
        #expect(ids.count == 17)
        #expect(Set(ids).count == ids.count)
        // Round 2 providers start before the features that consume them.
        let media = ids.firstIndex(of: "media"), weather = ids.firstIndex(of: "weather")
        let customItems = ids.firstIndex(of: "custom-items")
        #expect(media != nil && weather != nil && customItems != nil)
        if let media, let weather, let customItems { #expect(media < customItems && weather < customItems) }
    }
}

@Suite struct TransientSettingsTests {
    private let flag = SettingsKey<Bool>("rolltop.test.flag", default: false)
    private let state = SettingsKey<String>("rolltop.test.runtime-state", default: "")

    @Test func exportAndReplaceLeaveTransientKeysAlone() throws {
        let defaults = try #require(UserDefaults(suiteName: "com.alphapengwang.rolltop.tests.\(UUID().uuidString)"))
        let store = SettingsStore(defaults: defaults)
        store.markTransient(state)
        store[flag] = true
        store[state] = "running"
        #expect(store.exportAll().keys.sorted() == ["rolltop.test.flag"])

        store.replaceAll(with: ["rolltop.test.flag": false, "rolltop.test.runtime-state": "imported"])
        #expect(store[flag] == false)
        #expect(store[state] == "running")

        store.replaceAll(with: [:])
        #expect(!store.hasValue(for: flag))
        #expect(store[state] == "running")
    }

    @Test func featuresMarkTheirRuntimeState() throws {
        let context = try TestContext.make()
        _ = FeatureRegistry.all.map { $0.init(context: context) }
        for name in ["rolltop.automations.active-rules", "rolltop.automations.profile-ledger", "rolltop.settings-shell.last-pane",
                     "rolltop.onboarding.state", "rolltop.spacing.last-applied", "rolltop.capture.requested-access",
                     "rolltop.reveal.hide-everything"] {
            #expect(context.settings.isTransient(name), "\(name) should be transient")
        }
        #expect(!context.settings.isTransient("rolltop.layout"))
    }
}
