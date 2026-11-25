import AppKit
import Foundation
import RolltopCore
import SwiftUI
import Testing
@testable import Rolltop

/// Backups on a test context with the real Profiles and Automations participants, each on
/// throwaway storage (a temporary profiles folder, the test defaults suite) and a
/// temporary backups folder. Nothing touches ~/Library/Application Support.
@MainActor
@Suite struct InteropBackupTests {
    final class Harness {
        let context: AppContext
        let profiles: ProfilesController
        let profileStore: ProfileFileStore
        let backups: InteropBackupController
        let customItems: CustomItemsStore
        let root: URL

        init() throws {
            context = try TestContext.make()
            InteropSettings.markTransient(in: context.settings)
            root = FileManager.default.temporaryDirectory.appending(path: "RolltopInteropTests-\(UUID().uuidString)")
            profileStore = ProfileFileStore(directory: root.appending(path: "Profiles"))
            profiles = ProfilesController(settings: context.settings, layout: context.layout, store: profileStore)
            profiles.load()
            context.services[.backupParticipants].register(ProfilesBackupParticipant(controller: profiles))
            context.services[.backupParticipants].register(AutomationsBackupParticipant(settings: context.settings))
            context.services[.backupParticipants].register(CustomItemsBackupParticipant(settings: context.settings))
            customItems = CustomItemsStore(settings: context.settings)   // marks approvals transient, revokes on import
            backups = InteropBackupController(context: context, directory: root.appending(path: "Backups"))
        }

        func tearDown() {
            profileStore.flush()
            try? FileManager.default.removeItem(at: root)
        }

        /// Settings of several types, a layout, two profiles, two rules (one with a script).
        func populate() {
            let settings = context.settings
            settings[SettingsKey<Bool>("rolltop.reveal.hover", default: false)] = true
            settings[SettingsKey<Double>("rolltop.reveal.hover-delay", default: 0)] = 0.35
            settings[SettingsKey<String>("rolltop.appearance.preset", default: "")] = "glass"
            settings[SettingsKey<Date>("rolltop.test.date", default: .distantPast)] = Date(timeIntervalSince1970: 1_800_000_000.25)
            settings[SettingsKey<[String]>("rolltop.secondary-bar.order", default: [])] = ["a", "b"]
            settings[InteropSettings.allowSettingsCommands] = true   // transient: never in a backup
            context.layout.setSection(.hidden, for: .app("com.example.Chat"))
            context.layout.setSection(.alwaysHidden, for: .system(.battery))
            profiles.saveCurrent(name: "Work")
            context.layout.setSection(.shown, for: .app("com.example.Chat"))
            profiles.saveCurrent(name: "Home")
            settings[AutomationsSettings.rules] = AutomationRuleList(rules: [
                AutomationRule(id: "r-battery", name: "On battery", conditions: [AutomationCondition(.power(AutomationPowerCondition(test: .onBattery)))]),
                AutomationRule(id: "r-script", name: "Script", conditions: [AutomationCondition(.script(AutomationScriptCondition(command: "true")))]),
            ])
            customItems.replaceModel(CustomItemsModel(
                spacers: [CustomItemSpacer(id: "spacer-1")],
                widgets: [CustomItemWidget(id: "widget-1", source: .cpu), CustomItemWidget(id: "widget-2", source: .script, scriptCommand: "date")]))
            customItems.approveAndEnable("widget-2")
            settings[SettingsKey<Bool>("rolltop.shelf.clipboard-enabled", default: false)] = true
            settings[SettingsKey<Int>("rolltop.shelf.clipboard-limit", default: 100)] = 25
        }
    }

    private static let allParts: Set<InteropBackupPart> = [.settings, .layout, .section("profiles"), .section("automations"),
                                                           .section("custom-items")]

    @Test func roundTripRestoresEverythingAndTurnsScriptRulesOff() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.populate()
        let context = harness.context
        let data = try harness.backups.exportData()
        let exportedLayout = context.layout.layout
        let exportedSettings = context.settings.exportAll()

        try await harness.backups.reset(.everything)
        #expect(context.layout.layout == .empty)
        #expect(harness.profiles.all.isEmpty)
        #expect(context.settings[AutomationsSettings.rules].rules.isEmpty)
        #expect(context.settings.exportAll().isEmpty)
        #expect(context.settings[InteropSettings.allowSettingsCommands] == false, "reset everything forgets link policy")

        let file = try InteropBackupFile.read(data)
        let preview = harness.backups.preview(of: file)
        #expect(preview.parts.map(\.id) == ["settings", "layout", "automations", "custom-items", "profiles"])
        #expect(preview.parts.first { $0.id == "custom-items" }?.summary.contains("3") == true)
        #expect(preview.parts.first { $0.id == "profiles" }?.summary.contains("2") == true)
        #expect(preview.parts.allSatisfy { $0.isAvailable })
        #expect(!preview.isFromNewerVersion)

