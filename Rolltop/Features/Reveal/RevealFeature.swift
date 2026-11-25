import AppKit
import Foundation
import RolltopCore

/// Reveal gestures (click on empty menu bar, hover, scroll/swipe), automatic rehide,
/// "make room" and "hide everything". Milestone W1-A.
final class RevealFeature: FeatureModule {
    static let id: FeatureID = "reveal"

    private unowned let context: AppContext
    private let controller: RevealController

    init(context: AppContext) {
        self.context = context
        // A mode switched from the menu, not a preference (`hideEverythingPersists` is).
        context.settings.markTransient(RevealSettings.hideEverything)
        self.controller = RevealController(context: context)
    }

    func start() {
        controller.start()
    }

    func stop() {
        controller.stop()
    }

    var settingsPanes: [SettingsPane] {
        let context = context
        return [
            SettingsPane(id: "reveal", title: LocalizedStringResource("Reveal", table: "Reveal"),
                         symbol: "eye", sortOrder: 210,
                         keywords: [LocalizedStringResource("show hidden items, click, hover, scroll, swipe, gesture, hide automatically, rehide, make room, hide everything, notch", table: "Reveal", comment: "Settings search keywords, comma separated")]) {
                RevealSettingsView(context: context)
            },
        ]
    }

    var commands: [Command] {
        let settings = context.settings
        let controller = controller
        var commands = [
            Command(id: .revealToggleHideEverything,
                    title: LocalizedStringResource("Hide Everything", table: "Reveal"),
                    symbol: "rectangle.dashed", showInStatusMenu: true, allowedFromURL: true,
                    effect: .display,
                    isOn: { settings[RevealSettings.hideEverything] }) { _ in
                controller.toggleHideEverything()
            },
            Command(id: .revealToggleMakeRoom,
                    title: LocalizedStringResource("Make Room When Showing Hidden Items", table: "Reveal"),
                    symbol: "arrow.left.arrow.right", showInStatusMenu: true, allowedFromURL: true,
                    effect: .changesSettings,
                    isOn: { settings[RevealSettings.makeRoom] }) { _ in
                controller.toggleMakeRoom()
            },
            Command(id: .revealKeepRevealed,
                    title: LocalizedStringResource("Show Hidden Items Until Hidden Again", table: "Reveal"),
                    symbol: "pin", allowedFromURL: true,
                    effect: .display) { _ in
                try await controller.keepRevealed()
            },
        ]
        #if DEBUG
        commands += debugCommands
        #endif
        return commands
    }

    #if DEBUG
    /// Live-test hooks. URL-allowed so `scripts/rolltop-cmd.sh` can drive them.
    private var debugCommands: [Command] {
        let context = context
        let controller = controller
        return [
            Command(id: "reveal.debug-set", title: "Reveal: set options (Debug)", symbol: "ladybug",
                    arguments: [
                        CommandArgument(name: "click", title: "Click", isRequired: false),
                        CommandArgument(name: "hover", title: "Hover", isRequired: false),
                        CommandArgument(name: "hover-delay", title: "Hover delay", isRequired: false),
                        CommandArgument(name: "scroll", title: "Scroll", isRequired: false),
                        CommandArgument(name: "scroll-all", title: "Scroll shows always hidden", isRequired: false),
                        CommandArgument(name: "rehide", title: "Rehide delay override (s, 0 = never, clear)", isRequired: false),
                        CommandArgument(name: "click-outside", title: "Click outside", isRequired: false),
                        CommandArgument(name: "app-switch", title: "App switch", isRequired: false),
                        CommandArgument(name: "make-room", title: "Make room", isRequired: false),
                        CommandArgument(name: "make-room-scope", title: "Make room scope", isRequired: false),
                        CommandArgument(name: "reset", title: "Remove every reveal setting", isRequired: false),
                    ],
                    allowedFromURL: true) { invocation in
                let settings = context.settings
                let arguments = invocation.arguments
                func flag(_ name: String) -> Bool? { arguments[name].map { $0 == "1" || $0 == "true" } }
                if invocation.string("reset") == "1" {
                    RevealSettings.resetAll(in: settings)
                    controller.setRehideDelayOverride(nil)
                }
                if let value = flag("click") { settings[RevealSettings.clickEmptySpace] = value }
                if let value = flag("hover") { settings[RevealSettings.hover] = value }
                if let value = invocation.string("hover-delay").flatMap(Double.init) { settings[RevealSettings.hoverDelay] = value }
                if let value = flag("scroll") { settings[RevealSettings.scroll] = value }
                if let value = flag("scroll-all") { settings[RevealSettings.scrollRevealsAlwaysHidden] = value }
                if let value = flag("click-outside") { settings[RevealSettings.rehideOnClickOutside] = value }
                if let value = flag("app-switch") { settings[RevealSettings.rehideOnAppSwitch] = value }
                if let value = flag("make-room") { settings[RevealSettings.makeRoom] = value }
                if let value = invocation.string("make-room-scope") { settings[RevealSettings.makeRoomScope] = value }
                if let raw = invocation.string("rehide") {
                    controller.setRehideDelayOverride(raw == "clear" ? nil : Double(raw))
                }
            },
            Command(id: "reveal.debug-classify", title: "Reveal: classify a point (Debug)", symbol: "ladybug",
                    arguments: [CommandArgument(name: "x", title: "X"), CommandArgument(name: "y", title: "Y")],
                    allowedFromURL: true) { invocation in
                guard let x = Double(try invocation.require("x")), let y = Double(try invocation.require("y")) else {
                    throw CommandError.invalidArgument("x/y", "not a number")
                }
                let point = CGPoint(x: x, y: y)
                await context.catalog.refreshDrawn()
                let hit = await controller.classify(point)
                Log.logger("reveal").notice("debug classify \(RevealController.describe(point)): \(hit.rawValue)")
                try RevealDebugDump.write(controller.debugSnapshot.merging(["lastClassify": "\(Int(x)),\(Int(y)) \(hit.rawValue)"]) { $1 })
            },
            Command(id: "reveal.debug-pin-present", title: "Reveal: pin every present item except (Debug)", symbol: "ladybug",
                    arguments: [CommandArgument(name: "except", title: "Owners, comma separated")],
                    allowedFromURL: true) { invocation in
                let owners = try invocation.require("except").split(separator: ",").compactMap { OwnerID(stringValue: String($0)) }
                await context.catalog.refresh()
                controller.pinPresentOwners(except: Set(owners))
            },
            Command(id: "reveal.debug-restore-pins", title: "Reveal: restore pins (Debug)", symbol: "ladybug",
                    allowedFromURL: true) { _ in
                controller.restoreDebugPins()
            },
            Command(id: "reveal.debug-dump", title: "Reveal: dump state (Debug)", symbol: "ladybug",
                    allowedFromURL: true) { _ in
                try RevealDebugDump.write(controller.debugSnapshot)
            },
        ]
    }
    #endif
}

#if DEBUG
/// Writes `~/Library/Application Support/Rolltop/debug/reveal.json`.
enum RevealDebugDump {
    static func write(_ snapshot: [String: Any]) throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("Rolltop/debug", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var payload = snapshot
        payload["writtenAt"] = ISO8601DateFormatter().string(from: Date())
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("reveal.json"), options: .atomic)
    }
}
#endif
