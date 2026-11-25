import Foundation
import RolltopCore
import Testing
@testable import Rolltop

/// Fresh, isolated settings + layout + profile folder for one test.
@MainActor
private struct ProfilesHarness {
    let defaults: UserDefaults
    let settings: SettingsStore
    let layout: LayoutStore
    let directory: URL
    let store: ProfileFileStore
    let controller: ProfilesController

    init() throws {
        let suite = "com.alphapengwang.rolltop.tests.profiles.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        settings = SettingsStore(defaults: defaults)
        layout = LayoutStore(settings: settings)
        directory = FileManager.default.temporaryDirectory.appending(path: "RolltopProfilesTests-\(UUID().uuidString)")
        store = ProfileFileStore(directory: directory)
        controller = ProfilesController(settings: settings, layout: layout, store: store)
        controller.load()
    }

    /// A second controller reading the same folder, as after a relaunch.
    func relaunched() -> ProfilesController {
        store.flush()
        let again = ProfilesController(settings: settings, layout: layout, store: ProfileFileStore(directory: directory))
        again.load()
        return again
    }

    func cleanUp() {
        store.flush()
        try? FileManager.default.removeItem(at: directory)
    }
}

private let fixtureA = OwnerID.app("com.example.a")
private let fixtureB = OwnerID.app("com.example.b")

@Suite struct ProfileSettingValueTests {
    @Test func roundTripsEveryPropertyListType() throws {
        let date = Date(timeIntervalSinceReferenceDate: 812_345_678.25)
        let plist: [String: Any] = [
            "rolltop.appearance.flag": true,
            "rolltop.appearance.count": 3,
            "rolltop.appearance.scale": 1.5,
            "rolltop.appearance.name": "glass",
            "rolltop.appearance.when": date,
            "rolltop.appearance.blob": Data([0, 1, 2, 255]),
            "rolltop.appearance.list": [1, "two", false] as [Any],
            "rolltop.appearance.map": ["a": 1, "b": ["c": "d"]] as [String: Any],
        ]
        let captured = ProfileSettingsSnapshot.capture(from: plist, prefixes: ["rolltop.appearance."])
        #expect(captured.count == plist.count)
        #expect(captured["rolltop.appearance.flag"] == .bool(true))
        #expect(captured["rolltop.appearance.count"] == .int(3))
        #expect(captured["rolltop.appearance.scale"] == .double(1.5))
        #expect(captured["rolltop.appearance.when"] == .date(date))

        let json = try JSONEncoder().encode(captured)
        let decoded = try JSONDecoder().decode([String: ProfileSettingValue].self, from: json)
        #expect(decoded == captured)
        #expect(ProfileSettingsSnapshot.matches(current: plist, snapshot: decoded, prefixes: ["rolltop.appearance."]))
    }

    @Test func changesStayInsideThePrefixes() {
        let current = ["rolltop.appearance.a", "rolltop.appearance.b", "rolltop.layout", "rolltop.reveal.delay"]
        let snapshot: [String: ProfileSettingValue] = ["rolltop.appearance.a": .int(1), "rolltop.reveal.delay": .int(9)]
        let changes = ProfileSettingsSnapshot.changes(currentKeys: current, snapshot: snapshot, prefixes: ["rolltop.appearance."])
        #expect(changes.remove == ["rolltop.appearance.b"])
        #expect(changes.set == ["rolltop.appearance.a": .int(1)])
    }

    @Test func comparesNumbersByValue() {
        let snapshot: [String: ProfileSettingValue] = ["rolltop.appearance.x": .int(1)]
        #expect(ProfileSettingsSnapshot.matches(current: ["rolltop.appearance.x": 1.0], snapshot: snapshot, prefixes: ["rolltop.appearance."]))
        #expect(!ProfileSettingsSnapshot.matches(current: ["rolltop.appearance.x": 2], snapshot: snapshot, prefixes: ["rolltop.appearance."]))
        #expect(!ProfileSettingsSnapshot.matches(current: [:], snapshot: snapshot, prefixes: ["rolltop.appearance."]))
    }
}

