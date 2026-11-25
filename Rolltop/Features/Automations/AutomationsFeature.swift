import AppKit
import Foundation
import RolltopCore

/// Rules ("show the battery item on battery power", "apply the meeting profile during work
/// hours") whose conditions are watched live and whose actions force items visible, apply
/// profiles or run commands.
final class AutomationsFeature: FeatureModule {
    static let id: FeatureID = "automations"

    private unowned let context: AppContext
    let controller: AutomationsController
    /// The shared location wrapper (`.location`), never replaced after launch.
    let location: any LocationProviding
    /// Location updates for place conditions; started only by the live sources.
    let placeTracker: AutomationPlaceTracker
    private var sources: AutomationLiveSources?
    private var registeredRuleIDs: [String]?

    init(context: AppContext) {
        self.context = context
        let location = context.services[.location]
        self.location = location
        context.settings.markTransient(AutomationsSettings.activeRules)
        context.settings.markTransient(AutomationsSettings.profileLedger)
        let effects = AutomationEffects(
            setForcedVisible: { [unowned context] owners, source in context.visibility.setForcedVisible(owners, source: source) },
            activeProfileID: { [unowned context] in context.services[.profiles].activeProfileID },
            profileIDs: { [unowned context] in Set(context.services[.profiles].profiles.map(\.id)) },
            applyProfile: { [unowned context] id in try context.services[.profiles].applyProfile(id: id) },
            currentLayout: { [unowned context] in context.layout.layout },
            restoreLayout: { [unowned context] layout in
                context.services[.profileLayoutRestorer].restoreLayout(layout, activeProfileID: nil)
            },
            runCommand: { [unowned context] call in
                try await context.commands.run(call.id, arguments: call.arguments, source: .automation)
            })
        controller = AutomationsController(settings: context.settings, effects: effects,
                                           approvals: AutomationScriptApprovals(fileURL: AutomationScriptApprovals.defaultURL))
        placeTracker = AutomationPlaceTracker(location: location) { [controller] fix in controller.updateLocation(fix) }
        context.services[.backupParticipants].register(AutomationsBackupParticipant(settings: context.settings))
    }

    func start() {
        controller.onRulesChanged = { [weak self] in self?.rulesChanged() }
        controller.load()
        let sources = AutomationLiveSources(context: context, controller: controller, location: location,
                                            placeTracker: placeTracker)
        sources.start()
        self.sources = sources
        controller.startScripts()
        controller.evaluateNow()
    }

    func stop() {
        sources?.stop()
        controller.stop()
    }

    var settingsPanes: [SettingsPane] {
        [SettingsPane(id: "automations", title: LocalizedStringResource("Automations", table: "Automations"),
                      symbol: "bolt.badge.clock", sortOrder: 410,
                      keywords: [LocalizedStringResource("rules, triggers, conditions, battery, power, wi-fi, network, schedule, time, apps, script", table: "Automations", comment: "Settings search keywords, comma separated")]) { [context, controller, location] in
            AutomationsSettingsView(context: context, controller: controller, location: location)
        }]
    }

    var commands: [Command] {
        let controller = controller
        var commands = [
            Command(id: "automations.pause-all", title: LocalizedStringResource("Pause Automations", table: "Automations"),
                    symbol: "pause.circle", allowedFromURL: true, effect: .changesSettings,
                    isOn: { controller.isPaused }) { _ in
                controller.setPaused(true)
            },
            Command(id: "automations.resume-all", title: LocalizedStringResource("Resume Automations", table: "Automations"),
                    symbol: "play.circle", allowedFromURL: true,
                    effect: .destructive) { _ in
                controller.setPaused(false)
            },
            Self.toggleCommand(controller: controller, ids: []),
        ]
        #if DEBUG
        commands += AutomationsDebugCommands.commands(controller: controller, context: context, location: location,
                                                      placeTracker: placeTracker)
        #endif
        return commands
    }

    private func rulesChanged() {
        let ids = controller.rules.map(\.id)
        if ids != registeredRuleIDs {
            registeredRuleIDs = ids
            context.commands.register(Self.toggleCommand(controller: controller, ids: ids))
        }
        sources?.rulesChanged()
    }

    /// Re-registered whenever rules are added or removed so the allowed ids stay current.
    private static func toggleCommand(controller: AutomationsController, ids: [String]) -> Command {
        Command(id: "automations.toggle-rule", title: LocalizedStringResource("Turn Automation On or Off", table: "Automations"),
                symbol: "switch.2",
                arguments: [CommandArgument(name: "id", title: LocalizedStringResource("Automation", table: "Automations"),
                                            allowedValues: ids)],
                allowedFromURL: true,
                effect: .destructive) { invocation in
            try controller.toggle(id: try invocation.require("id"))
        }
    }
}

