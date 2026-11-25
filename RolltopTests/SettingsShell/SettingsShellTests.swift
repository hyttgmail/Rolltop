import Foundation
import ServiceManagement
import RolltopCore
import Testing
@testable import Rolltop

@Suite struct SettingsSidebarTests {
    private let items = [
        SidebarItem(id: "general", title: "General", sortOrder: 10),
        SidebarItem(id: "menu-bar-items", title: "Menu Bar Items", sortOrder: 110),
        SidebarItem(id: "reveal", title: "Reveal", sortOrder: 210),
        SidebarItem(id: "hotkeys", title: "Keyboard Shortcuts", sortOrder: 220),
        SidebarItem(id: "permissions", title: "Permissions", sortOrder: 910),
        SidebarItem(id: "about", title: "About", sortOrder: 990),
    ]

    @Test func groupsFollowTheContractRanges() {
        #expect(SettingsSidebar.group(forSortOrder: 0) == 0)
        #expect(SettingsSidebar.group(forSortOrder: 99) == 0)
        #expect(SettingsSidebar.group(forSortOrder: 100) == 1)
        #expect(SettingsSidebar.group(forSortOrder: 499) == 4)
        #expect(SettingsSidebar.group(forSortOrder: 600) == 5)
        #expect(SettingsSidebar.group(forSortOrder: 900) == 9)
        #expect(SettingsSidebar.group(forSortOrder: 990) == 9)
        let ids = SettingsSidebar.groups(items).map { $0.map(\.id) }
        #expect(ids == [["general"], ["menu-bar-items"], ["reveal", "hotkeys"], ["permissions", "about"]])
    }

    @Test func searchMatchesTitleWordsIgnoringCase() {
        #expect(SettingsSidebar.filter(items, query: "").count == items.count)
        #expect(SettingsSidebar.filter(items, query: "   ").count == items.count)
        #expect(SettingsSidebar.filter(items, query: "perm").map(\.id) == ["permissions"])
        #expect(SettingsSidebar.filter(items, query: "MENU items").map(\.id) == ["menu-bar-items"])
        #expect(SettingsSidebar.filter(items, query: "e").map(\.id) == ["general", "menu-bar-items", "reveal", "hotkeys", "permissions"])
        #expect(SettingsSidebar.filter(items, query: "zzz").isEmpty)
    }

    @Test func selectionPrefersRequestedThenSavedThenFirst() {
        let ids = items.map(\.id)
        #expect(SettingsSidebar.selection(requested: "about", saved: "general", available: ids) == "about")
        #expect(SettingsSidebar.selection(requested: "missing", saved: "permissions", available: ids) == "permissions")
        #expect(SettingsSidebar.selection(requested: nil, saved: "gone", available: ids) == "general")
        #expect(SettingsSidebar.selection(requested: nil, saved: nil, available: []) == nil)
    }
}

@Suite struct LaunchAtLoginTests {
    @Test func statusMapping() {
        #expect(LaunchAtLogin.state(for: .enabled) == .enabled)
        #expect(LaunchAtLogin.state(for: .requiresApproval) == .requiresApproval)
        #expect(LaunchAtLogin.state(for: .notRegistered) == .disabled)
        #expect(LaunchAtLogin.state(for: .notFound) == .disabled)
        #expect(LaunchAtLogin.name(of: .notFound) == "not-found")
    }
}

@Suite struct DiagnosticsTests {
    @Test func textHasVersionsPermissionsPathAndRestriction() {
        let diagnostics = Diagnostics(
            appVersion: "0.1.0", appBuild: "7", osVersion: "27.2.1 (26B131)", bundlePath: "/Applications/Rolltop.app",
            runsFromApplications: true, launchedByLaunchServices: false, accessibility: true, accessibilityAtLaunch: false,
            screenRecording: false, restrictionAvailable: true, restrictionHeld: true, presentation: "collapsed",
            concealShown: false, lastError: nil, catalogEntryCount: 24, explicitSectionCount: 3, openAtLogin: "not-found")
        let lines = diagnostics.text.components(separatedBy: "\n")
        #expect(lines.first == "Rolltop 0.1.0 (7)")
        #expect(lines.contains("macOS 27.2.1 (26B131)"))
        #expect(lines.contains("Path: /Applications/Rolltop.app"))
        #expect(lines.contains("Launched by: shell (inherits the terminal's permissions)"))
        #expect(lines.contains("Accessibility: yes (at launch: no)"))
        #expect(lines.contains("Restriction held: yes"))
        #expect(lines.contains("Open at login: not-found"))
        #expect(!diagnostics.text.contains("Last error"))
    }

    @Test func resetClearsStoredValuesAndTheLayoutInMemory() throws {
        let suite = "com.alphapengwang.rolltop.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let layout = LayoutStore(settings: settings)
        let flag = SettingsKey<Bool>("rolltop.test.flag", default: false)
        layout.setSection(.hidden, for: .app("com.foo"))
        settings[flag] = true
        defaults.set("kept", forKey: "NSWindow Frame Elsewhere")

        SettingsReset.resetAll(settings: settings, layout: layout)

        #expect(layout.layout == .empty)
        #expect(settings[flag] == false)
        #expect(settings.exportAll().isEmpty)
        #expect(defaults.string(forKey: "NSWindow Frame Elsewhere") == "kept")
        // A later change starts from the empty layout, not the old one.
        layout.setSection(.shown, for: .app("com.bar"))
        #expect(settings[CoreSettings.layout] == Layout(sections: [.app("com.bar"): .shown]))
    }
}

@Suite struct SettingsSearchKeywordTests {
    @Test func keywordsMatchLikeTitles() {
        let items = [
            SidebarItem(id: "general", title: "General", sortOrder: 10, keywords: ["login, startup"]),
            SidebarItem(id: "reveal", title: "Reveal", sortOrder: 210, keywords: ["click, hover, make room"]),
            SidebarItem(id: "about", title: "About", sortOrder: 990),
        ]
        #expect(SettingsSidebar.filter(items, query: "login").map(\.id) == ["general"])
        #expect(SettingsSidebar.filter(items, query: "HOVER").map(\.id) == ["reveal"])
        #expect(SettingsSidebar.filter(items, query: "reveal room").map(\.id) == ["reveal"])
        #expect(SettingsSidebar.filter(items, query: "about login").isEmpty)
    }

    @Test func everyPaneHasKeywords() throws {
        let context = try TestContext.make()
        let features = FeatureRegistry.all.map { $0.init(context: context) }
        let panes = features.flatMap(\.settingsPanes)
        #expect(panes.count >= 12)
        for pane in panes {
            #expect(!pane.keywords.isEmpty, "pane \(pane.id) has no search keywords")
        }
    }
}
