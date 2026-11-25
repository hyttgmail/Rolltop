import AppKit
import Foundation
import RolltopCore
import Testing
@testable import Rolltop

/// Hiding Rolltop's own icon (Settings › General "Show Rolltop in the menu bar") and the ways
/// back: the setting and its sync with the item, the toggle command, links, the cold-start
/// decision, and what frame and image users get while the icon is hidden.
@MainActor
@Suite struct StatusItemVisibilityTests {
    /// Stands in for `NSStatusItem`: `visible` is KVO-observable like the real property.
    final class FakeItem: NSObject, StatusItemVisibilityTarget {
        @objc(visible) dynamic var isVisible = true
    }

    final class FakeSettingsWindow: SettingsWindowPresenting {
        var shown: [String?] = []
        func showSettings(paneID: String?) { shown.append(paneID) }
    }

    private func controller(_ context: AppContext) -> StatusItemController {
        StatusItemController(visibility: context.visibility, commands: context.commands, catalog: context.catalog,
                             services: context.services, settings: context.settings)
    }

    // MARK: Setting

    @Test func shownIsTheDefaultAndLeavesNoKey() throws {
        let context = try TestContext.make()
        #expect(context.settings[StatusItemVisibility.setting])
        StatusItemVisibility.set(false, in: context.settings)
        #expect(context.settings.exportAll()[StatusItemVisibility.setting.name] as? Bool == false)
        StatusItemVisibility.set(true, in: context.settings)
        #expect(!context.settings.hasValue(for: StatusItemVisibility.setting))
        #expect(context.settings.exportAll()[StatusItemVisibility.setting.name] == nil)
        #expect(!context.settings.isTransient(StatusItemVisibility.setting.name))
    }

    // MARK: Sync (5a: ⌘-drag removal → the setting follows)

    @Test func theSettingDrivesTheItem() throws {
        let context = try TestContext.make()
        let item = FakeItem()
        let sync = StatusItemVisibilitySync(settings: context.settings, item: item)
        sync.applySetting()
        #expect(item.isVisible)
        StatusItemVisibility.set(false, in: context.settings)
        sync.applySetting()
        #expect(!item.isVisible)
        // Applying its own value back is not a change by the user.
        #expect(context.settings[StatusItemVisibility.setting] == false)
        StatusItemVisibility.set(true, in: context.settings)
        sync.applySetting()
        #expect(item.isVisible)
        #expect(!context.settings.hasValue(for: StatusItemVisibility.setting))
    }

    @Test func removingTheItemTurnsTheSettingOff() throws {
        let context = try TestContext.make()
        let item = FakeItem()
        let sync = StatusItemVisibilitySync(settings: context.settings, item: item)
        sync.applySetting()
        item.isVisible = false                       // the user ⌘-dragged it out
        sync.itemVisibilityChanged(to: false)
        #expect(context.settings[StatusItemVisibility.setting] == false)
        item.isVisible = true
        sync.itemVisibilityChanged(to: true)
        #expect(context.settings[StatusItemVisibility.setting])
        #expect(!context.settings.hasValue(for: StatusItemVisibility.setting))
        // After stop() (quitting) nothing is written back.
        sync.stop()
        sync.itemVisibilityChanged(to: false)
        #expect(context.settings[StatusItemVisibility.setting])
    }

    /// The controller's KVO wiring, end to end with a fake item: a removal by the user writes
    /// the setting, the setting hides the item, and after `stopObserving` nothing follows.
    @Test func controllerFollowsTheItemThroughKVO() throws {
        let context = try TestContext.make()
        let controller = controller(context)
        let item = FakeItem()
        controller.attachVisibility(to: item)
        #expect(item.isVisible)
        item.isVisible = false
        #expect(context.settings[StatusItemVisibility.setting] == false)
        StatusItemVisibility.set(true, in: context.settings)
        controller.observeState()
        #expect(item.isVisible)
        controller.stopObserving()
        item.isVisible = false
        #expect(context.settings[StatusItemVisibility.setting])
    }