@Suite struct ProfileDisplayRuleTests {
    private let builtIn = ProfileDisplay(id: "BUILTIN", name: "Built-in Display", isBuiltIn: true)
    private let lg = ProfileDisplay(id: "LG", name: "LG UltraFine", isBuiltIn: false)
    private let dell = ProfileDisplay(id: "DELL", name: "Dell", isBuiltIn: false)

    private func profile(_ id: String, _ rule: ProfileDisplayRule?) -> RolltopProfile {
        RolltopProfile(id: id, name: id, layout: .empty, displayRule: rule)
    }

    @Test func matchesEachKind() {
        let laptop = ProfileDisplayConfiguration(displays: [builtIn])
        let desk = ProfileDisplayConfiguration(displays: [lg, builtIn])
        let closedLid = ProfileDisplayConfiguration(displays: [lg])
        #expect(ProfileDisplayRule.builtInOnly.matches(laptop))
        #expect(!ProfileDisplayRule.builtInOnly.matches(desk))
        #expect(!ProfileDisplayRule.externalConnected.matches(laptop))
        #expect(ProfileDisplayRule.externalConnected.matches(desk))
        #expect(ProfileDisplayRule.externalConnected.matches(closedLid))
        // Exact set, order-independent, names ignored.
        #expect(ProfileDisplayRule.displays([ProfileDisplay(id: "BUILTIN", name: "x", isBuiltIn: true), lg]).matches(desk))
        #expect(!ProfileDisplayRule.displays([lg]).matches(desk))
        #expect(!ProfileDisplayRule.displays([]).matches(ProfileDisplayConfiguration(displays: [])))
    }

    @Test func mostSpecificRuleWinsThenListOrder() {
        let profiles = [profile("any-external", .externalConnected), profile("none", nil),
                        profile("desk", .displays([builtIn, lg])), profile("desk-2", .displays([lg, builtIn])),
                        profile("mobile", .builtInOnly)]
        #expect(ProfileDisplayRule.bestMatch(in: profiles, for: .init(displays: [builtIn, lg]))?.id == "desk")
        #expect(ProfileDisplayRule.bestMatch(in: profiles, for: .init(displays: [builtIn, dell]))?.id == "any-external")
        #expect(ProfileDisplayRule.bestMatch(in: profiles, for: .init(displays: [builtIn]))?.id == "mobile")
        #expect(ProfileDisplayRule.bestMatch(in: [profile("none", nil)], for: .init(displays: [builtIn])) == nil)
    }
}

@Suite struct ProfileNamingTests {
    @Test func makesURLSafeUniqueIDs() {
        #expect(ProfileNaming.makeID(for: "Work", existing: []) == "work")
        #expect(ProfileNaming.makeID(for: "Screen Sharing!", existing: []) == "screen-sharing")
        #expect(ProfileNaming.makeID(for: "Café Zürich", existing: []) == "cafe-zurich")
        #expect(ProfileNaming.makeID(for: "Work", existing: ["work", "work-2"]) == "work-3")
        #expect(ProfileNaming.makeID(for: "工作", existing: []) == "profile")
        #expect(ProfileNaming.makeID(for: "index", existing: []) == "profile")
        #expect(ProfileNaming.isValidID("work-2"))
        #expect(!ProfileNaming.isValidID("../x"))
        #expect(!ProfileNaming.isValidID("index"))
    }

    @Test func makesUniqueNames() {
        #expect(ProfileNaming.uniqueName("Work", existing: ["Home"]) == "Work")
        #expect(ProfileNaming.uniqueName("work", existing: ["Work", "work 2"]) == "work 3")
    }

    @Test func cyclesThroughProfiles() {
        let order = ["a", "b", "c"]
        #expect(ProfileNaming.neighbor(of: "b", in: order, step: 1) == "c")
        #expect(ProfileNaming.neighbor(of: "c", in: order, step: 1) == "a")
        #expect(ProfileNaming.neighbor(of: "a", in: order, step: -1) == "c")
        #expect(ProfileNaming.neighbor(of: nil, in: order, step: 1) == "a")
        #expect(ProfileNaming.neighbor(of: "gone", in: order, step: -1) == "c")
        #expect(ProfileNaming.neighbor(of: nil, in: [], step: 1) == nil)
    }
}

