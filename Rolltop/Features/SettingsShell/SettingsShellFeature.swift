import AppKit
import Foundation
import RolltopCore

/// The settings window (sidebar of every contributed pane), its General, Permissions,
/// Advanced and About panes, and Rolltop's main menu. Registers `services[.settingsWindow]`.
final class SettingsShellFeature: FeatureModule {
    static let id: FeatureID = "settings-shell"

    /// Pane ids, for `app.settings pane=<id>`.
    enum PaneID {
        static let general = "general"
        static let permissions = "permissions"
        static let advanced = "advanced"
        static let about = "about"
    }

    private unowned let context: AppContext
    private let window: SettingsWindowController
    private let launchAtLogin = LaunchAtLogin()
    private var mainMenu: MainMenu?

    init(context: AppContext) {
        self.context = context
        context.settings.markTransient(SettingsShellSettings.lastPane)
        window = SettingsWindowController(context: context)
        context.services.register(window, for: .settingsWindow)
        // Location is shared Platform state (Automations, Weather): its row lives here.
        context.services[.consents].register(SettingsShellLocationConsent.item(context: context))
    }

    func start() {
        let menu = MainMenu { [weak window] pane in window?.showSettings(paneID: pane) }
        menu.install()
        mainMenu = menu
    }

    var settingsPanes: [SettingsPane] {
        let context = context
        let launchAtLogin = launchAtLogin
        return [
            SettingsPane(id: PaneID.general, title: LocalizedStringResource("General", table: "SettingsShell"),
                         symbol: "gearshape", sortOrder: 10,
                         keywords: [LocalizedStringResource("login, startup, launch, new items, default section, menu bar icon, status item, symbol, pinned, keep visible, hide everything", table: "SettingsShell", comment: "Settings search keywords, comma separated")]) {
                GeneralPane(context: context, launchAtLogin: launchAtLogin)
            },
            SettingsPane(id: PaneID.permissions, title: LocalizedStringResource("Permissions", table: "SettingsShell"),
                         symbol: "hand.raised", sortOrder: 910,
                         keywords: [LocalizedStringResource("device control, data access, accessibility, screen recording, system audio, privacy, access, allow", table: "SettingsShell", comment: "Settings search keywords, comma separated")]) {
                PermissionsPane(context: context)
            },
            SettingsPane(id: PaneID.advanced, title: LocalizedStringResource("Advanced", table: "SettingsShell"),
                         symbol: "wrench.and.screwdriver", sortOrder: 920,
                         keywords: [LocalizedStringResource("diagnostics, reset, troubleshoot, debug", table: "SettingsShell", comment: "Settings search keywords, comma separated")]) {
                AdvancedPane(context: context, launchAtLogin: launchAtLogin)
            },
            SettingsPane(id: PaneID.about, title: LocalizedStringResource("About", table: "SettingsShell"),
                         symbol: "info.circle", sortOrder: 990,
                         keywords: [LocalizedStringResource("version, acknowledgments, licenses, credits", table: "SettingsShell", comment: "Settings search keywords, comma separated")]) {
                AboutPane()
            },
        ]
    }

    var commands: [Command] {
        #if DEBUG
        let window = window
        let context = context
        return [
            // Sample consent rows in every status (screenshots); `reset=1` removes them.
            Command(id: "settings-shell.debug-consents", title: LocalizedStringResource("Show Sample Consent Rows", table: "SettingsShell"),
                    symbol: "hand.raised",
                    arguments: [CommandArgument(name: "reset", title: LocalizedStringResource("Reset", table: "SettingsShell"),
                                                isRequired: false)],
                    allowedFromURL: true) { invocation in
                let registry = context.services[.consents]
                if invocation.string("reset") == "1" {
                    SettingsShellConsentSamples.reset(in: registry)
                } else {
                    SettingsShellConsentSamples.register(in: registry)
                }
            },
            // Live tests cannot type: set the sidebar search text.
            Command(id: "settings-shell.debug-search", title: LocalizedStringResource("Set Settings Search Text", table: "SettingsShell"), symbol: "magnifyingglass",
                    arguments: [CommandArgument(name: "query", title: LocalizedStringResource("Text", table: "SettingsShell"), isRequired: false)],
                    allowedFromURL: true) { invocation in
                window.setSearch(invocation.string("query") ?? "")
            },
            // Captures in light and dark without changing the system appearance.
            Command(id: "settings-shell.debug-appearance", title: LocalizedStringResource("Set Settings Window Appearance", table: "SettingsShell"), symbol: "circle.lefthalf.filled",
                    arguments: [CommandArgument(name: "appearance", title: LocalizedStringResource("Appearance", table: "SettingsShell"), allowedValues: ["light", "dark", "system"])],
                    allowedFromURL: true) { invocation in
                switch try invocation.require("appearance") {
                case "light": window.setAppearance(.aqua)
                case "dark": window.setAppearance(.darkAqua)
                default: window.setAppearance(nil)
                }
            },
            // `deactivate=1` also hands activation back to the next app, so the next
            // presentation starts from an inactive Rolltop, as it does for users.
            Command(id: "settings-shell.debug-close", title: LocalizedStringResource("Close Settings Window", table: "SettingsShell"), symbol: "xmark",
                    arguments: [CommandArgument(name: "deactivate", title: LocalizedStringResource("Deactivate", table: "SettingsShell"),
                                                isRequired: false)],
                    allowedFromURL: true) { invocation in
                window.close()
                if invocation.string("deactivate") == "1" { NSApp.hide(nil) }
            },
            // Places Rolltop's visible titled windows (Settings, onboarding) side by side from a
            // top-left point, so captures avoid whatever else is centred on screen.
            Command(id: "settings-shell.debug-place-windows", title: LocalizedStringResource("Place Rolltop Windows", table: "SettingsShell"),
                    symbol: "macwindow",
                    arguments: [CommandArgument(name: "x", title: LocalizedStringResource("Left", table: "SettingsShell")),
                                CommandArgument(name: "y", title: LocalizedStringResource("Top", table: "SettingsShell")),
                                CommandArgument(name: "height", title: LocalizedStringResource("Height", table: "SettingsShell"),
                                                isRequired: false)],
                    allowedFromURL: true) { invocation in
                guard let x = Double(try invocation.require("x")), let y = Double(try invocation.require("y")) else {
                    throw CommandError.invalidArgument("x/y", "")
                }
                let height = invocation.string("height").flatMap(Double.init)
                let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
                var left = x
                for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
                    if let height, window.styleMask.contains(.resizable) {
                        var frame = window.frame
                        frame.size.height = height
                        window.setFrame(frame, display: true)
                    }
                    window.setFrameTopLeftPoint(NSPoint(x: left, y: screenTop - y))
                    left += window.frame.width + 20
                }
            },
        ]
        #else
        return []
        #endif
    }
}