/// Feeds the controller's environment from the live system: power sources, Wi-Fi,
/// running and frontmost apps (the catalog's running apps include agent apps), displays,
/// wake and clock changes, and item-change reports.
final class AutomationLiveSources {
    private unowned let context: AppContext
    private let controller: AutomationsController
    private let location: any LocationProviding
    private let placeTracker: AutomationPlaceTracker
    private var powerSource: CFRunLoopSource?
    private var wifi: AutomationWiFiMonitor?
    private let events = AutomationSystemEvents()
    private var appsObserver: ChangeObserver?
    private var locationObserver: ChangeObserver?
    private var itemChangesObserver: ChangeObserver?
    private var networkNameTask: Task<Void, Never>?
    private let log = Log.logger("automations")

    init(context: AppContext, controller: AutomationsController, location: any LocationProviding,
         placeTracker: AutomationPlaceTracker) {
        self.context = context
        self.controller = controller
        self.location = location
        self.placeTracker = placeTracker
    }

    func start() {
        controller.updateEnvironment { environment in
            environment.power = AutomationPowerReader.read()
            environment.displays = AutomationDisplayReader.read()
            environment.apps = Self.apps(context.catalog.runningApps)
        }
        powerSource = AutomationPowerReader.observe { [weak self] in
            Task { @MainActor in self?.refreshPower() }
        }
        let wifi = AutomationWiFiMonitor { [weak self] connected in self?.wifiChanged(connected) }
        wifi.start()
        self.wifi = wifi
        events.start { [weak self] event in self?.handle(event) }
        appsObserver = ChangeObserver(track: { [weak self] in _ = self?.context.catalog.runningApps }) { [weak self] in
            self?.refreshApps()
        }
        itemChangesObserver = ChangeObserver(track: { [weak self] in
            _ = self?.context.services[.automationItemChanges].lastChanges
        }) { [weak self] in
            guard let self else { return }
            let changes = self.context.services[.automationItemChanges].lastChanges
            self.controller.updateEnvironment { $0.itemChanges = changes }
        }
        rulesChanged()
    }

    func stop() {
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
        powerSource = nil
        wifi?.stop()
        events.stop()
        appsObserver?.cancel()
        locationObserver?.cancel()
        itemChangesObserver?.cancel()
        networkNameTask?.cancel()
        placeTracker.stop()
    }

    /// Location is touched only once a rule needs network names or places; neither path
    /// asks for access (only a click in the editor or Settings › Permissions does).
    func rulesChanged() {
        placeTracker.reconcile(needed: controller.usesPlaces)
        guard controller.usesNetworkNames else {
            networkNameTask?.cancel()
            networkNameTask = nil
            return
        }
        // The editor may have activated Location already; the observer is ours either way.
        location.activate()
        if locationObserver == nil {
            locationObserver = ChangeObserver(track: { [weak self] in _ = self?.location.authorization }) { [weak self] in
                self?.refreshNetworkName()
            }
        }
        if networkNameTask == nil {
            // Network names change without a path change (roaming); re-read once a minute.
            networkNameTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.refreshNetworkName()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        }
    }

    private func handle(_ event: AutomationSystemEvents.Event) {
        switch event {
        case .wake:
            log.info("wake: re-evaluating")
            refreshPower()
            controller.updateEnvironment { $0.displays = AutomationDisplayReader.read() }
            refreshApps()
            refreshNetworkName()
            controller.evaluateNow()
        case .clockChanged:
            controller.evaluateNow()
        case .screensChanged:
            controller.updateEnvironment { $0.displays = AutomationDisplayReader.read() }
        case .frontmostChanged:
            refreshApps()
        }
    }

    private func refreshPower() {
        let power = AutomationPowerReader.read()
        controller.updateEnvironment { $0.power = power }
    }

    private func refreshApps() {
        let apps = Self.apps(context.catalog.runningApps)
        controller.updateEnvironment { $0.apps = apps }
    }

    private func wifiChanged(_ connected: Bool) {
        controller.updateEnvironment { $0.wifi.isConnected = connected }
        refreshNetworkName()
    }

    private func refreshNetworkName() {
        let authorized = location.isActive && location.isAuthorized
        guard controller.usesNetworkNames, authorized, controller.environment.wifi.isConnected else {
            controller.updateEnvironment { environment in
                environment.wifi.canReadNetworkName = authorized
                if !environment.wifi.isConnected || !authorized { environment.wifi.networkName = nil }
            }
            return
        }
        Task { [weak self] in
            let name = await AutomationWiFiMonitor.readNetworkName()
            self?.controller.updateEnvironment { environment in
                environment.wifi.canReadNetworkName = true
                environment.wifi.networkName = name
            }
        }
    }

    private static func apps(_ records: [RunningAppRecord]) -> AutomationAppsState {
        AutomationAppsState(running: Set(records.compactMap(\.bundleID)),
                            frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }
}