        try await harness.backups.importBackup(file, parts: Self.allParts)
        #expect(context.layout.layout == exportedLayout)
        #expect(harness.profiles.all.map(\.id) == ["work", "home"], "ids are kept")
        #expect(harness.profiles.activeProfileID == "home")
        let rules = context.settings[AutomationsSettings.rules].rules
        #expect(rules.map(\.id) == ["r-battery", "r-script"])
        #expect(rules.map(\.isEnabled) == [true, false], "the script rule arrives turned off")
        try await Task.sleep(for: .milliseconds(50))   // the store follows the settings change
        let items = context.settings[CustomItemsSettings.model]
        #expect(items.spacers.map(\.id) == ["spacer-1"])
        #expect(items.widgets.map(\.isEnabled) == [true, false], "the script widget arrives turned off")
        #expect(context.settings[CustomItemsSettings.scriptApprovals].isEmpty, "approvals never travel")
        #expect(!String(decoding: data, as: UTF8.self).contains("script-approvals"))
        // The Shelf: its settings travel, its contents (clips, files) never do: every
        // `rolltop.shelf.` key in the file is one of its settings.
        let shelfSettings: Set<String> = [ShelfSettings.clipboardEnabled.name, ShelfSettings.clipboardLimit.name]
        let shelfKeys = Set(file.settings.keys.filter { $0.hasPrefix("rolltop.shelf.") })
        #expect(shelfKeys == shelfSettings, "\(shelfKeys)")
        let restored = context.settings.exportAll()
        for key in ["rolltop.reveal.hover", "rolltop.reveal.hover-delay", "rolltop.appearance.preset", "rolltop.test.date", "rolltop.secondary-bar.order",
                    "rolltop.shelf.clipboard-enabled", "rolltop.shelf.clipboard-limit"] {
            #expect((restored[key] as? NSObject) == (exportedSettings[key] as? NSObject), "\(key)")
        }
        #expect(context.settings[InteropSettings.allowSettingsCommands] == false, "link policy never travels")
        #expect(String(decoding: data, as: UTF8.self).contains("links-settings-commands") == false)

