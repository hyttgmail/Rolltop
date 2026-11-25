#if DEBUG
import AppKit
import Foundation
import RolltopCore
import SwiftUI

/// Debug-only commands for live tests: set a style without the pane, dump what the
/// overlays do, host any settings pane in a plain window (the settings window is
/// another feature), and remove every appearance key.
enum AppearanceDebugCommands {
    static func make(context: AppContext, store: AppearanceStore, controller: AppearanceController) -> [Command] {
        [
            Command(id: "appearance.debug-style", title: "Debug: Set Menu Bar Style", symbol: "ladybug",
                    arguments: [
                        CommandArgument(name: "kind", title: "Kind", isRequired: false, allowedValues: StyleKind.allCases.map(\.rawValue)),
                        CommandArgument(name: "shape", title: "Shape", isRequired: false, allowedValues: BarShape.allCases.map(\.rawValue)),
                        CommandArgument(name: "notch", title: "Split around notch", isRequired: false, allowedValues: ["on", "off"]),
                        CommandArgument(name: "border", title: "Border", isRequired: false, allowedValues: ["on", "off"]),
                        CommandArgument(name: "shadow", title: "Shadow", isRequired: false, allowedValues: ["on", "off"]),
                        CommandArgument(name: "radius", title: "Corner radius", isRequired: false),
                        CommandArgument(name: "per-display", title: "Per display", isRequired: false, allowedValues: ["on", "off"]),
                        CommandArgument(name: "display", title: "Display", isRequired: false, allowedValues: ["main", "other"]),
                        CommandArgument(name: "preset", title: "Preset", isRequired: false, allowedValues: AppearancePresets.ids),
                        // space=current|<id>: edit that desktop's own style on `display` (default main).
                        CommandArgument(name: "space", title: "Space", isRequired: false),
                        CommandArgument(name: "corners", title: "Screen corners", isRequired: false, allowedValues: ["on", "off"]),
                        CommandArgument(name: "below-bar", title: "Corners below the bar", isRequired: false, allowedValues: ["on", "off"]),
                        CommandArgument(name: "corner-radius", title: "Screen corner radius", isRequired: false),
                    ],
                    allowedFromURL: true) { invocation in
                if let raw = invocation.string("per-display") { store.perDisplay = raw == "on" }
                // display=main|other edits that display's own style (turns per-display on).
                var scope = AppearanceScope.allDisplays
                if let raw = invocation.string("display") {
                    let screens = NSScreen.screens
                    let screen = raw == "main" ? screens.first : screens.dropFirst().first
                    guard let identity = screen?.rolltopDisplayIdentity else { throw CommandError.invalidArgument("display", raw) }
                    if !store.perDisplay { store.perDisplay = true }
                    scope = .display(identity)
                }
                if let raw = invocation.string("space") {
                    let screens = NSScreen.screens
                    let screen = invocation.string("display") == "other" ? screens.dropFirst().first : screens.first
                    guard let identity = screen?.rolltopDisplayIdentity else { throw CommandError.invalidArgument("display", "") }
                    let current = controller.simulatedSpaces[identity.key] ?? controller.currentSpaces[identity.key]
                    guard let spaceID = raw == "current" ? current : raw else { throw CommandError.invalidArgument("space", raw) }
                    scope = .space(display: identity, spaceID: spaceID, fallback: store.perDisplay ? .display : .allDisplays)
                }
                var corners = store.corners
                if let raw = invocation.string("corners") { corners.screenCorners = raw == "on" }
                if let raw = invocation.string("below-bar") { corners.belowMenuBar = raw == "on" }
                if let raw = invocation.string("corner-radius") {
                    guard let radius = Double(raw) else { throw CommandError.invalidArgument("corner-radius", raw) }
                    corners.radius = radius
                }
                if corners != store.corners { store.corners = corners }
                // Corner arguments alone leave the bar style as it is.
                let styleArguments = ["kind", "shape", "notch", "border", "shadow", "radius", "per-display", "display", "preset", "space"]
                let cornerArguments = ["corners", "below-bar", "corner-radius"]
                if !styleArguments.contains(where: { invocation.string($0) != nil }),
                   cornerArguments.contains(where: { invocation.string($0) != nil }) { return }
                var style = store.style(for: scope)
                if let raw = invocation.string("preset") {
                    guard let preset = AppearancePresets.preset(id: raw) else { throw CommandError.invalidArgument("preset", raw) }
                    style = preset.style
                }
                if let raw = invocation.string("kind") {
                    guard let kind = StyleKind(rawValue: raw) else { throw CommandError.invalidArgument("kind", raw) }
                    style.kind = kind
                }
                if let raw = invocation.string("shape") {
                    guard let shape = BarShape(rawValue: raw) else { throw CommandError.invalidArgument("shape", raw) }
                    style.shape = shape
                }
                if let raw = invocation.string("notch") { style.splitAroundNotch = raw == "on" }
                if let raw = invocation.string("border") { style.border.isEnabled = raw == "on" }
                if let raw = invocation.string("shadow") { style.shadow.isEnabled = raw == "on" }
                if let raw = invocation.string("radius") {
                    guard let radius = Double(raw) else { throw CommandError.invalidArgument("radius", raw) }
                    style.cornerRadius = radius
                }
                store.setStyle(style, for: scope)
                store.isEnabled = true
            },
            // Stands in for "the current Space of `display` is `space`" (clear=1 removes every stand-in).
            Command(id: "appearance.debug-space", title: "Debug: Simulate Current Space", symbol: "ladybug",
                    arguments: [
                        CommandArgument(name: "display", title: "Display", isRequired: false, allowedValues: ["main", "other"]),
                        CommandArgument(name: "space", title: "Space", isRequired: false),
                        CommandArgument(name: "clear", title: "Clear", isRequired: false),
                    ],
                    allowedFromURL: true) { invocation in
                if invocation.string("clear") != nil {
                    controller.simulatedSpaces = [:]
                    return
                }
                let screens = NSScreen.screens
                let screen = invocation.string("display") == "other" ? screens.dropFirst().first : screens.first
                guard let identity = screen?.rolltopDisplayIdentity else { throw CommandError.invalidArgument("display", "") }
                controller.simulatedSpaces[identity.key] = try invocation.require("space")
            },
            Command(id: "appearance.debug-reset", title: "Debug: Remove Appearance Settings", symbol: "ladybug",
                    allowedFromURL: true) { _ in
                store.removeAll()
            },
            Command(id: "appearance.debug-dump", title: "Debug: Dump Appearance State", symbol: "ladybug",
                    allowedFromURL: true) { _ in
                try AppearanceDebugDump.write(controller: controller, store: store)
            },
            Command(id: "appearance.debug-host-pane", title: "Debug: Show Settings Pane", symbol: "ladybug",
                    arguments: [CommandArgument(name: "id", title: "Pane")],
                    allowedFromURL: true) { invocation in
                let id = try invocation.require("id")
                guard let pane = context.settingsPanes.pane(id) else { throw CommandError.invalidArgument("id", id) }
                DebugPaneHost.show(pane)
            },
            Command(id: "appearance.debug-close-pane", title: "Debug: Close Settings Pane", symbol: "ladybug",
                    allowedFromURL: true) { _ in
                DebugPaneHost.close()
            },
        ]
    }
}