@Suite struct ProfileCodingTests {
    @Test func decodingIsTolerant() throws {
        let json = """
        {"id":"ignored","name":"Desk","symbol":"desktopcomputer","futureField":{"x":1},
         "layout":{"sections":{"com.example.a":"hidden","system:wifi":"shown","not valid":"hidden"},"defaultSection":"shown"},
         "settingsPrefixes":["rolltop.appearance.","bogus"],
         "settings":{"rolltop.appearance.n":{"int":2},"rolltop.appearance.bad":{"mystery":1}},
         "displayRule":{"kind":"something-new"}}
        """
        let profile = try JSONDecoder().decode(RolltopProfile.self, from: Data(json.utf8))
        #expect(profile.name == "Desk")
        #expect(profile.layout.section(for: fixtureA) == .hidden)
        #expect(profile.layout.sections.count == 2)
        #expect(profile.settingsPrefixes == ["rolltop.appearance."])
        #expect(profile.settings == ["rolltop.appearance.n": .int(2)])
        #expect(profile.displayRule == nil)
        #expect(!profile.applyAtLaunch)

        let minimal = try JSONDecoder().decode(RolltopProfile.self, from: Data("{}".utf8))
        #expect(minimal.layout == .empty)
        #expect(minimal.symbol == RolltopProfile.defaultSymbol)
    }

    @Test func roundTrips() throws {
        let profile = RolltopProfile(id: "desk", name: "Desk", symbol: "desktopcomputer",
                                  layout: Layout(sections: [fixtureA: .hidden], defaultSection: .hidden),
                                  settingsPrefixes: ["rolltop.appearance."], settings: ["rolltop.appearance.n": .double(0.5)],
                                  applyAtLaunch: true,
                                  displayRule: .displays([ProfileDisplay(id: "LG", name: "LG", isBuiltIn: false)]),
                                  createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_100))
        let data = try ProfileFileStore.encoder().encode(profile)
        #expect(try ProfileFileStore.decoder().decode(RolltopProfile.self, from: data) == profile)
    }
}

@MainActor
@Suite struct ProfileStoreTests {
    @Test func persistsOrderAndActiveAcrossRelaunch() throws {
        let harness = try ProfilesHarness()
        defer { harness.cleanUp() }
        harness.layout.setSection(.hidden, for: fixtureA)
        let p1 = harness.controller.saveCurrent(name: "p1")
        harness.layout.setSection(.hidden, for: fixtureB)
        let p2 = harness.controller.saveCurrent(name: "p2")
        harness.controller.move(id: p2.id, by: -1)
        try harness.controller.applyProfile(id: p1.id)

        let again = harness.relaunched()
        #expect(again.all.map(\.id) == ["p2", "p1"])
        #expect(again.activeProfileID == "p1")
        #expect(again.profile(id: "p2")?.layout.section(for: fixtureB) == .hidden)
    }

    @Test func toleratesStrayAndBrokenFiles() throws {
        let harness = try ProfilesHarness()
        defer { harness.cleanUp() }
        harness.controller.saveCurrent(name: "Kept")
        harness.store.flush()
        try Data("not json".utf8).write(to: harness.directory.appending(path: "broken.json"))
        try Data("{\"name\":\"Hand made\"}".utf8).write(to: harness.directory.appending(path: "hand-made.json"))
        try Data("{\"name\":\"Bad id\"}".utf8).write(to: harness.directory.appending(path: "Bad ID.json"))
        let again = harness.relaunched()
        #expect(again.all.map(\.id) == ["kept", "hand-made"])
        #expect(again.profile(id: "hand-made")?.name == "Hand made")
    }

