import Carbon.HIToolbox
import Foundation
import RolltopCore
import Testing
@testable import Rolltop

/// Records registrations; `refuse` makes chosen combinations fail like a taken hotkey.
final class FakeRegistrar: HotkeyRegistering {
    var onPress: ((UInt32) -> Void)?
    private(set) var registered: [UInt32: KeyCombo] = [:]
    var refuse: Set<KeyCombo> = []

    func register(_ combo: KeyCombo, id: UInt32) -> OSStatus {
        if refuse.contains(combo) { return OSStatus(eventHotKeyExistsErr) }
        registered[id] = combo
        return noErr
    }

    func unregister(id: UInt32) { registered[id] = nil }

    func press(_ combo: KeyCombo) {
        guard let id = registered.first(where: { $0.value == combo })?.key else { return }
        onPress?(id)
    }
}

/// Captures the invocations of test commands.
final class InvocationLog {
    var invocations: [(CommandID, CommandInvocation)] = []
}

@Suite struct HotkeyControllerTests {
    private let hideCombo = KeyCombo(keyCode: UInt16(kVK_ANSI_H), modifiers: [.command, .option, .control])
    private let otherCombo = KeyCombo(keyCode: UInt16(kVK_ANSI_J), modifiers: [.command, .option, .control])
    private let systemCombo = KeyCombo(keyCode: UInt16(kVK_ANSI_3), modifiers: [.command, .shift])

    private func make(defaults: [CommandID: KeyCombo] = [:], system: Set<KeyCombo> = [])
        throws -> (HotkeyController, FakeRegistrar, CommandRegistry, InvocationLog, SettingsStore) {
        let suite = "com.alphapengwang.rolltop.tests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suite))
        let settings = SettingsStore(defaults: userDefaults)
        let commands = CommandRegistry()
        let log = InvocationLog()
        for id in [CommandID("test.alpha"), "test.beta", "test.gamma"] {
            commands.register(Command(id: id, title: LocalizedStringResource(stringLiteral: id.rawValue), symbol: "circle",
                                      defaultShortcut: defaults[id]) { log.invocations.append((id, $0)) })
        }
        commands.register(Command(id: .activateItem, title: "Open Menu Bar Item", symbol: "cursorarrow.click",
                                  arguments: [CommandArgument(name: "owner", title: "Item")]) { log.invocations.append((.activateItem, $0)) })
        let registrar = FakeRegistrar()
        let controller = HotkeyController(commands: commands, settings: settings, registrar: registrar,
                                          systemCombos: { system }, itemName: { _ in "Wi-Fi" })
        controller.start()
        return (controller, registrar, commands, log, settings)
    }

    @Test func registersDefaultsAndRunsWithHotkeySource() async throws {
        let (controller, registrar, _, log, _) = try make(defaults: ["test.alpha": hideCombo])
        #expect(Set(registrar.registered.values) == [hideCombo])
        #expect(controller.shortcut(for: "test.alpha", arguments: [:]) == hideCombo)
        registrar.press(hideCombo)
        await controller.lastRun?.value
        #expect(log.invocations.count == 1)
        #expect(log.invocations.first?.0 == "test.alpha")
        #expect(log.invocations.first?.1.source == .hotkey)
    }

    @Test func userChangesAndClearsADefault() throws {
        let (controller, registrar, _, _, settings) = try make(defaults: ["test.alpha": hideCombo])
        controller.setShortcut(otherCombo, for: "test.alpha", arguments: [:])
        #expect(Set(registrar.registered.values) == [otherCombo])
        controller.setShortcut(nil, for: "test.alpha", arguments: [:])
        #expect(registrar.registered.isEmpty)
        #expect(settings[HotkeySettings.overrides] == [HotkeyOverride(action: HotkeyAction("test.alpha"), combo: nil)])
        controller.setShortcut(hideCombo, for: "test.alpha", arguments: [:])
        #expect(settings[HotkeySettings.overrides].isEmpty)   // back to following the default
        #expect(Set(registrar.registered.values) == [hideCombo])
    }

    @Test func conflictNamesTheOtherCommandAndRegistersOnlyTheWinner() throws {
        let (controller, registrar, _, _, _) = try make(defaults: ["test.alpha": hideCombo])
        controller.setShortcut(hideCombo, for: "test.beta", arguments: [:])
        #expect(registrar.registered.count == 1)
        #expect(controller.problem(for: "test.alpha", arguments: [:]) == .conflict(HotkeyAction("test.beta")))
        #expect(controller.problem(for: "test.beta", arguments: [:]) == nil)
        #expect(controller.conflictingTitle(for: hideCombo, excluding: "test.gamma", arguments: [:]) != nil)
        #expect(controller.conflictingTitle(for: otherCombo, excluding: "test.gamma", arguments: [:]) == nil)
        let message = HotkeyProblem.conflict(HotkeyAction("test.beta")).message(title: controller.title(for:))
        #expect(message.contains("test.beta"))
    }

