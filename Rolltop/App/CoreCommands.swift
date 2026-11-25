import AppKit
import Foundation
import RolltopCore

/// Commands owned by the shared core. Features add theirs through `FeatureModule.commands`.
enum CoreCommands {
    static func register(in context: AppContext) {
        let visibility = context.visibility
        let layout = context.layout

        // toggle-hidden / show-hidden / collapse go through the reveal router (inline by
        // default; the Rolltop Bar when the SecondaryBar feature's setting is on).
        let anchorArgument = CommandArgument(name: "anchor", title: "Anchor", isRequired: false,
                                             allowedValues: RevealAnchorArgument.allowedValues)
        let gestureArgument = CommandArgument(name: "gesture", title: "Gesture", isRequired: false,
                                              allowedValues: RevealGesture.allCases.map(\.rawValue))

        context.commands.register([
            Command(id: .toggleHidden, title: "Toggle Hidden Items", symbol: "eye", arguments: [anchorArgument, gestureArgument],
                    allowedFromURL: true, effect: .display,
                    isOn: { context.services[.revealRouting].isHiddenPresented }) { invocation in
                let anchor = try RevealAnchorArgument.anchor(for: invocation)
                context.services[.revealRouting].toggleHidden(anchor: anchor, gesture: try RevealAnchorArgument.gesture(for: invocation),
                                                              source: invocation.source)
            },
            Command(id: .toggleAll, title: "Toggle All Items", symbol: "eye.circle",
                    allowedFromURL: true, effect: .display,
                    isOn: { visibility.level == .allRevealed }) { _ in
                visibility.toggle(.allRevealed)
            },
            Command(id: .showHidden, title: "Show Hidden Items", symbol: "eye", arguments: [anchorArgument, gestureArgument],
                    allowedFromURL: true,
                    effect: .display) { invocation in
                let anchor = try RevealAnchorArgument.anchor(for: invocation)
                context.services[.revealRouting].showHidden(anchor: anchor, gesture: try RevealAnchorArgument.gesture(for: invocation),
                                                            source: invocation.source)
            },
            Command(id: .showAll, title: "Show All Items", symbol: "eye.circle", allowedFromURL: true,
                    effect: .display) { _ in
                visibility.show(.allRevealed)
            },
            Command(id: .collapse, title: "Hide Items", symbol: "eye.slash", allowedFromURL: true,
                    effect: .display) { _ in
                context.services[.revealRouting].collapse()
            },
            Command(id: .setSection, title: "Move Item to Section", symbol: "rectangle.split.3x1",
                    arguments: [
                        CommandArgument(name: "owner", title: "Item"),
                        CommandArgument(name: "section", title: "Section",
                                        allowedValues: Section.allCases.map(\.rawValue) + ["default"]),
                    ],
                    allowedFromURL: true,
                    effect: .changesSettings) { invocation in
                let owner = try invocation.owner()
                let raw = try invocation.require("section")
                if raw == "default" {
                    layout.setSection(nil, for: owner)
                } else {
                    guard let section = Section(argument: raw) else { throw CommandError.invalidArgument("section", raw) }
                    layout.setSection(section, for: owner)
                }
            },
            Command(id: .setDefaultSection, title: "Set Section for New Items", symbol: "rectangle.badge.plus",
                    arguments: [CommandArgument(name: "section", title: "Section", allowedValues: Section.allCases.map(\.rawValue))],
                    allowedFromURL: true,
                    effect: .changesSettings) { invocation in
                let raw = try invocation.require("section")
                guard let section = Section(argument: raw) else { throw CommandError.invalidArgument("section", raw) }
                // Items already in the bar keep their section; only new owners follow the default.
                layout.setDefaultSection(section, freezing: context.catalog.presentOwners)
            },
            Command(id: .activateItem, title: "Open Menu Bar Item", symbol: "cursorarrow.click",
                    arguments: [
                        CommandArgument(name: "owner", title: "Item"),
                        CommandArgument(name: "button", title: "Button", isRequired: false,
                                        allowedValues: ItemActivator.Button.allCases.map(\.rawValue)),
                        CommandArgument(name: "index", title: "Index", isRequired: false),
                    ],
                    allowedFromURL: true,
                    effect: .display) { invocation in
                let owner = try invocation.owner()
                let button = try invocation.string("button").map { raw in
                    guard let button = ItemActivator.Button(rawValue: raw) else { throw CommandError.invalidArgument("button", raw) }
                    return button
                } ?? .left
                let index = try invocation.string("index").map { raw in
                    guard let index = Int(raw), index >= 0 else { throw CommandError.invalidArgument("index", raw) }
                    return index
                } ?? 0
                try await context.activator.activate(owner, button: button, index: index)
            },
            Command(id: .openSettings, title: "Settings…", symbol: "gearshape", allowedFromURL: true,
                    effect: .display) { invocation in
                context.services[.settingsWindow].showSettings(paneID: invocation.string("pane"))
            },
            // Shows or hides Rolltop's own icon (Settings › General). It writes a setting, so a
            // link runs it only with "Allow links that change settings"; `rolltop://settings`
            // (a display command) is the link that brings Settings back.
            Command(id: StatusItemVisibility.toggleCommand, title: "Toggle Rolltop Icon", symbol: "menubar.rectangle",
                    allowedFromURL: true, effect: .changesSettings,
                    isOn: { context.settings[StatusItemVisibility.setting] }) { _ in
                StatusItemVisibility.set(!context.settings[StatusItemVisibility.setting], in: context.settings)
            },
            Command(id: .quit, title: "Quit Rolltop", symbol: "power", allowedFromURL: true,
                    effect: .display) { _ in
                AppTermination.quit()
            },
        ])

        #if DEBUG
        context.commands.register([
            Command(id: .dumpState, title: "Dump Debug State", symbol: "ladybug", allowedFromURL: true) { _ in
                await context.catalog.refresh()
                try DebugState.write(context)
            },
            Command(id: "debug.set-clock-mode", title: "Set Clock Bridge Mode", symbol: "clock",
                    arguments: [CommandArgument(name: "mode", title: "Mode", allowedValues: ["after-press", "after-panel-closes"])],
                    allowedFromURL: true) { invocation in
                guard let mode = ClockBridge.RestoreMode(rawValue: try invocation.require("mode")) else { return }
                context.clockBridge.restoreMode = mode
            },
        ])
        #endif
    }
}

/// The optional `anchor` argument of the reveal commands: `pointer` or `status-item`.
/// Without one, a run from the status menu anchors to the status item, anything else to
/// the pointer.
enum RevealAnchorArgument {
    static let pointer = "pointer"
    static let statusItem = "status-item"
    static let allowedValues = [pointer, statusItem]

    static func anchor(for invocation: CommandInvocation,
                       pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }) throws -> PanelAnchor {
        switch invocation.string("anchor") {
        case nil, "": invocation.source == .statusMenu ? .statusItem : .point(pointerLocation())
        case pointer: .point(pointerLocation())
        case statusItem: .statusItem
        case let other?: throw CommandError.invalidArgument("anchor", other)
        }
    }

    /// The optional `gesture` argument (`click`, `hover`, `scroll`).
    static func gesture(for invocation: CommandInvocation) throws -> RevealGesture? {
        guard let raw = invocation.string("gesture"), !raw.isEmpty else { return nil }
        guard let gesture = RevealGesture(rawValue: raw) else { throw CommandError.invalidArgument("gesture", raw) }
        return gesture
    }
}