    @Test func deletingRemovesTheFile() throws {
        let harness = try ProfilesHarness()
        defer { harness.cleanUp() }
        let profile = harness.controller.saveCurrent(name: "Gone soon")
        harness.store.flush()
        let file = harness.directory.appending(path: "\(profile.id).json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        harness.controller.delete(id: profile.id)
        harness.store.flush()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(harness.controller.activeProfileID == nil)
    }
}

@MainActor
@Suite struct ProfilesControllerTests {
    @Test func applyReplacesLayoutAndTracksModification() throws {
        let harness = try ProfilesHarness()
        defer { harness.cleanUp() }
        let controller = harness.controller
        harness.layout.setSection(.hidden, for: fixtureA)
        harness.layout.setSection(.shown, for: fixtureB)
        let p1 = controller.saveCurrent(name: "p1")
        harness.layout.replace(with: Layout(sections: [fixtureA: .shown, fixtureB: .hidden]))
        let p2 = controller.saveCurrent(name: "p2")

        try controller.applyProfile(id: p1.id)
        #expect(harness.layout.layout.section(for: fixtureA) == .hidden)
        #expect(harness.layout.layout.section(for: fixtureB) == .shown)
        #expect(controller.activeProfileID == p1.id)
        #expect(!controller.isActiveModified)

        harness.layout.setSection(.alwaysHidden, for: fixtureB)
        #expect(controller.isActiveModified)
        controller.revertActive()
        #expect(!controller.isActiveModified)
        #expect(harness.layout.layout.section(for: fixtureB) == .shown)

        harness.layout.setSection(.alwaysHidden, for: fixtureB)
        controller.updateFromCurrent(id: p1.id)
        #expect(!controller.isActiveModified)
        #expect(controller.profile(id: p1.id)?.layout.section(for: fixtureB) == .alwaysHidden)

        try controller.applyNeighbor(step: 1)
        #expect(controller.activeProfileID == p2.id)
        #expect(throws: ProfileFileError.unknownProfile("nope")) { try controller.applyProfile(id: "nope") }
    }

    @Test func includedSettingsApplyOnlyTheirPrefix() throws {
        let harness = try ProfilesHarness()
        defer { harness.cleanUp() }
        let controller = harness.controller
        harness.defaults.set("glass", forKey: "rolltop.appearance.style")
        harness.defaults.set(4, forKey: "rolltop.appearance.radius")
        harness.defaults.set(0.7, forKey: "rolltop.reveal.delay")
        let profile = controller.saveCurrent(name: "Glass", including: [.appearance])
        #expect(profile.settings.keys.sorted() == ["rolltop.appearance.radius", "rolltop.appearance.style"])

        harness.defaults.set("solid", forKey: "rolltop.appearance.style")
        harness.defaults.set(true, forKey: "rolltop.appearance.border")
        harness.defaults.set(1.5, forKey: "rolltop.reveal.delay")
        harness.layout.setSection(.hidden, for: fixtureA)
        #expect(controller.isActiveModified)

        try controller.applyProfile(id: profile.id)
        #expect(harness.defaults.string(forKey: "rolltop.appearance.style") == "glass")
        #expect(harness.defaults.integer(forKey: "rolltop.appearance.radius") == 4)
        #expect(harness.defaults.object(forKey: "rolltop.appearance.border") == nil)
        #expect(harness.defaults.double(forKey: "rolltop.reveal.delay") == 1.5)
        #expect(harness.layout.layout == .empty)
        #expect(!controller.isActiveModified)

        // Dropping a group forgets its values; adding one captures the current values.
        controller.setIncluded(.appearance, false, id: profile.id)
        #expect(controller.profile(id: profile.id)?.settings.isEmpty == true)
        harness.defaults.set(true, forKey: "rolltop.secondary-bar.enabled")
        controller.setIncluded(.secondaryBar, true, id: profile.id)
        #expect(controller.profile(id: profile.id)?.settings == ["rolltop.secondary-bar.enabled": .bool(true)])
    }

