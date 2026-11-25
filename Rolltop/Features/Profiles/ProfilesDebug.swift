#if DEBUG
import AppKit
import RolltopCore
import SwiftUI

/// Debug-build commands for live tests: export/import without panels, delete from a URL,
/// a JSON dump, and the pane in a plain window (the settings window is another feature).
enum ProfilesDebugCommands {
    static func commands(controller: ProfilesController, context: AppContext) -> [Command] {
        [
            Command(id: "profiles.debug-export", title: "Export Profile to Path", symbol: "square.and.arrow.up",
                    arguments: [CommandArgument(name: "id", title: "Profile"), CommandArgument(name: "path", title: "Path")],
                    allowedFromURL: true) { invocation in
                let url = try DebugFiles.inputURL(try invocation.require("path"))
                try controller.exportData(id: try invocation.require("id")).write(to: url, options: .atomic)
            },
            Command(id: "profiles.debug-import", title: "Import Profile from Path", symbol: "square.and.arrow.down",
                    arguments: [CommandArgument(name: "path", title: "Path")], allowedFromURL: true) { invocation in
                let url = try DebugFiles.inputURL(try invocation.require("path"))
                try controller.importData(try Data(contentsOf: url))
            },
            Command(id: "profiles.debug-delete", title: "Delete Profile", symbol: "trash",
                    arguments: [CommandArgument(name: "id", title: "Profile")], allowedFromURL: true) { invocation in
                controller.delete(id: try invocation.require("id"))
            },
            Command(id: "profiles.debug-dump", title: "Dump Profiles", symbol: "ladybug", allowedFromURL: true) { _ in
                try dump(controller: controller)
            },
            Command(id: "profiles.debug-window", title: "Show Profiles Pane in a Window", symbol: "macwindow",
                    arguments: [CommandArgument(name: "edit", title: "Profile to edit", isRequired: false)],
                    allowedFromURL: true) { invocation in
                ProfilesDebugWindow.shared.show(context: context, controller: controller, editing: invocation.string("edit"))
            },
            Command(id: "profiles.debug-window-close", title: "Close Profiles Pane Window", symbol: "xmark",
                    allowedFromURL: true) { _ in
                ProfilesDebugWindow.shared.close()
            },
        ]
    }

    /// Absolute `.json` paths only (debug builds).
    struct Dump: Encodable {
        struct Entry: Encodable {
            let id: String
            let name: String
            let symbol: String
            let layout: [String: String]
            let defaultSection: String
            let settingsPrefixes: [String]
            let applyAtLaunch: Bool
            let displayRule: ProfileDisplayRule?
        }
        let writtenAt: Date
        let directory: String
        let activeProfileID: String?
        let activeModified: Bool
        let lastApplyReason: String?
        let currentLayout: [String: String]
        let displays: [ProfileDisplay]
        let commands: [String]
        let profiles: [Entry]
    }

    static func dump(controller: ProfilesController) throws {
        let flatten = { (layout: RolltopCore.Layout) in Dictionary(uniqueKeysWithValues: layout.sections.map { ($0.key.stringValue, $0.value.rawValue) }) }
        let dump = Dump(writtenAt: Date(), directory: controller.store.directory.path,
                        activeProfileID: controller.activeProfileID, activeModified: controller.isActiveModified,
                        lastApplyReason: controller.lastApplyReason?.rawValue,
                        currentLayout: flatten(AppContext.current?.layout.layout ?? .empty),
                        displays: ProfileDisplayWatcher.current().displays,
                        commands: (AppContext.current?.commands.commands ?? []).map(\.id.rawValue).filter { $0.hasPrefix("profiles.") },
                        profiles: controller.all.map {
                            Dump.Entry(id: $0.id, name: $0.name, symbol: $0.symbol, layout: flatten($0.layout),
                                       defaultSection: $0.layout.defaultSection.rawValue, settingsPrefixes: $0.settingsPrefixes,
                                       applyAtLaunch: $0.applyAtLaunch, displayRule: $0.displayRule)
                        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Rolltop/debug/profiles.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(dump).write(to: url, options: .atomic)
    }
}

/// A plain window hosting the pane at a fixed frame (top-left of the main screen, 80 pt
/// in) so screenshots can use known coordinates. Debug builds only.
final class ProfilesDebugWindow {
    static let shared = ProfilesDebugWindow()
    static let size = CGSize(width: 660, height: 720)
    private var window: NSWindow?

    func show(context: AppContext, controller: ProfilesController, editing: String?) {
        close()
        // The editor is shown as the window's content (not a sheet) so one window capture holds it.
        let profile = editing.flatMap(controller.profile(id:))
        let size = profile == nil ? Self.size : CGSize(width: 480, height: 620)
        let view: AnyView = if let profile {
            AnyView(ProfileEditorSheet(draft: profile, controller: controller) { [weak self] in self?.close() }
                .frame(width: size.width, height: size.height))
        } else {
            AnyView(ProfilesSettingsView(context: context, controller: controller)
                .frame(width: size.width, height: size.height))
        }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = String(localized: "Profiles", table: "Profiles")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        if let screen = NSScreen.main {
            window.setFrameTopLeftPoint(CGPoint(x: screen.frame.minX + 80, y: screen.visibleFrame.maxY - 40))
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
        writeFrame(window)
    }

    func close() {
        window?.close()
        window = nil
    }

    /// `debug/profiles-window.json`: the window frame in top-left screen coordinates.
    private func writeFrame(_ window: NSWindow) {
        let frame = ScreenGeometry.topLeftRect(fromAppKit: window.frame)
        let text = "{\"x\":\(Int(frame.minX)),\"y\":\(Int(frame.minY)),\"w\":\(Int(frame.width)),\"h\":\(Int(frame.height)),\"windowNumber\":\(window.windowNumber)}"
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Rolltop/debug/profiles-window.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url, options: .atomic)
    }
}
#endif
