import AppKit
import Foundation
import RolltopCore

/// Global keyboard shortcuts bound to commands (Carbon `RegisterEventHotKey`), per-item
/// "show and click" shortcuts, and the `.hotkeyBindings` service. Milestone W1-A.
final class HotkeysFeature: FeatureModule {
    static let id: FeatureID = "hotkeys"

    private unowned let context: AppContext
    private let center = HotkeyCenter()
    private let controller: HotkeyController
    #if DEBUG
    private var preview: HotkeysDebugPreview?
    #endif

    init(context: AppContext) {
        self.context = context
        let catalog = context.catalog
        controller = HotkeyController(commands: context.commands, settings: context.settings, registrar: center,
                                      itemName: { catalog.displayName(for: $0) })
        context.services.register(controller, for: .hotkeyBindings)
    }

    func start() {
        center.install()
        controller.start()
    }

    func stop() {
        controller.stop()
        center.invalidate()
    }

    var settingsPanes: [SettingsPane] {
        let context = context
        let controller = controller
        return [
            SettingsPane(id: "hotkeys", title: LocalizedStringResource("Shortcuts", table: "Hotkeys"),
                         symbol: "command", sortOrder: 250,
                         keywords: [LocalizedStringResource("keyboard, hotkeys, keys, global shortcuts, item shortcuts", table: "Hotkeys", comment: "Settings search keywords, comma separated")]) {
                HotkeysSettingsView(context: context, controller: controller)
            },
        ]
    }

    #if DEBUG
    var commands: [Command] {
        [
            Command(id: "hotkeys.debug-preview", title: "Shortcuts: preview panes (Debug)", symbol: "ladybug",
                    arguments: [CommandArgument(name: "pane", title: "hotkeys | reveal | recorder | close",
                                                allowedValues: ["hotkeys", "reveal", "recorder", "close"])],
                    allowedFromURL: true) { [weak self] invocation in
                guard let self else { return }
                let pane = try invocation.require("pane")
                if self.preview == nil { self.preview = HotkeysDebugPreview(context: self.context, controller: self.controller) }
                self.preview?.show(pane)
            },
            Command(id: "hotkeys.debug-bind", title: "Shortcuts: bind (Debug)", symbol: "ladybug",
                    arguments: [
                        CommandArgument(name: "command", title: "Command id"),
                        CommandArgument(name: "key", title: "Virtual key code", isRequired: false),
                        CommandArgument(name: "mods", title: "cmd,opt,ctrl,shift", isRequired: false),
                        CommandArgument(name: "owner", title: "Item owner (item.activate)", isRequired: false),
                        CommandArgument(name: "button", title: "left | right (item.activate)", isRequired: false),
                    ],
                    allowedFromURL: true) { [weak self] invocation in
                guard let self else { return }
                let arguments = invocation.arguments
                let command = CommandID(try invocation.require("command"))
                var actionArguments: [String: String] = [:]
                if let owner = arguments["owner"] { actionArguments["owner"] = owner }
                if let button = arguments["button"] { actionArguments["button"] = button }
                var combo: KeyCombo?
                if let key = arguments["key"].flatMap(UInt16.init) {
                    var modifiers: KeyModifiers = []
                    for name in (arguments["mods"] ?? "").split(separator: ",") {
                        switch name {
                        case "cmd": modifiers.insert(.command)
                        case "opt": modifiers.insert(.option)
                        case "ctrl": modifiers.insert(.control)
                        case "shift": modifiers.insert(.shift)
                        default: break
                        }
                    }
                    combo = KeyCombo(keyCode: key, modifiers: modifiers)
                }
                if command == .activateItem, let owner = actionArguments["owner"].flatMap(OwnerID.init(stringValue:)) {
                    let button = ItemActivator.Button(rawValue: actionArguments["button"] ?? "left") ?? .left
                    self.controller.addItemRow(HotkeyController.itemAction(owner: owner, button: button))
                }
                self.controller.setShortcut(combo, for: command, arguments: actionArguments)
            },
            Command(id: "hotkeys.debug-reset", title: "Shortcuts: remove stored bindings (Debug)", symbol: "ladybug",
                    allowedFromURL: true) { [weak self] _ in
                guard let self else { return }
                self.context.settings.reset(HotkeySettings.overrides)
                self.controller.reload(force: true)
            },
        ]
    }
    #endif
}