    @Test func exportImportRoundTripMintsFreshIdentity() throws {
        let harness = try ProfilesHarness()
        defer { harness.cleanUp() }
        let controller = harness.controller
        harness.layout.setSection(.hidden, for: fixtureA)
        var original = controller.saveCurrent(name: "Desk", symbol: "desktopcomputer")
        original.applyAtLaunch = true
        original.displayRule = .externalConnected
        controller.update(original)
        let data = try controller.exportData(id: original.id)

        let imported = try controller.importData(data)
        #expect(imported.id == "desk-2")
        #expect(imported.name == "Desk 2")
        #expect(!imported.applyAtLaunch)
        #expect(imported.displayRule == .externalConnected)
        #expect(imported.layout == controller.profile(id: original.id)?.layout)
        #expect(imported.symbol == "desktopcomputer")
        #expect(controller.all.filter(\.applyAtLaunch).map(\.id) == [original.id])
        #expect(throws: ProfileFileError.notAProfile) { try controller.importData(Data("{\"x\":1}".utf8)) }
    }

    @Test func applyAtLaunchIsUniqueAndDisplayRulesWinAtLaunch() throws {
        let harness = try ProfilesHarness()
        defer { harness.cleanUp() }
        let controller = harness.controller
        let builtIn = ProfileDisplay(id: "B", name: "Built-in", isBuiltIn: true)
        let lg = ProfileDisplay(id: "LG", name: "LG", isBuiltIn: false)

        harness.layout.setSection(.hidden, for: fixtureA)
        let home = controller.saveCurrent(name: "Home")
        harness.layout.replace(with: .empty)
        let work = controller.saveCurrent(name: "Work")
        controller.setApplyAtLaunch(id: home.id, true)
        controller.setApplyAtLaunch(id: work.id, true)
        #expect(controller.all.filter(\.applyAtLaunch).map(\.id) == [work.id])

        var desk = try #require(controller.profile(id: home.id))
        desk.displayRule = .displays([builtIn, lg])
        controller.update(desk)

        // Launch with the desk displays: the display rule beats "apply at launch".
        #expect(controller.applyAtLaunch(configuration: .init(displays: [builtIn, lg])) == home.id)
        #expect(harness.layout.layout.section(for: fixtureA) == .hidden)
        // Launch elsewhere: the launch profile.
        #expect(controller.applyAtLaunch(configuration: .init(displays: [builtIn])) == work.id)
        // A change to an unmatched configuration leaves things alone.
        #expect(controller.displayConfigurationChanged(.init(displays: [builtIn])) == nil)
        #expect(controller.activeProfileID == work.id)
        // Back at the desk.
        #expect(controller.displayConfigurationChanged(.init(displays: [lg, builtIn])) == home.id)
        // Already active: edits survive another notification.
        harness.layout.setSection(.shown, for: fixtureA)
        #expect(controller.displayConfigurationChanged(.init(displays: [lg, builtIn])) == nil)
        #expect(harness.layout.layout.section(for: fixtureA) == .shown)
    }

    @Test func restoreLayoutSetsMarkerWithoutSettings() throws {
        let harness = try ProfilesHarness()
        defer { harness.cleanUp() }
        let p1 = harness.controller.saveCurrent(name: "p1")
        harness.controller.restoreLayout(Layout(sections: [fixtureA: .hidden]), activeProfileID: nil)
        #expect(harness.controller.activeProfileID == nil)
        #expect(harness.layout.layout.section(for: fixtureA) == .hidden)
        harness.controller.restoreLayout(.empty, activeProfileID: p1.id)
        #expect(harness.controller.activeProfileID == p1.id)
        harness.controller.restoreLayout(.empty, activeProfileID: "missing")
        #expect(harness.controller.activeProfileID == nil)
    }

    @Test func slotCommandsCarryNamesVerbatim() throws {
        let harness = try ProfilesHarness()
        defer { harness.cleanUp() }
        let odd = harness.controller.saveCurrent(name: "50% off %@ %d")
        let commands = ProfilesFeature.slotCommands(controller: harness.controller, profiles: harness.controller.all, showInMenu: true)
        #expect(commands.count == ProfilesFeature.statusMenuSlots)
        #expect(commands.map(\.id.rawValue) == (1...5).map { "profiles.apply-\($0)" })
        #expect(commands.allSatisfy { $0.id.isWellFormed })
        #expect(commands[0].localizedTitle == odd.name)
        #expect(commands[0].isAvailable?() == true)
        #expect(commands[0].isOn?() == true)
        #expect(commands[1].isAvailable?() == false)
    }
}
