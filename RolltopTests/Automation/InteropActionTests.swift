import AppIntents
import AppKit
import Foundation
import RolltopCore
import Testing
@testable import Rolltop

/// Runs an intent the way the system does: made with `init()`, from any thread.
nonisolated func interopProbe<I: AppIntent>(_ type: I.Type) async throws -> String {
    let intent = I()
    _ = try await intent.perform()
    return String(localized: I.title)
}

/// Profiles for a test context: the service plus the `profiles.apply` command the
/// Profiles feature would register.
@MainActor
final class InteropTestProfiles: ProfileApplying {
    var profiles: [ProfileSummary] = [ProfileSummary(id: "work", name: "Work", symbol: "briefcase"),
                                      ProfileSummary(id: "home", name: "Home")]
    var activeProfileID: String?
    var layouts: [String: Layout] = ["work": Layout(sections: [.app("com.example.Mail"): .hidden]), "home": .empty]
    weak var layoutStore: LayoutStore?

    func applyProfile(id: String) throws {
        guard profiles.contains(where: { $0.id == id }) else { throw CommandError.failed("no profile \(id)") }
        activeProfileID = id
        if let layout = layouts[id] { layoutStore?.replace(with: layout) }
    }
}

/// Every App Intent's `perform()`, the AppleScript command classes and accessors, through
/// `InteropActions` on a test context. `AppContext.current` stays nil (the actions use
/// `testContext`); nothing reaches the live menu bar (seams replace Accessibility, the
/// catalog and pressing items). Serialized: the seams are process-wide.
@MainActor
@Suite(.serialized) struct InteropActionTests {
    final class Harness {
        let context: AppContext
        let profiles = InteropTestProfiles()
        let log = InteropTestLog()
        var trusted = true
        var activated: [(OwnerID, ItemActivator.Button)] = []

        init() throws {
            context = try TestContext.make()
            InteropSettings.markTransient(in: context.settings)
            profiles.layoutStore = context.layout
            context.services.register(profiles, for: .profiles)
            let profiles = profiles
            context.commands.register(Command(id: "profiles.apply", title: "Apply Profile", symbol: "x",
                                              arguments: [CommandArgument(name: "id", title: "Profile")], allowedFromURL: true,
                                              effect: .display) { invocation in
                try profiles.applyProfile(id: try invocation.require("id"))
            })
            let log = log
            context.commands.register(Command(id: "test.echo", title: "Echo", symbol: "x", allowedFromURL: true,
                                              effect: .changesSettings) { invocation in
                let pairs = invocation.arguments.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                log.entries.append("echo \(pairs) \(invocation.source.rawValue)")
            })
            context.commands.register(Command(id: "test.delete-all", title: "Delete", symbol: "x",
                                              effect: .destructive) { _ in log.entries.append("deleted") })
            context.layout.setSection(.hidden, for: .app("com.example.Chat"))
            InteropActions.testContext = context
            InteropActions.testSeams = InteropActions.Seams(
                isAccessibilityTrusted: { [unowned self] _ in trusted },
                catalogEntries: { _ in Self.entries },
                activate: { [unowned self] _, owner, button in activated.append((owner, button)) })
        }

        func tearDown() {
            InteropActions.testContext = nil
            InteropActions.testSeams = nil
        }

        static let entries: [CatalogEntry] = [
            entry(.app("com.example.Chat"), name: "Chat", section: .hidden, drawn: false),
            entry(.system(.wifi), name: "Wi-Fi", section: .shown, drawn: true),
            entry(.app("com.alphapengwang.rolltop"), name: "Rolltop", section: .shown, drawn: true, own: true),
        ]

        static func entry(_ owner: OwnerID, name: String, section: RolltopCore.Section, drawn: Bool, own: Bool = false) -> CatalogEntry {
            let slots = drawn ? [DrawnSlotRecord(displayID: 1, frame: CGRect(x: 100, y: 0, width: 24, height: 24), ownerPID: 1,
                                                 ownerBundleID: owner.bundleID, axIdentifier: nil)] : []
            return CatalogEntry(id: owner.stringValue, kind: owner.bundleID == nil ? .system : .app, owner: owner, displayName: name,
                                section: section, hasExplicitSection: true, itemCount: 1, pids: [1], axIdentifiers: [],
                                slots: slots, lastKnownFrames: [], runsOutsideApplications: false, isUnreadable: false,
                                isOwn: own, isCarriedOver: false)
        }
    }

    // MARK: Intents