/// A plain window hosting one settings pane (the settings window belongs to SettingsShell).
enum DebugPaneHost {
    private static var window: NSWindow?

    static func show(_ pane: SettingsPane) {
        close()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 760),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = String(localized: pane.title)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: pane.makeView().frame(width: 560, height: 760))
        window.center()
        window.orderFrontRegardless()
        self.window = window
    }

    static func close() {
        window?.close()
        window = nil
    }

    static var windowNumber: Int? { window?.windowNumber }
}

/// `appearance.debug-dump`: `~/Library/Application Support/Rolltop/debug/appearance.json`.
enum AppearanceDebugDump {
    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Rolltop/debug/appearance.json")
    }

    static func write(controller: AppearanceController, store: AppearanceStore) throws {
        func rect(_ r: CGRect?) -> Any { r.map { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] } ?? NSNull() }
        let config = store.configuration
        let styleJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config.style))
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownWindows = WindowList.onScreen().filter { $0.ownerPID == ownPID }.map { window -> [String: Any] in
            ["id": window.windowID, "layer": window.layer, "bounds": rect(window.bounds)]
        }
        let displays = controller.displayStates.map { state -> [String: Any] in
            [
                "key": state.identity.key,
                "name": state.identity.name,
                "displayID": state.identity.displayID,
                "barFrame": rect(state.barFrame),
                "notch": state.notch.map { [$0.lowerBound, $0.upperBound] } ?? NSNull(),
                "appMenusMaxX": state.appMenusMaxX ?? NSNull(),
                "statusItemsMinX": state.statusItemsMinX ?? NSNull(),
                "appearance": state.appearance.appearance.rawValue,
                "appearanceSource": state.appearance.source,
                "shape": state.shape?.rawValue ?? NSNull(),
                "segments": state.segments.map { ["role": $0.role.rawValue, "frame": rect($0.frame), "corners": [$0.corners.topLeading, $0.corners.bottomLeading, $0.corners.bottomTrailing, $0.corners.topTrailing]] },
                "isShown": state.isShown,
                "hiddenReason": state.hiddenReason ?? NSNull(),
                "windowNumber": state.windowNumber ?? NSNull(),
                "spaceID": state.spaceID ?? NSNull(),
            ]
        }
        let statusWindows = MenuBarAppearanceProbe.statusBarWindows().map { window -> [String: Any] in
            ["class": NSStringFromClass(type(of: window)), "screen": window.screen?.localizedName ?? NSNull(),
             "frame": rect(window.frame), "appearance": window.effectiveAppearance.name.rawValue]
        }
        let settings = controller.systemSettings
        let spaces: Any = ManagedSpaces.read().map { lists in
            lists.map { list -> [String: Any] in
                ["displayKey": list.displayKey, "currentID": list.currentID ?? NSNull(),
                 "spaces": list.spaces.map { ["id": $0.id, "kind": $0.kind.rawValue] }]
            }
        } ?? "unavailable"
        let cornerJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.corners))
        let spaceStyles = store.spaceStyles.mapValues { styles in styles.mapValues { $0.kind.rawValue } }
        let snapshot: [String: Any] = [
            "spaces": spaces,
            "currentSpaces": controller.currentSpaces,
            "simulatedSpaces": controller.simulatedSpaces,
            "spaceStyleKinds": spaceStyles,
            "corners": cornerJSON,
            "cornerWindows": controller.cornerPanels.map { panel -> [String: Any] in
                ["id": panel.windowNumber, "corner": panel.corner.rawValue, "level": panel.level.rawValue,
                 "ignoresMouseEvents": panel.ignoresMouseEvents, "frame": rect(panel.frame)]
            },
            "writtenAt": ISO8601DateFormatter().string(from: Date()),
            "enabled": config.isEnabled,
            "perDisplay": config.perDisplay,
            "style": styleJSON,
            "running": controller.isRunning,
            "systemSettings": ["showsBackground": settings.showsBackground, "hidesAutomatically": settings.hidesAutomatically,
                               "reducesTransparency": settings.reducesTransparency],
            "systemAppearance": NSApp.effectiveAppearance.name.rawValue,
            "displays": displays,
            "statusBarWindows": statusWindows,
            "ownWindows": ownWindows,
            "paneWindowNumber": DebugPaneHost.windowNumber ?? NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
#endif
