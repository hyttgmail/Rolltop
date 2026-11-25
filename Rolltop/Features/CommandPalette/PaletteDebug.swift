#if DEBUG
import AppKit
import Foundation

/// Debug-build commands for live tests. Keys are handed straight to the panel as `NSEvent`s
/// (never posted to the system), through the same handler real key presses reach.
enum PaletteDebugCommands {
    /// Names accepted by `palette.debug-key`.
    static let keys: [String: (code: UInt16, modifiers: NSEvent.ModifierFlags, characters: String)] = [
        "return": (PaletteKeys.Code.returnKey, [], "\r"),
        "shift-return": (PaletteKeys.Code.returnKey, .shift, "\r"),
        "control-return": (PaletteKeys.Code.returnKey, .control, "\r"),
        "command-return": (PaletteKeys.Code.returnKey, .command, "\r"),
        "escape": (PaletteKeys.Code.escape, [], "\u{1b}"),
        "down": (PaletteKeys.Code.down, [], String(UnicodeScalar(NSDownArrowFunctionKey)!)),
        "up": (PaletteKeys.Code.up, [], String(UnicodeScalar(NSUpArrowFunctionKey)!)),
        "control-n": (PaletteKeys.Code.n, .control, "n"),
        "control-p": (PaletteKeys.Code.p, .control, "p"),
        "command-1": (PaletteKeys.Code.digits[0], .command, "1"),
        "command-2": (PaletteKeys.Code.digits[1], .command, "2"),
        "command-w": (PaletteKeys.Code.w, .command, "w"),
        "command-q": (PaletteKeys.Code.q, .command, "q"),
    ]

    static func commands(feature: CommandPaletteFeature) -> [Command] {
        [
            Command(id: "palette.debug-query", title: "Search: set query text (Debug)", symbol: "ladybug",
                    arguments: [CommandArgument(name: "text", title: "Query", isRequired: false)],
                    allowedFromURL: true) { [weak feature] invocation in
                feature?.controller.setQuery(invocation.string("text") ?? "")
            },
            Command(id: "palette.debug-run-selected", title: "Search: run the selected row (Debug)", symbol: "ladybug",
                    arguments: [CommandArgument(name: "button", title: "left | right", isRequired: false,
                                                allowedValues: ["left", "right"])],
                    allowedFromURL: true) { [weak feature] invocation in
                // Exactly what Return (Shift-Return) does: a key event handed to the panel.
                let right = invocation.string("button") == "right"
                feature?.controller.deliverKey(keyCode: PaletteKeys.Code.returnKey, modifiers: right ? .shift : [], characters: "\r")
            },
            Command(id: "palette.debug-key", title: "Search: deliver a key to the panel (Debug)", symbol: "ladybug",
                    arguments: [CommandArgument(name: "key", title: "Key", allowedValues: keys.keys.sorted())],
                    allowedFromURL: true) { [weak feature] invocation in
                guard let key = keys[try invocation.require("key")] else { return }
                feature?.controller.deliverKey(keyCode: key.code, modifiers: key.modifiers, characters: key.characters)
            },
            Command(id: "palette.debug-appearance", title: "Search: force light or dark (Debug)", symbol: "ladybug",
                    arguments: [CommandArgument(name: "mode", title: "light | dark | system", allowedValues: ["light", "dark", "system"])],
                    allowedFromURL: true) { [weak feature] invocation in
                let appearance: NSAppearance? = switch try invocation.require("mode") {
                case "light": NSAppearance(named: .aqua)
                case "dark": NSAppearance(named: .darkAqua)
                default: nil
                }
                feature?.controller.debugAppearance = appearance
            },
            Command(id: "palette.debug-dump", title: "Search: dump state (Debug)", symbol: "ladybug",
                    allowedFromURL: true) { [weak feature] _ in
                guard let feature else { return }
                try DebugFiles.writeJSON(feature.controller.snapshot(), name: "palette.json")
            },
            // Rows "Sample with second action" (⌘↩ Paste) and "Sample without second action";
            // their actions only count runs (`palette.debug-dump` shows `lastRun`).
            Command(id: "palette.debug-sample-rows", title: "Search: add sample provider rows (Debug)", symbol: "ladybug",
                    arguments: [CommandArgument(name: "remove", title: "Remove", isRequired: false, allowedValues: ["1"])],
                    allowedFromURL: true) { [weak feature] invocation in
                guard let feature else { return }
                let registry = feature.context.services[.paletteResultProviders]
                if invocation.string("remove") == "1" {
                    registry.unregister(id: PaletteDebugSampleProvider.providerID)
                } else {
                    registry.register(PaletteDebugSampleProvider())
                }
            },
        ]
    }
}

/// Sample rows for live checks of the second action; nothing they run touches anything.
final class PaletteDebugSampleProvider: PaletteResultProviding {
    static let providerID = "palette.debug-sample"
    let id = providerID
    let title = "Sample"
    private(set) var mainRuns = 0
    private(set) var secondRuns = 0

    func results(for query: String) -> [PaletteProvidedResult] {
        guard query.lowercased().hasPrefix("sam") else { return [] }
        return [
            PaletteProvidedResult(id: "with", title: "Sample with second action", subtitle: "⌘↩ runs the second action",
                                  icon: .symbol("doc.on.clipboard"),
                                  alternateAction: PaletteAlternateAction(title: "Paste") { [weak self] in
                                      self?.secondRuns += 1
                                  }) { [weak self] in self?.mainRuns += 1 },
            PaletteProvidedResult(id: "without", title: "Sample without second action", icon: .symbol("doc")) { [weak self] in
                self?.mainRuns += 1
            },
        ]
    }
}
#endif