    @Test func aStoredFalseHidesTheItemAtAttach() throws {
        let context = try TestContext.make()
        StatusItemVisibility.set(false, in: context.settings)
        let controller = controller(context)
        let item = FakeItem()
        controller.attachVisibility(to: item)
        #expect(!item.isVisible)
        #expect(context.settings[StatusItemVisibility.setting] == false)
        controller.stopObserving()
    }

    // MARK: Command (5a, 5c)

    @Test func toggleCommandFlipsTheSettingFromAShortcut() async throws {
        let context = try TestContext.make()
        let command = try #require(context.commands.command(StatusItemVisibility.toggleCommand))
        #expect(command.effect == .changesSettings)
        #expect(command.allowedFromURL)
        #expect(command.arguments.allSatisfy { !$0.isRequired }, "bindable in Settings › Shortcuts")
        #expect(command.isOn?() == true)
        try await context.commands.run(StatusItemVisibility.toggleCommand, source: .hotkey)
        #expect(context.settings[StatusItemVisibility.setting] == false)
        #expect(command.isOn?() == false)
        try await context.commands.run(StatusItemVisibility.toggleCommand, source: .palette)
        #expect(context.settings[StatusItemVisibility.setting])
        #expect(!context.settings.hasValue(for: StatusItemVisibility.setting))
    }

    @Test func openSettingsRunsFromAShortcutAndALink() async throws {
        let context = try TestContext.make()
        let window = FakeSettingsWindow()
        context.services.register(window, for: .settingsWindow)
        let command = try #require(context.commands.command(.openSettings))
        #expect(command.arguments.allSatisfy { !$0.isRequired })
        try await context.commands.run(.openSettings, source: .hotkey)
        try await context.commands.run(.openSettings, arguments: ["pane": "general"], source: .url)
        #expect(window.shown == [nil, "general"])
    }

    // MARK: Links (5d)

    private func decide(_ id: CommandID, effect: CommandEffect?, sender: LinkSender,
                        settings: InteropLinkPolicySettings = InteropLinkPolicySettings()) -> InteropLinkDecision {
        InteropLinkPolicy.decide(InteropLinkRequest(command: id, commandAllowsLinks: true, effect: effect, sender: sender),
                                 settings: settings, isDebugBuild: false, rateAllowed: true)
    }

    /// Release policy: `rolltop://settings` runs from `open` (an unknown sender) by default; the
    /// toggle changes a setting, so a link runs it only after the user allowed such links.
    @Test func releaseLinkPolicyForTheWaysBack() throws {
        let context = try TestContext.make()
        let toggle = try #require(context.commands.command(StatusItemVisibility.toggleCommand))
        let settings = try #require(context.commands.command(.openSettings))
        let tool = LinkSender(kind: .tool, path: "/usr/bin/open")
        #expect(decide(.openSettings, effect: settings.effect, sender: tool) == .run)
        #expect(decide(.openSettings, effect: settings.effect, sender: .unknown) == .run)
        #expect(decide(toggle.id, effect: toggle.effect, sender: tool) == .refuse(.settingsCommandsOff))
        var allowing = InteropLinkPolicySettings()
        allowing.allowSettingsCommands = true
        #expect(decide(toggle.id, effect: toggle.effect, sender: tool, settings: allowing) == .run)
        // What can still stop `rolltop://settings`: links turned off, unknown senders turned off.
        var off = InteropLinkPolicySettings()
        off.linksEnabled = false
        #expect(decide(.openSettings, effect: settings.effect, sender: tool, settings: off) == .refuse(.linksOff))
        // An app asks once.
        let app = LinkSender(kind: .app, bundleID: "com.example.launcher")
        #expect(decide(.openSettings, effect: settings.effect, sender: app) == .ask)
        // `rolltop://settings` and `rolltop://command/app.settings` both name app.settings.
        #expect(InteropLinkRoutes.target(of: URL(string: "rolltop://settings")!, paletteCommand: nil) == .command(.openSettings, [:]))
        #expect(InteropLinkRoutes.target(of: URL(string: "rolltop://command/app.settings")!, paletteCommand: nil) == .command(.openSettings, [:]))
    }

