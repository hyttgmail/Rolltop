import AppKit
import Foundation
import RolltopCore

/// Composition root: builds the platform, engine and app objects, wires them, then
/// creates and starts every feature.
final class AppState {
    let context: AppContext
    private(set) var features: [any FeatureModule] = []
    private let statusItem: StatusItemController
    private let log = Log.logger("app")

    init() {
        let ownBundleIDs: Set<String> = [Bundle.main.bundleIdentifier ?? "com.alphapengwang.rolltop"]
        let permissions = Permissions()
        let settings = SettingsStore()
        let layout = LayoutStore(settings: settings)
        let catalog = ItemCatalog(layoutStore: layout, settings: settings, permissions: permissions, ownBundleIDs: ownBundleIDs)
        let engine = VisibilityEngine(restriction: MenuBarRestriction(), layoutStore: layout, catalog: catalog,
                                      settings: settings, ownBundleIDs: ownBundleIDs)
        catalog.restrictionHeld = { [unowned engine] in engine.isRestrictionHeld }
        let clockBridge = ClockBridge(isRestricted: { [unowned engine] in engine.isRestrictionHeld },
                                      lift: { [unowned engine] in engine.suspend(reason: "clock") },
                                      restore: { [unowned engine] token in engine.endSuspension(token) },
                                      beginInteraction: { [unowned engine] reason in engine.beginInteraction(reason) },
                                      endInteraction: { [unowned engine] token in engine.endInteraction(token) })
        let activator = ItemActivator(engine: engine, catalog: catalog, permissions: permissions, clockBridge: clockBridge)
        let commands = CommandRegistry()
        let services = ServiceLocator()
        let statusItem = StatusItemController(visibility: engine, commands: commands, catalog: catalog, services: services,
                                              settings: settings)
        self.statusItem = statusItem
        let urlRoutes = URLRouteRegistry()
        context = AppContext(settings: settings, layout: layout, catalog: catalog, visibility: engine,
                             activator: activator, clockBridge: clockBridge, permissions: permissions,
                             commands: commands, settingsPanes: SettingsPaneRegistry(), services: services,
                             urlRoutes: urlRoutes,
                             launchInfo: .current(accessibilityTrusted: permissions.accessibility),
                             ownBundleIDs: ownBundleIDs,
                             statusItemFrame: { [unowned statusItem] in statusItem.buttonFrame })
        context.makeCurrent()
    }

    func start() {
        let info = context.launchInfo
        log.notice("launch pid \(info.pid) from \(info.bundlePath) (\(info.launchedByLaunchServices ? "LaunchServices" : "shell, parent \(info.parentPID)")); "
            + "Accessibility trusted: \(info.accessibilityTrustedAtLaunch); restriction API available: \(context.visibility.isAvailable)")
        if !info.runsFromApplications {
            log.error("running outside /Applications: macOS 27 hides this app's status items")
        }

        CoreCommands.register(in: context)
        statusItem.install()
        context.permissions.startMonitoring()
        context.catalog.start()
        context.visibility.start()
        context.clockBridge.start()

        features = FeatureRegistry.all.map { $0.init(context: context) }
        for feature in features {
            context.commands.register(feature.commands)
            feature.settingsPanes.forEach(context.settingsPanes.register)
            feature.settingsSections.forEach { context.settingsPanes.register(section: $0) }
        }
        for feature in features {
            feature.start()
        }
        statusItem.observeState()
        log.info("started \(features.count) features")
        let ids = context.commands.commands.map(\.id.rawValue).sorted()
        log.info("registered \(ids.count) commands: \(ids.joined(separator: " "))")
        #if !DEBUG
        // Debug commands (`debug.*`, `*.debug-*`) exist only in Debug builds.
        let debugIDs = context.commands.commands.map(\.id).filter(\.isDebugOnly)
        if !debugIDs.isEmpty { log.error("Release build registered Debug commands: \(debugIDs)") }
        #endif
    }

    func stop() {
        statusItem.stopObserving()
        for feature in features.reversed() { feature.stop() }
        context.clockBridge.stop()
        context.catalog.stop()
        context.visibility.releaseAll()
        log.notice("stopped; restriction released")
    }

    /// Every link, also one that launched Rolltop, goes through the link gate.
    func open(_ url: URL, sender: LinkSender) {
        context.services[.linkGate].handle(url, sender: sender)
    }

    func showSettings() {
        context.services[.settingsWindow].showSettings(paneID: nil)
    }

    /// A cold start with Rolltop's icon hidden opens Settings, unless it was a login launch or
    /// a link started Rolltop (`StatusItemLaunch`): otherwise the app would run with no visible
    /// way into it.
    func openSettingsIfIconHidden(trigger: StatusItemLaunch.Trigger) {
        let shown = statusItem.isShown
        let opens = StatusItemLaunch.opensSettings(iconShown: shown, trigger: trigger)
        log.notice("launch trigger \(trigger.rawValue); menu bar icon \(shown ? "shown" : "hidden"); "
            + (opens ? "opening Settings" : "not opening Settings"))
        if opens { showSettings() }
    }
}