        await harness.backups.refreshLocalBackups()
        #expect(harness.backups.localBackups.map(\.reason).sorted() == ["before-import", "before-reset"])
    }

    @Test func settingsOnlyImportKeepsLayoutProfilesAndRules() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.populate()
        let context = harness.context
        let file = try InteropBackupFile.read(try harness.backups.exportData())
        context.settings[SettingsKey<Bool>("rolltop.reveal.hover", default: false)] = false
        context.layout.setSection(.hidden, for: .app("com.example.Later"))
        let layout = context.layout.layout
        context.settings[AutomationsSettings.rules] = AutomationRuleList(rules: [AutomationRule(id: "r-new", name: "New")])

        try await harness.backups.importBackup(file, parts: [.settings])
        #expect(context.settings[SettingsKey<Bool>("rolltop.reveal.hover", default: false)] == true)
        #expect(context.layout.layout == layout)
        #expect(context.settings[CoreSettings.layout] == layout, "the stored layout is kept too")
        #expect(context.settings[AutomationsSettings.rules].rules.map(\.id) == ["r-new"])
        #expect(harness.profiles.all.count == 2)
    }

    @Test func fileFromANewerVersionImportsWhatItKnows() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.populate()
        var json = try #require(try JSONSerialization.jsonObject(with: harness.backups.exportData()) as? [String: Any])
        json["version"] = 7
        json["futureTopLevel"] = ["anything": [1, 2, 3]]
        var settings = try #require(json["settings"] as? [String: Any])
        settings["rolltop.future.color"] = ["colour": "#ff0000"]
        json["settings"] = settings
        var sections = try #require(json["sections"] as? [String: Any])
        sections["shelf"] = ["title": "Shelf", "summary": "3 pins", "json": ["pins": [1, 2, 3]]]
        var profilesSection = try #require(sections["profiles"] as? [String: Any])
        var payload = try #require(profilesSection["json"] as? [String: Any])
        var list = try #require(payload["profiles"] as? [[String: Any]])
        list[0]["futureField"] = true
        payload["profiles"] = list
        payload["version"] = 4
        profilesSection["json"] = payload
        sections["profiles"] = profilesSection
        json["sections"] = sections
        let data = try JSONSerialization.data(withJSONObject: json)

        let file = try InteropBackupFile.read(data)
        let preview = harness.backups.preview(of: file)
        #expect(preview.isFromNewerVersion)
        #expect(preview.skippedSettings == ["rolltop.future.color"])
        #expect(preview.parts.first { $0.id == "shelf" }?.isAvailable == false)

        try await harness.backups.reset(.everything)
        try await harness.backups.importBackup(file, parts: Self.allParts.union([.section("shelf")]))
        #expect(harness.profiles.all.map(\.id) == ["work", "home"])
        #expect(harness.context.settings[SettingsKey<Bool>("rolltop.reveal.hover", default: false)] == true)
        #expect(harness.context.settings.exportAll()["rolltop.future.color"] == nil)
    }

    @Test func importSheetHasAHeight() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.populate()
        let file = try InteropBackupFile.read(try harness.backups.exportData())
        let pending = InteropPendingImport(url: URL(filePath: "/tmp/x.rolltopbackup"), file: file, preview: harness.backups.preview(of: file))
        let view = NSHostingView(rootView: InteropImportSheet(pending: pending, backups: harness.backups) { _ in })
        let size = view.fittingSize
        #expect(size.width == 460)
        #expect(size.height >= InteropImportSheet.height(parts: 4, warning: false), "sheet measures \(size)")
    }

    @Test func notABackupIsRejected() throws {
        #expect(throws: InteropBackupError.notABackup) { try InteropBackupFile.read(Data("{\"format\":\"x\",\"version\":1}".utf8)) }
        #expect(throws: InteropBackupError.notABackup) { try InteropBackupFile.read(Data("not json".utf8)) }
    }

    @Test func aFailingSectionChangesNothing() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.populate()
        let context = harness.context
        var file = try InteropBackupFile.read(try harness.backups.exportData())
        file.sections["profiles"] = InteropBackupSection(title: "Profiles", summary: "", data: Data("{\"format\":\"wrong\"}".utf8))
        file.layout = .empty
        let layout = context.layout.layout
        await #expect(throws: InteropBackupError.self) { try await harness.backups.importBackup(file, parts: Self.allParts) }
        #expect(context.layout.layout == layout)
        #expect(harness.profiles.all.count == 2)
        await harness.backups.refreshLocalBackups()
        #expect(harness.backups.localBackups.isEmpty, "validation fails before the automatic backup")
    }

    @Test func applyFailureRollsBack() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.populate()
        let failing = InteropFailingParticipant()
        harness.context.services[.backupParticipants].register(failing)
        let context = harness.context
        var file = try InteropBackupFile.read(try harness.backups.exportData())
        file.layout = .empty
        let layout = context.layout.layout
        failing.failImport = true
        await #expect(throws: InteropBackupError.self) {
            try await harness.backups.importBackup(file, parts: Self.allParts.union([.section("test")]))
        }
        #expect(context.layout.layout == layout, "rolled back from the automatic backup")
        #expect(harness.profiles.all.count == 2)
    }

    @Test func layoutResetKeepsEverythingElse() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.populate()
        try await harness.backups.reset(.layout)
        #expect(harness.context.layout.layout == .empty)
        #expect(harness.profiles.all.count == 2)
        #expect(harness.context.settings[AutomationsSettings.rules].rules.count == 2)
        #expect(harness.context.settings[SettingsKey<Bool>("rolltop.reveal.hover", default: false)] == true)
    }

    @Test func onlyTheTenNewestLocalBackupsAreKept() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        harness.backups.now = { date }
        for _ in 0..<12 {
            try await harness.backups.saveLocalBackup(try harness.backups.snapshot(reason: "before-import"))
            date = date.addingTimeInterval(61)
        }
        #expect(harness.backups.localBackups.count == 10)
        #expect(harness.backups.localBackups.first?.createdAt == date.addingTimeInterval(-61))
        let files = try FileManager.default.contentsOfDirectory(atPath: harness.backups.directory.path)
        #expect(files.count == 10)
    }

    @Test func settingValuesKeepTheirTypes() throws {
        let values: [String: Any] = ["b": true, "i": 3, "d": 0.5, "s": "x", "date": Date(timeIntervalSince1970: 5.5),
                                     "json": Data("{\"a\":[1,true,\"x\"]}".utf8), "raw": Data([0, 1, 2]),
                                     "list": ["a", 1], "dict": ["k": false]]
        let section = InteropBackupMerge.settingsSection(from: values, reserved: [])
        #expect(section["b"] == .bool(true))
        #expect(section["i"] == .int(3))
        #expect(section["d"] == .double(0.5))
        guard case .json = section["json"] else { Issue.record("JSON data stays readable"); return }
        #expect(section["raw"] == .data(Data([0, 1, 2])))
        let file = InteropBackupFile(createdAt: Date(), appVersion: "t", reason: "export", settings: section, layout: nil, sections: [:])
        let decoded = try InteropBackupFile.read(try InteropBackupFile.encoder().encode(file))
        #expect(decoded.settings == section)
        let json = try #require(decoded.settings["json"]?.plist as? Data)
        #expect((try JSONSerialization.jsonObject(with: json) as? NSDictionary) == ["a": [1, true, "x"]] as NSDictionary)
        #expect((decoded.settings["date"]?.plist as? Date) == Date(timeIntervalSince1970: 5.5))
    }
}

/// A participant whose import can be made to fail (rollback test).
@MainActor
final class InteropFailingParticipant: BackupParticipating {
    var failImport = false
    var backupID: String { "test" }
    var backupTitle: String { "Test" }
    var backupOwnedSettingsKeys: Set<String> { [] }
    func exportBackupData() throws -> Data { Data("{\"ok\":true}".utf8) }
    func backupSummary(for data: Data) throws -> String { "ok" }
    func importBackupData(_ data: Data) throws {
        if failImport { throw CommandError.failed("test failure") }
    }
    func resetBackupData() throws {}
}
