import AppKit
import SwiftUI
import RolltopCore

/// The Rolltop Bar: a glass panel below the menu bar listing hidden items. Registers the
/// `ItemPanelPresenting` service and the reveal router (`RevealRouting`).
final class SecondaryBarFeature: FeatureModule {
    static let id: FeatureID = "secondary-bar"

    private unowned let context: AppContext
    private let presenter: RolltopBarPresenter
    private let router: RolltopBarRevealRouter
    #if DEBUG
    private var previewWindow: NSWindow?
    #endif

    init(context: AppContext) {
        self.context = context
        presenter = RolltopBarPresenter(context: context)
        router = RolltopBarRevealRouter(context: context, presenter: presenter)
        context.services.register(presenter as any ItemPanelPresenting, for: .itemPanel)
        #if DEBUG
        presenter.onDismiss = { [weak self] in
            self?.backdropWindow?.orderOut(nil)
            self?.backdropWindow = nil
            self?.presenter.debugAppearance = nil
        }
        #endif
        context.services.register(router as any RevealRouting, for: .revealRouting)
    }

    func stop() {
        presenter.dismiss(.api)
    }

    var settingsPanes: [SettingsPane] {
        let context = context
        return [SettingsPane(id: "secondary-bar", title: LocalizedStringResource("Rolltop Bar", table: "SecondaryBar"),
                             symbol: "rectangle.topthird.inset.filled", sortOrder: 220,
                             keywords: [LocalizedStringResource("secondary bar, panel, hidden items, below the menu bar, size, idle", table: "SecondaryBar", comment: "Settings search keywords, comma separated")]) {
            RolltopBarSettingsView(context: context)
        }]
    }

    var commands: [Command] {
        var commands: [Command] = []
        #if DEBUG
        commands += [
            // Writes the panel geometry (global top-left points) to
            // ~/Library/Application Support/Rolltop/debug/rolltop-bar.json.
            Command(id: "secondary-bar.debug-dump", title: "Dump Rolltop Bar State", symbol: "ladybug",
                    allowedFromURL: true) { [weak self] _ in
                guard let self else { return }
                try DebugFiles.writeJSON(self.presenter.snapshot(), name: "rolltop-bar.json")
            },
            // Shows (or closes) the settings pane in a plain window: the settings window is
            // another feature's and does not exist on this branch.
            Command(id: "secondary-bar.debug-preview-settings", title: "Preview Rolltop Bar Settings", symbol: "gearshape",
                    allowedFromURL: true) { [weak self] _ in
                self?.togglePreviewWindow()
            },
            // Look checks: presents the panel at a global top-left point (or under Rolltop's
            // item), with the hidden owners or every present owner, an appearance override
            // and an optional solid backdrop window behind it.
            Command(id: "secondary-bar.debug-present", title: "Present Rolltop Bar (Debug)", symbol: "rectangle.topthird.inset.filled",
                    arguments: [
                        CommandArgument(name: "x", title: "X", isRequired: false),
                        CommandArgument(name: "y", title: "Y", isRequired: false),
                        CommandArgument(name: "owners", title: "Owners", isRequired: false, allowedValues: ["hidden", "present"]),
                        CommandArgument(name: "appearance", title: "Appearance", isRequired: false, allowedValues: ["system", "light", "dark"]),
                        CommandArgument(name: "backdrop", title: "Backdrop", isRequired: false, allowedValues: ["none", "light", "dark"]),
                    ],
                    allowedFromURL: true) { [weak self] invocation in
                self?.debugPresent(invocation)
            },
            // Sets Rolltop Bar settings in the running instance (live tests); omitted keys stay.
            Command(id: "secondary-bar.debug-configure", title: "Configure Rolltop Bar", symbol: "slider.horizontal.3",
                    arguments: [
                        CommandArgument(name: "enabled", title: "Enabled", isRequired: false, allowedValues: ["true", "false"]),
                        CommandArgument(name: "idle-timeout", title: "Idle timeout", isRequired: false),
                        CommandArgument(name: "always-hidden", title: "Always hidden", isRequired: false,
                                        allowedValues: AlwaysHiddenPresentation.allCases.map(\.rawValue)),
                        CommandArgument(name: "item-size", title: "Item size", isRequired: false,
                                        allowedValues: RolltopBarItemSize.allCases.map(\.rawValue)),
                        CommandArgument(name: "style", title: "Style", isRequired: false,
                                        allowedValues: RolltopBarStyle.allCases.map(\.rawValue)),
                        CommandArgument(name: "only-with-notch", title: "Only with a notch", isRequired: false, allowedValues: ["true", "false"]),
                        CommandArgument(name: "when-full", title: "When full", isRequired: false, allowedValues: ["true", "false"]),
                    ],
                    allowedFromURL: true) { [weak self] invocation in
                guard let settings = self?.context.settings else { return }
                if let value = invocation.string("enabled") { settings[RolltopBarSettings.enabled] = value == "true" }
                if let raw = invocation.string("idle-timeout") {
                    guard let value = Double(raw), value >= 0 else { throw CommandError.invalidArgument("idle-timeout", raw) }
                    settings[RolltopBarSettings.idleTimeout] = value
                }
                if let value = invocation.string("always-hidden") { settings[RolltopBarSettings.alwaysHidden] = value }
                if let value = invocation.string("item-size") { settings[RolltopBarSettings.itemSize] = value }
                if let value = invocation.string("style") { settings[RolltopBarSettings.style] = value }
                if let value = invocation.string("only-with-notch") { settings[RolltopBarSettings.onlyWithNotch] = value == "true" }
                if let value = invocation.string("when-full") { settings[RolltopBarSettings.whenFull] = value == "true" }
            },
            // Runs a reveal as a click at a global top-left point (x, y) would, without moving
            // the pointer; `overflow` injects macOS's overflow chevron on every display (true),
            // on none (false) or clears the injection (clear). Writes the decision to
            // ~/Library/Application Support/Rolltop/debug/rolltop-bar-route.json. `request=dismiss` closes the panel.
            Command(id: "secondary-bar.debug-route", title: "Route a Reveal (Debug)", symbol: "arrow.triangle.branch",
                    arguments: [
                        CommandArgument(name: "x", title: "X", isRequired: false),
                        CommandArgument(name: "y", title: "Y", isRequired: false),
                        CommandArgument(name: "request", title: "Request", isRequired: false, allowedValues: ["show", "toggle", "collapse", "dismiss"]),
                        CommandArgument(name: "overflow", title: "Overflow", isRequired: false, allowedValues: ["true", "false", "clear"]),
                    ],
                    allowedFromURL: true) { [weak self] invocation in
                guard let self else { return }
                switch invocation.string("overflow") {
                case "true": self.router.debugOverflow = true
                case "false": self.router.debugOverflow = false
                case "clear": self.router.debugOverflow = nil
                default: break
                }
                if invocation.string("request") == "dismiss" { self.presenter.dismiss(.api); return }
                guard let x = invocation.string("x").flatMap(Double.init), let y = invocation.string("y").flatMap(Double.init) else { return }
                let point = ScreenGeometry.appKitPoint(fromTopLeft: CGPoint(x: x, y: y))
                let request: RevealRoutePlanner.Request = switch invocation.string("request") {
                case "toggle": .toggle
                case "collapse": .collapse
                default: .show
                }
                let anchor = PanelAnchor.point(point)
                let screen = RolltopBarRevealRouter.revealScreen(anchor: anchor, gesture: .click, source: .internal)
                self.router.route(request, anchor: anchor, gesture: .click, source: .internal)
                struct Result: Codable { var screen: CGRect?; var notch: Bool; var panel: Bool; var level: String }
                try DebugFiles.writeJSON(Result(screen: screen?.frame, notch: (screen?.safeAreaInsets.top ?? 0) > 0,
                                                panel: self.presenter.isPanelVisible,
                                                level: String(describing: self.context.visibility.level)),
                                         name: "rolltop-bar-route.json")
            },
        ]
        #endif
        return commands
    }