    /// Without the Automation feature's gate, the core gate runs display commands only.
    @Test func coreLinkGateRunsSettingsButNotTheToggle() async throws {
        let context = try TestContext.make()
        let window = FakeSettingsWindow()
        context.services.register(window, for: .settingsWindow)
        StatusItemVisibility.set(false, in: context.settings)
        let gate = CoreLinkGate(context: context)
        gate.handle(URL(string: "rolltop://command/app.toggle-menu-bar-icon")!, sender: .unknown)
        gate.handle(URL(string: "rolltop://command/app.settings")!, sender: .unknown)
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.shown == [nil])
        #expect(context.settings[StatusItemVisibility.setting] == false)
    }

    // MARK: Cold start (5b)

    @Test func launchTriggers() {
        typealias L = StatusItemLaunch
        #expect(L.trigger(launchedByLaunchServices: false, loginItemMarker: false, linkQueued: false, secondsSinceLogin: 30) == .shell)
        #expect(L.trigger(launchedByLaunchServices: true, loginItemMarker: false, linkQueued: false, secondsSinceLogin: 3_600) == .user)
        #expect(L.trigger(launchedByLaunchServices: true, loginItemMarker: false, linkQueued: false, secondsSinceLogin: nil) == .user)
        #expect(L.trigger(launchedByLaunchServices: true, loginItemMarker: true, linkQueued: false, secondsSinceLogin: 3_600) == .login)
        // Right after login counts as a login launch even without the marker: when in doubt, no Settings.
        #expect(L.trigger(launchedByLaunchServices: true, loginItemMarker: false, linkQueued: false, secondsSinceLogin: 40) == .login)
        #expect(L.trigger(launchedByLaunchServices: true, loginItemMarker: false, linkQueued: true, secondsSinceLogin: 3_600) == .link)
        #expect(L.trigger(launchedByLaunchServices: true, loginItemMarker: true, linkQueued: true, secondsSinceLogin: 10) == .link)
    }

    @Test func coldStartOpensSettingsOnlyForAHiddenIconAndAUserStart() {
        typealias L = StatusItemLaunch
        #expect(L.opensSettings(iconShown: false, trigger: .user))
        #expect(L.opensSettings(iconShown: false, trigger: .shell))
        #expect(!L.opensSettings(iconShown: false, trigger: .login))
        #expect(!L.opensSettings(iconShown: false, trigger: .link))
        for trigger in [L.Trigger.user, .shell, .login, .link] {
            #expect(!L.opensSettings(iconShown: true, trigger: trigger))
        }
    }

    @Test func loginItemEventMarker() {
        let core = UInt32(kCoreEventClass), oapp = UInt32(kAEOpenApplication), login = UInt32(keyAELaunchedAsLogInItem)
        #expect(StatusItemLaunch.isLoginItemEvent(eventClass: core, eventID: oapp, propData: login))
        #expect(!StatusItemLaunch.isLoginItemEvent(eventClass: core, eventID: oapp, propData: nil))
        #expect(!StatusItemLaunch.isLoginItemEvent(eventClass: core, eventID: oapp, propData: UInt32(keyAELaunchedAsServiceItem)))
        #expect(!StatusItemLaunch.isLoginItemEvent(eventClass: core, eventID: UInt32(kAEReopenApplication), propData: login))
        #expect(!StatusItemLaunch.isLoginItemEvent(eventClass: nil, eventID: nil, propData: nil))
    }

    // MARK: Frame, images, nudge (5e)

    @Test func noFrameWhileTheIconIsHidden() {
        let item = CGRect(x: 1500, y: 1266, width: 30, height: 30)
        let widget = CGRect(x: 1400, y: 1266, width: 40, height: 30)
        #expect(OwnStatusItemRegistry.mainFrame(appKit: item, ownSlots: [item], otherFrames: []) == item)
        #expect(OwnStatusItemRegistry.mainFrame(appKit: nil, ownSlots: [item, widget], otherFrames: [widget]) == item)
        // Hidden: neither AppKit's frame nor a leftover slot (a widget's, or stale) is used.
        #expect(OwnStatusItemRegistry.mainFrame(appKit: item, ownSlots: [item], otherFrames: [], mainVisible: false) == nil)
        #expect(OwnStatusItemRegistry.mainFrame(appKit: nil, ownSlots: [widget], otherFrames: [], mainVisible: false) == nil)
    }

    @Test func imagesCountTheVisibleItems() {
        typealias R = OwnStatusItemRegistry
        // Icon shown, two widgets: 0 = icon, 1…2 = widgets.
        #expect(R.imageSource(index: 0, visibleCount: 3, hasMain: true) == .visible(0))
        #expect(R.imageSource(index: 2, visibleCount: 3, hasMain: true) == .visible(2))
        #expect(R.imageSource(index: 3, visibleCount: 3, hasMain: true) == nil)
        // Icon hidden, one widget: index 0 is the widget, not the hidden icon.
        #expect(R.imageSource(index: 0, visibleCount: 1, hasMain: true) == .visible(0))
        #expect(R.imageSource(index: 1, visibleCount: 1, hasMain: true) == nil)
        // Nothing visible: the hidden icon still stands for Rolltop's owner.
        #expect(R.imageSource(index: 0, visibleCount: 0, hasMain: true) == .hiddenMain)
        #expect(R.imageSource(index: 1, visibleCount: 0, hasMain: true) == nil)
        #expect(R.imageSource(index: 0, visibleCount: 0, hasMain: false) == nil)
    }

    @Test func nudgeChangesTheLengthByHalfAPoint() {
        // Variable and square items: the button's content width, not the padded slot width.
        #expect(OwnStatusItemRegistry.nudgedLength(length: NSStatusItem.variableLength, contentWidth: 17) == 17.5)
        #expect(OwnStatusItemRegistry.nudgedLength(length: NSStatusItem.squareLength, contentWidth: 24) == 24.5)
        #expect(OwnStatusItemRegistry.nudgedLength(length: 12, contentWidth: 40) == 12.5)
        #expect(OwnStatusItemRegistry.nudgedLength(length: NSStatusItem.variableLength, contentWidth: 0) == nil)
    }

    @Test func nudgeWithoutAnyItemReturnsFalse() {
        #expect(!OwnStatusItemRegistry().nudgeLayout())
    }

    // MARK: Ways to show hidden items (5f)

    @Test func revealGestureKeysMatchReveal() {
        let reveal = [RevealSettings.clickEmptySpace, RevealSettings.hover, RevealSettings.scroll]
        #expect(StatusItemVisibility.revealGestureKeys.map(\.name) == reveal.map(\.name))
        #expect(StatusItemVisibility.revealGestureKeys.map(\.defaultValue) == reveal.map(\.defaultValue))
    }

    @Test func waysToShowHiddenItems() throws {
        let context = try TestContext.make()
        // Defaults: clicking the empty menu bar is on.
        #expect(StatusItemVisibility.revealGestures(in: context.settings) == [true, false, false])
        #expect(StatusItemVisibility.hasWayToShowHiddenItems(gestures: [true, false, false], shortcutCount: 0))
        context.settings[RevealSettings.clickEmptySpace] = false
        let gestures = StatusItemVisibility.revealGestures(in: context.settings)
        #expect(gestures == [false, false, false])
        #expect(!StatusItemVisibility.hasWayToShowHiddenItems(gestures: gestures, shortcutCount: 0))
        #expect(StatusItemVisibility.hasWayToShowHiddenItems(gestures: gestures, shortcutCount: 1))
        context.settings[RevealSettings.scroll] = true
        #expect(StatusItemVisibility.hasWayToShowHiddenItems(gestures: StatusItemVisibility.revealGestures(in: context.settings),
                                                             shortcutCount: 0))
    }
}