    @Test func visibilityIntentsDriveTheCommands() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let visibility = harness.context.visibility
        _ = try await InteropShowHiddenIntent().perform()
        #expect(visibility.level == .hiddenRevealed)
        _ = try await InteropHideHiddenIntent().perform()
        #expect(visibility.level == .collapsed)
        let toggled = try await InteropToggleHiddenIntent().perform()
        #expect(toggled.value == true)
        #expect(visibility.level == .hiddenRevealed)
        let again = try await InteropToggleHiddenIntent().perform()
        #expect(again.value == false)
        _ = try await InteropShowAllIntent().perform()
        #expect(visibility.level == .allRevealed)
    }

    /// Shortcuts creates and runs intents off the main thread: construct them, read their
    /// static metadata and perform them from a detached task through a generic function.
    @Test func intentsRunFromOtherThreads() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let title = try await Task.detached { try await interopProbe(InteropShowHiddenIntent.self) }.value
        #expect(title == "Show Hidden Items")
        #expect(harness.context.visibility.level == .hiddenRevealed)
        _ = try await Task.detached { try await interopProbe(InteropHideHiddenIntent.self) }.value
        #expect(harness.context.visibility.level == .collapsed)
        let profiles = try await Task.detached { try await InteropProfileEntity.defaultQuery.suggestedEntities().map(\.id) }.value
        #expect(profiles == ["work", "home"])
        let items = try await Task.detached { try await InteropMenuBarItemEntity.defaultQuery.suggestedEntities().count }.value
        #expect(items == 2)
        let filter = try await Task.detached { try await interopProbe(InteropFocusFilter.self) }.value
        #expect(filter == "Use Rolltop Profile")
    }

    @Test func intentsNeedAccessibility() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.trusted = false
        await #expect(throws: InteropActionError.accessibilityMissing) { _ = try await InteropShowHiddenIntent().perform() }
        await #expect(throws: InteropActionError.accessibilityMissing) { _ = try await InteropGetItemsIntent().perform() }
        let chat = InteropMenuBarItemEntity(InteropItem(owner: .app("com.example.Chat"), name: "Chat", bundleID: "com.example.Chat",
                                                        section: .hidden, isVisible: false))
        await #expect(throws: InteropActionError.accessibilityMissing) { _ = try await InteropOpenItemIntent(item: chat).perform() }
        #expect(harness.activated.isEmpty)
        #expect(InteropActionError.accessibilityMissing.errorDescription?.contains("Device Control and Data Access") == true)
    }

    @Test func intentsSayWhenRolltopIsNotRunning() async throws {
        #expect(AppContext.current == nil)
        await #expect(throws: InteropActionError.notRunning) { _ = try await InteropShowHiddenIntent().perform() }
        await #expect(throws: InteropActionError.notRunning) { _ = try await InteropProfileQuery().suggestedEntities() }
    }

    @Test func profileIntentsAndQuery() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let suggested = try await InteropProfileQuery().suggestedEntities()
        #expect(suggested.map(\.id) == ["work", "home"])
        #expect(try await InteropProfileQuery().entities(matching: "wor").map(\.id) == ["work"])
        let current = try await InteropGetCurrentProfileIntent().perform()
        #expect(current.value??.id == nil)
        let applied = try await InteropApplyProfileIntent(profile: suggested[0]).perform()
        #expect(applied.value?.id == "work")
        #expect(harness.profiles.activeProfileID == "work")
        #expect(harness.context.layout.layout.section(for: .app("com.example.Mail")) == .hidden)
        let now = try await InteropGetCurrentProfileIntent().perform()
        #expect(now.value??.name == "Work")
    }

    @Test func itemIntentsAndQuery() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let all = try await InteropGetItemsIntent().perform()
        #expect(all.value?.map(\.id) == ["com.example.Chat", "system:wifi"], "Rolltop's own item is left out")
        #expect(all.value?.first?.bundleIdentifier == "com.example.Chat")
        #expect(all.value?.last?.bundleIdentifier == nil)
        #expect(all.value?.first?.isVisible == false)
        let hidden = try await InteropGetItemsIntent(section: .hidden).perform()
        #expect(hidden.value?.map(\.name) == ["Chat"])
        #expect(try await InteropMenuBarItemQuery().entities(for: ["system:wifi"]).map(\.name) == ["Wi-Fi"])

        let chat = try #require(all.value?.first)
        _ = try await InteropOpenItemIntent(item: chat, click: .right).perform()
        #expect(harness.activated.map(\.0) == [.app("com.example.Chat")])
        #expect(harness.activated.map(\.1) == [.right])

        let wifi = try #require(all.value?.last)
        _ = try await InteropSetSectionIntent(item: wifi, section: .alwaysHidden).perform()
        #expect(harness.context.layout.layout.section(for: .system(.wifi)) == .alwaysHidden)
    }

    @Test func runCommandIntent() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        _ = try await InteropRunCommandIntent(command: "test.echo", arguments: ["a=1", "b=two words"]).perform()
        #expect(harness.log.entries == ["echo a=1 b=two words shortcuts"])
        await #expect(throws: InteropActionError.notAllowed("test.delete-all")) {
            _ = try await InteropRunCommandIntent(command: "test.delete-all").perform()
        }
        await #expect(throws: InteropActionError.notAllowed("debug.dump-state")) {
            _ = try await InteropRunCommandIntent(command: "debug.dump-state").perform()
        }
        await #expect(throws: InteropActionError.unknownCommand("nope.nope")) {
            _ = try await InteropRunCommandIntent(command: "nope.nope").perform()
        }
        #expect(!harness.log.entries.contains("deleted"))
    }

    @Test func focusFilterAppliesAndRestores() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        try harness.profiles.applyProfile(id: "home")
        let work = InteropProfileEntity(id: "work", name: "Work", symbol: "briefcase")
        _ = try await InteropFocusFilter(profile: work).perform()
        #expect(harness.profiles.activeProfileID == "work")
        #expect(harness.context.settings[InteropSettings.focusRestore]?.previousProfileID == "home")
        _ = try await InteropFocusFilter(profile: nil).perform()
        #expect(harness.profiles.activeProfileID == "home")
        #expect(harness.context.settings[InteropSettings.focusRestore] == nil)
        #expect(String(localized: InteropFocusFilter(profile: work).displayRepresentation.title) == "Work")
    }

    @Test func focusFilterRestoresTheLayoutWhenNoProfileWasActive() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let before = harness.context.layout.layout
        _ = try await InteropFocusFilter(profile: InteropProfileEntity(id: "work", name: "Work", symbol: "x")).perform()
        #expect(harness.context.layout.layout != before)
        _ = try await InteropFocusFilter(profile: nil).perform()
        #expect(harness.context.layout.layout == before)
    }

    /// The filter's runs drive `.focusState`: on with a profile, unknown (never off) with the
    /// defaults macOS sends when that Focus ends.
    @Test func focusFilterReportsOnOrUnknown() async throws {
        #expect(InteropFocusState.state(afterFilterWith: "work") == true)
        #expect(InteropFocusState.state(afterFilterWith: nil) == nil)
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.context.services.register(InteropFocusState() as any FocusStateProviding, for: .focusState)
        #expect(harness.context.services[.focusState].isFocused == nil)
        _ = try await InteropFocusFilter(profile: InteropProfileEntity(id: "work", name: "Work", symbol: "x")).perform()
        #expect(harness.context.services[.focusState].isFocused == true)
        _ = try await InteropFocusFilter(profile: nil).perform()
        #expect(harness.context.services[.focusState].isFocused == nil)
        // A Focus whose profile was deleted since is still on.
        _ = try? await InteropFocusFilter(profile: InteropProfileEntity(id: "gone", name: "Gone", symbol: "x")).perform()
        #expect(harness.context.services[.focusState].isFocused == true)
    }

    // MARK: AppleScript

    private static func code(_ text: String) -> FourCharCode { InteropScriptCodes.fourCharCode(text) }

    /// A command instance made by Cocoa scripting from Rolltop.sdef (proves the mapping).
    private func command<T: InteropScriptCommand>(_ id: String, as type: T.Type) throws -> T {
        let registry = NSScriptSuiteRegistry.shared()
        let description = try #require(registry.commandDescription(withAppleEventClass: Self.code("Rltp"),
                                                                     andAppleEventCode: Self.code(id)),
                                       "Rolltop.sdef defines Rolltop\(id)")
        return try #require(description.createCommandInstance() as? T, "\(description.commandClassName) is \(T.self)")
    }

    private func run(_ command: InteropScriptCommand) async -> Any? {
        _ = command.performDefaultImplementation()
        await command.pendingTask?.value
        return command.lastResult
    }

    @Test func dictionaryMapsEveryCommandAndClass() throws {
        let registry = NSScriptSuiteRegistry.shared()
        let suite = registry.suiteNames.contains("Rolltop Suite")
        #expect(suite)
        for (code, name) in [("Show", "InteropShowHiddenScriptCommand"), ("Hide", "InteropHideHiddenScriptCommand"),
                             ("Togl", "InteropToggleHiddenScriptCommand"), ("Appl", "InteropApplyProfileScriptCommand"),
                             ("OpnI", "InteropOpenItemScriptCommand"), ("RunC", "InteropRunCommandScriptCommand")] {
            let description = registry.commandDescription(withAppleEventClass: Self.code("Rltp"), andAppleEventCode: Self.code(code))
            #expect(description?.commandClassName == name)
            #expect(NSClassFromString(name) != nil)
        }
        let application = try #require(NSScriptClassDescription(for: NSApplication.self))
        #expect(application.key(withAppleEventCode: Self.code("SCpr")) == "interopCurrentProfile")
        #expect(registry.classDescription(withAppleEventCode: Self.code("SPrf"))?.implementationClassName == "InteropScriptProfile")
        #expect(registry.classDescription(withAppleEventCode: Self.code("SMbi"))?.implementationClassName == "InteropScriptItem")
    }

    @Test func visibilityScriptCommands() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        _ = await run(try command("Show", as: InteropShowHiddenScriptCommand.self))
        #expect(harness.context.visibility.level == .hiddenRevealed)
        _ = await run(try command("Hide", as: InteropHideHiddenScriptCommand.self))
        #expect(harness.context.visibility.level == .collapsed)
        let toggle = try command("Togl", as: InteropToggleHiddenScriptCommand.self)
        #expect((await run(toggle) as? NSNumber)?.boolValue == true)
        #expect(toggle.scriptErrorNumber == 0)
    }

    @Test func applyProfileScriptCommand() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let apply = try command("Appl", as: InteropApplyProfileScriptCommand.self)
        apply.directParameter = "home"
        #expect((await run(apply) as? InteropScriptProfile)?.name == "Home")
        let byName = try command("Appl", as: InteropApplyProfileScriptCommand.self)
        byName.directParameter = "WORK"
        let result = await run(byName) as? InteropScriptProfile
        #expect(result?.uniqueID == "work")
        #expect(result?.objectSpecifier is NSUniqueIDSpecifier)
        #expect(harness.profiles.activeProfileID == "work")
        let missing = try command("Appl", as: InteropApplyProfileScriptCommand.self)
        missing.directParameter = "Gym"
        _ = await run(missing)
        #expect(missing.scriptErrorNumber == -1728)
        #expect(missing.scriptErrorString?.contains("Gym") == true)
    }

    @Test func openItemScriptCommand() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let open = try command("OpnI", as: InteropOpenItemScriptCommand.self)
        open.directParameter = "com.example.Chat"
        open.arguments = ["RightClick": NSNumber(value: true)]
        _ = await run(open)
        #expect(open.scriptErrorNumber == 0)
        #expect(harness.activated.map(\.1) == [.right])
        let byName = try command("OpnI", as: InteropOpenItemScriptCommand.self)
        byName.directParameter = "wi-fi"
        _ = await run(byName)
        #expect(harness.activated.map(\.0) == [.app("com.example.Chat"), .system(.wifi)])
        harness.trusted = false
        let denied = try command("OpnI", as: InteropOpenItemScriptCommand.self)
        denied.directParameter = "com.example.Chat"
        _ = await run(denied)
        #expect(denied.scriptErrorNumber == -10000)
        #expect(denied.scriptErrorString?.contains("Device Control and Data Access") == true)
    }

    @Test func runCommandScriptCommand() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let record = try command("RunC", as: InteropRunCommandScriptCommand.self)
        record.directParameter = "test.echo"
        record.arguments = ["Arguments": ["owner": "system:wifi"]]
        _ = await run(record)
        let list = try command("RunC", as: InteropRunCommandScriptCommand.self)
        list.directParameter = "test.echo"
        list.arguments = ["Arguments": ["x=1"]]
        _ = await run(list)
        #expect(harness.log.entries == ["echo owner=system:wifi applescript", "echo x=1 applescript"])
        let refused = try command("RunC", as: InteropRunCommandScriptCommand.self)
        refused.directParameter = "test.delete-all"
        _ = await run(refused)
        #expect(refused.scriptErrorNumber == -10004)
        // A record with user-defined fields, as AppleScript sends {owner:"…"}.
        let fields = NSAppleEventDescriptor.list()
        fields.insert(NSAppleEventDescriptor(string: "owner"), at: 1)
        fields.insert(NSAppleEventDescriptor(string: "com.example.Chat"), at: 2)
        let raw = NSAppleEventDescriptor.record()
        raw.setDescriptor(fields, forKeyword: InteropScriptCodes.userRecordFields)
        #expect(try InteropRunCommandScriptCommand.arguments(from: raw) == ["owner": "com.example.Chat"])
    }

    @Test func applicationAccessors() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        try harness.profiles.applyProfile(id: "home")
        let app = NSApplication.shared
        #expect(app.interopProfiles.map(\.uniqueID) == ["work", "home"])
        #expect(app.interopCurrentProfile?.name == "Home")
        #expect((app.value(forKey: "interopMenuBarItems") as? [InteropScriptItem])?.map(\.uniqueID) == ["com.example.Chat", "system:wifi"])
        let chat = app.interopMenuBarItems[0]
        #expect(chat.section.uint32Value == InteropScriptCodes.fourCharCode("SShd"))
        #expect(chat.bundleIdentifier == "com.example.Chat")
        #expect(!chat.visible)
        #expect(app.interopHiddenItemsShowing == false)
        harness.trusted = false
        #expect(app.interopMenuBarItems.isEmpty)
    }
}