    @Test func macOSShortcutsAndRefusalsAreReported() throws {
        let (controller, registrar, _, _, _) = try make(system: [systemCombo])
        registrar.refuse = [otherCombo]
        controller.setShortcut(systemCombo, for: "test.alpha", arguments: [:])
        controller.setShortcut(otherCombo, for: "test.beta", arguments: [:])
        controller.setShortcut(hideCombo, for: "test.gamma", arguments: [:])
        #expect(controller.problem(for: "test.alpha", arguments: [:]) == .reservedBySystem)
        #expect(controller.problem(for: "test.beta", arguments: [:]) == .registrationFailed(OSStatus(eventHotKeyExistsErr)))
        #expect(controller.problem(for: "test.gamma", arguments: [:]) == nil)
        #expect(Set(registrar.registered.values) == [hideCombo])
    }

    @Test func recordingSuspendsEveryShortcut() async throws {
        let (controller, registrar, _, log, _) = try make(defaults: ["test.alpha": hideCombo])
        controller.setRecording(true)
        #expect(registrar.registered.isEmpty)
        registrar.press(hideCombo)
        #expect(log.invocations.isEmpty)
        controller.setRecording(false)
        #expect(Set(registrar.registered.values) == [hideCombo])
    }

    @Test func perItemShortcutRunsItemActivateWithArguments() async throws {
        let (controller, registrar, _, log, _) = try make()
        let action = HotkeyController.itemAction(owner: .system(.wifi), button: .right)
        controller.addItemRow(action)
        #expect(controller.itemActions == [action])
        #expect(registrar.registered.isEmpty)        // no shortcut yet
        controller.setShortcut(otherCombo, for: .activateItem, arguments: action.arguments)
        #expect(controller.title(for: action) == "Right-click Wi-Fi")
        registrar.press(otherCombo)
        await controller.lastRun?.value
        #expect(log.invocations.first?.0 == .activateItem)
        #expect(log.invocations.first?.1.arguments == ["owner": "system:wifi", "button": "right"])
        #expect(log.invocations.first?.1.source == .hotkey)
        controller.setShortcut(nil, for: .activateItem, arguments: action.arguments)
        #expect(controller.itemActions == [action])  // the row stays until removed
        controller.removeRow(action)
        #expect(controller.itemActions.isEmpty)
    }

    @Test func commandsRegisteredLaterPickUpTheirDefault() async throws {
        let (controller, registrar, commands, _, _) = try make()
        commands.register(Command(id: "test.late", title: "Late", symbol: "circle", defaultShortcut: otherCombo) { _ in })
        controller.reload()
        #expect(Set(registrar.registered.values) == [otherCombo])
    }
}

/// The real Carbon path: registers a global hotkey and sends the hotkey-pressed event
/// through the event dispatcher target (no key event is posted).
@Suite(.serialized) struct HotkeyCenterTests {
    @Test func carbonHandlerRunsTheBoundCommand() async throws {
        let suite = "com.alphapengwang.rolltop.tests.\(UUID().uuidString)"
        let settings = SettingsStore(defaults: try #require(UserDefaults(suiteName: suite)))
        let commands = CommandRegistry()
        let log = InvocationLog()
        commands.register(Command(id: "test.carbon", title: "Carbon", symbol: "circle") { log.invocations.append(("test.carbon", $0)) })
        let center = HotkeyCenter()
        defer { center.invalidate() }
        let controller = HotkeyController(commands: commands, settings: settings, registrar: center, systemCombos: { [] })
        controller.start()
        defer { controller.stop() }

        // An obscure combination nobody uses: ⌃⌥⇧⌘F19.
        let combo = KeyCombo(keyCode: UInt16(kVK_F19), modifiers: [.command, .option, .control, .shift])
        controller.setShortcut(combo, for: "test.carbon", arguments: [:])
        #expect(controller.problem(for: "test.carbon", arguments: [:]) == nil)
        let id = try #require(controller.id(for: HotkeyAction("test.carbon")))
        #expect(center.registeredIDs == [id])

        let event = try #require(HotkeyCenter.makePressEvent(id: id))
        let status = SendEventToEventTarget(event, GetEventDispatcherTarget())
        #expect(status == noErr)
        await controller.lastRun?.value
        #expect(controller.lastFired == HotkeyAction("test.carbon"))
        #expect(log.invocations.count == 1)
        #expect(log.invocations.first?.1.source == .hotkey)

        // An event for an id that is not registered is ignored.
        controller.setShortcut(nil, for: "test.carbon", arguments: [:])
        #expect(center.registeredIDs.isEmpty)
        let stale = try #require(HotkeyCenter.makePressEvent(id: id))
        _ = SendEventToEventTarget(stale, GetEventDispatcherTarget())
        #expect(log.invocations.count == 1)
    }
}