    #if DEBUG
    private var backdropWindow: NSWindow?

    private func debugPresent(_ invocation: CommandInvocation) {
        let anchor: PanelAnchor
        if let x = invocation.string("x").flatMap(Double.init), let y = invocation.string("y").flatMap(Double.init) {
            anchor = .point(ScreenGeometry.appKitPoint(fromTopLeft: CGPoint(x: x, y: y)))
        } else {
            anchor = .statusItem
        }
        let entries = context.catalog.entries
        let content: RolltopBarPresenter.Content
        if invocation.string("owners") == "present" {
            let owners = entries.compactMap { entry -> OwnerID? in
                guard let owner = entry.owner, !entry.isOwn, entry.itemCount > 0 || !entry.slots.isEmpty else { return nil }
                return owner
            }
            content = .init(primary: owners)
        } else {
            content = .init(primary: RevealRoutePlanner.owners(in: .hidden, entries: entries),
                            secondary: RevealRoutePlanner.owners(in: .alwaysHidden, entries: entries), expanded: false)
        }
        presenter.debugAppearance = switch invocation.string("appearance") {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
        presenter.present(content, anchor: anchor, trigger: .other)
        backdropWindow?.orderOut(nil)
        backdropWindow = nil
        if let colour = invocation.string("backdrop"), colour != "none", let frame = presenter.panelFrame {
            let window = NSWindow(contentRect: frame.insetBy(dx: -120, dy: -24), styleMask: [.borderless], backing: .buffered, defer: false)
            window.backgroundColor = colour == "light" ? NSColor(white: 0.97, alpha: 1) : NSColor(white: 0.08, alpha: 1)
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.orderFrontRegardless()
            backdropWindow = window
        }
    }

    private func togglePreviewWindow() {
        if let window = previewWindow {
            window.close()
            previewWindow = nil
            return
        }
        let hosting = NSHostingController(rootView: RolltopBarSettingsView(context: context).frame(width: 520, height: 520))
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "Rolltop Bar", table: "SecondaryBar")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        if let screen = NSScreen.main {
            window.setFrameTopLeftPoint(CGPoint(x: screen.visibleFrame.minX + 80, y: screen.visibleFrame.maxY - 80))
        }
        window.orderFrontRegardless()
        previewWindow = window
    }
    #endif
}
