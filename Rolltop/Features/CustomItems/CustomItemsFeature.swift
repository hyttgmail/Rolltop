import AppKit
import RolltopCore

/// Spacers, groups and widgets as Rolltop's own status items (milestone W2-C).
///
/// macOS hides menu bar items per app and never lets Rolltop hide its own, so these items are
/// visible whenever Rolltop runs; the user places them with ⌘-drag. Each has a fixed
/// `autosaveName` derived from its stable id, is created once and toggled with `isVisible`.
final class CustomItemsFeature: FeatureModule {
    static let id: FeatureID = "custom-items"
    static let paneID = "custom-items"

    private unowned let context: AppContext
    let store: CustomItemsStore
    let hub = CustomItemsSamplerHub()
    private var bar: CustomItemsBar?
    private let log = Log.logger("custom-items")

    init(context: AppContext) {
        self.context = context
        store = CustomItemsStore(settings: context.settings)
        context.services[.backupParticipants].register(CustomItemsBackupParticipant(settings: context.settings))
    }

    func start() {
        let bar = CustomItemsBar(context: context, store: store, hub: hub)
        self.bar = bar
        hub.onUpdate = { [weak bar] source, scriptID in bar?.refreshWidgets(source: source, scriptID: scriptID) }
        hub.ambientReader = { [unowned context] in CustomItemsAmbientReader.read(context.services) }
        store.onChange = { [weak bar] in bar?.reconcile() }
        hub.start()
        bar.reconcile()
        context.services[.paletteResultProviders].register(CustomItemsGroupPaletteProvider(store: store) { [weak bar] id in
            bar?.openGroup(id, gesture: .keyboard)
        })
        log.info("started: \(store.model.spacers.count) spacers, \(store.model.groups.count) groups, \(store.model.widgets.count) widgets")
    }

    func stop() {
        bar?.stop()
        hub.stop()
    }

    var settingsPanes: [SettingsPane] {
        [
            SettingsPane(id: Self.paneID, title: LocalizedStringResource("Custom Items", table: "CustomItems"),
                         symbol: "menubar.arrow.up.rectangle", sortOrder: 120,
                         keywords: [LocalizedStringResource("spacer, gap, group, widget, cpu, memory, network, battery, disk, clock, time zone, script, gpu, music, calendar, focus, weather",
                                                            table: "CustomItems", comment: "Settings search keywords, comma separated")]) { [unowned self] in
                CustomItemsSettingsView(context: context, store: store, hub: hub,
                                        openGroup: { [weak self] id in self?.bar?.openGroup(id) })
            },
        ]
    }

    var commands: [Command] {
        let idArgument = CommandArgument(name: "id", title: LocalizedStringResource("Item", table: "CustomItems"))
        var commands = [
            Command(id: "custom-items.toggle", title: LocalizedStringResource("Turn Custom Item On or Off", table: "CustomItems"),
                    symbol: "menubar.rectangle", arguments: [idArgument], allowedFromURL: true,
                    effect: .changesSettings) { [unowned self] invocation in
                let id = try invocation.require("id")
                guard store.model.isEnabled(id) != nil else { throw CommandError.invalidArgument("id", id) }
                let turningOn = !store.isActive(id)
                guard CustomItemsCommandPolicy.mayToggle(source: store.model.widget(id)?.source, turningOn: turningOn) else {
                    throw CommandError.failed(String(localized: "Script widgets can only be turned on in Settings › Custom Items.", table: "CustomItems"))
                }
                store.setEnabled(id, turningOn)
            },
            Command(id: "custom-items.open-group", title: LocalizedStringResource("Open Group", table: "CustomItems"),
                    symbol: "square.grid.2x2", arguments: [idArgument], allowedFromURL: true,
                    effect: .display) { [unowned self] invocation in
                let id = try invocation.require("id")
                guard store.model.group(id) != nil else { throw CommandError.invalidArgument("id", id) }
                guard store.isActive(id) else { throw CommandError.failed(String(localized: "The group is turned off.", table: "CustomItems")) }
                // A shortcut or the palette gives the panel the keyboard.
                bar?.openGroup(id, gesture: [.hotkey, .palette].contains(invocation.source) ? .keyboard : .click)
            },
            Command(id: "custom-items.refresh-widget", title: LocalizedStringResource("Refresh Widget", table: "CustomItems"),
                    symbol: "arrow.clockwise", arguments: [idArgument], allowedFromURL: true,
                    effect: .changesSettings) { [unowned self] invocation in
                let id = try invocation.require("id")
                guard let widget = store.model.widget(id) else { throw CommandError.invalidArgument("id", id) }
                guard store.isActive(id) else { throw CommandError.failed(String(localized: "The widget is turned off.", table: "CustomItems")) }
                hub.refresh(source: widget.source, scriptID: widget.id)
            },
        ]
        #if DEBUG
        commands += debugCommands
        #endif
        return commands
    }

    #if DEBUG
    /// Live-test helpers (Debug builds only).
    private var debugCommands: [Command] {
        [
            // Writes ~/Library/Application Support/Rolltop/debug/custom-items.json.
            Command(id: "custom-items.debug-dump", title: "Dump Custom Items", symbol: "ladybug", allowedFromURL: true) { [unowned self] _ in
                try DebugFiles.writeJSON(debugSnapshot(), name: "custom-items.json")
            },
            // Replaces the stored model with a JSON file, as an import would (script
            // approvals are revoked).
            Command(id: "custom-items.debug-load", title: "Load Custom Items", symbol: "tray.and.arrow.down",
                    arguments: [CommandArgument(name: "path", title: "Path")], allowedFromURL: true) { [unowned self] invocation in
                let url = try DebugFiles.inputURL(try invocation.require("path"))
                let model = try JSONDecoder().decode(CustomItemsModel.self, from: Data(contentsOf: url))
                context.settings[CustomItemsSettings.model] = model
            },
            Command(id: "custom-items.debug-clear", title: "Clear Custom Items", symbol: "trash", allowedFromURL: true) { [unowned self] _ in
                context.settings.reset(CustomItemsSettings.model)
                context.settings.reset(CustomItemsSettings.scriptApprovals)
            },
            // Stands in for the pane's confirmation when a script widget is switched on.
            Command(id: "custom-items.debug-approve-script", title: "Approve Script Widget", symbol: "checkmark.shield",
                    arguments: [CommandArgument(name: "id", title: "Item")], allowedFromURL: true) { [unowned self] invocation in
                store.debugApprove(try invocation.require("id"))
            },
            // A synthetic flag-less click on an item's centre (pointer restored). `tagged=false`
            // posts it without Rolltop's tag, so Rolltop's own monitors treat it like a user click.
            Command(id: "custom-items.debug-click", title: "Click Custom Item", symbol: "cursorarrow.click",
                    arguments: [CommandArgument(name: "id", title: "Item"),
                                CommandArgument(name: "button", title: "Button", isRequired: false, allowedValues: ["left", "right"]),
                                CommandArgument(name: "tagged", title: "Tagged", isRequired: false, allowedValues: ["true", "false"]),
                                CommandArgument(name: "close-menu-after", title: "Close menu after", isRequired: false),
                                CommandArgument(name: "restore", title: "Restore pointer", isRequired: false, allowedValues: ["true", "false"])],
                    allowedFromURL: true) { [unowned self] invocation in
                let id = try invocation.require("id")
                guard let frame = bar?.frame(of: id) else { throw CommandError.failed("item \(id) is not in the menu bar") }
                bar?.debugMenuTimeout = invocation.string("close-menu-after").flatMap(Double.init)
                let rect = ScreenGeometry.topLeftRect(fromAppKit: frame)
                let point = CGPoint(x: rect.midX, y: rect.midY)
                let button: EventSynthesizer.Button = invocation.string("button") == "right" ? .right : .left
                let tagged = invocation.string("tagged") != "false"
                // `restore=false` leaves the pointer on the item (a hover-style panel stays open)
                // until `custom-items.debug-restore-pointer`.
                let restore = invocation.string("restore") != "false"
                if !restore, debugSavedPointer == nil { debugSavedPointer = EventSynthesizer.pointerLocation }
                await Task.detached { CustomItemsDebugClick.click(at: point, button: button, tagged: tagged, restore: restore) }.value
            },
            Command(id: "custom-items.debug-restore-pointer", title: "Restore Pointer", symbol: "cursorarrow", allowedFromURL: true) { [unowned self] _ in
                guard let saved = debugSavedPointer else { return }
                debugSavedPointer = nil
                CGWarpMouseCursorPosition(saved)
            },
            // Registers sample providers for the service-fed widgets (`sample` = music,
            // paused, calendar, focus, weather, all) or puts the previous ones back (`reset`).
            Command(id: "custom-items.debug-inject", title: "Inject Widget Samples", symbol: "syringe",
                    arguments: [CommandArgument(name: "sample", title: "Sample",
                                                allowedValues: ["music", "paused", "calendar", "focus", "weather", "all", "reset"])],
                    allowedFromURL: true) { [unowned self] invocation in
                debugInject(try invocation.require("sample"))
            },
            Command(id: "custom-items.debug-edit", title: "Edit Custom Item", symbol: "pencil",
                    arguments: [CommandArgument(name: "id", title: "Item")], allowedFromURL: true) { [unowned self] invocation in
                bar?.edit(try invocation.require("id"))
            },
        ]
    }

    private var debugSavedPointer: CGPoint?
    private var debugSavedProviders: (any NowPlayingProviding, any UpNextProviding, any FocusStateProviding, any WeatherProviding)?

    private func debugInject(_ sample: String) {
        let services = context.services
        if debugSavedProviders == nil, sample != "reset" {
            debugSavedProviders = (services[.nowPlaying], services[.upNext], services[.focusState], services[.weather])
        }
        let all = sample == "all"
        if all || sample == "music" || sample == "paused" {
            let state = NowPlayingState(player: .music, title: "Clair de lune", artist: "Claude Debussy", isPlaying: sample != "paused")
            services.register(CustomItemsSampleNowPlaying(state: state) as any NowPlayingProviding, for: .nowPlaying)
        }
        if all || sample == "calendar" {
            let start = Date().addingTimeInterval(25 * 60)
            let event = UpNextEvent(id: "sample", title: "Standup", start: start, end: start.addingTimeInterval(1800), location: "Room 4")
            services.register(CustomItemsSampleUpNext(event: event) as any UpNextProviding, for: .upNext)
        }
        if all || sample == "focus" {
            services.register(CustomItemsSampleFocus(label: "Work") as any FocusStateProviding, for: .focusState)
        }
        if all || sample == "weather" {
            var report = WeatherReport.sample
            report.temperature = Measurement(value: 18, unit: .celsius)
            report.condition = .partlyCloudy
            report.fetchedAt = Date()
            services.register(CustomItemsSampleWeather(report: report) as any WeatherProviding, for: .weather)
        }
        if sample == "reset", let saved = debugSavedProviders {
            services.register(saved.0, for: .nowPlaying)
            services.register(saved.1, for: .upNext)
            services.register(saved.2, for: .focusState)
            services.register(saved.3, for: .weather)
            debugSavedProviders = nil
        }
        for source in [CustomItemWidgetSource.music, .calendar, .focus, .weather] { hub.refresh(source: source) }
    }

    struct DebugSnapshot: Encodable {
        var model: CustomItemsModel
        var approvedScripts: [String]
        var active: [String]
        var readOnly: Bool
        var bar: CustomItemsBar.Snapshot?
        var samplers: CustomItemsSamplerHub.Snapshot
        var readings: [String: String]
        var panelVisible: Bool
    }

    private func debugSnapshot() -> DebugSnapshot {
        let readings = hub.readings
        var values: [String: String] = [:]
        values["cpu"] = readings.cpu.map { CustomItemsFormat.percent($0.total) }
        values["memoryUsed"] = readings.memory.map { "\(CustomItemsFormat.memory($0.used)) (\($0.used) bytes)" }
        values["memoryPressure"] = readings.memory.map { "\($0.pressure.rawValue) \($0.pressurePercent.map { "\($0)" } ?? "-")" }
        values["network"] = readings.network.map { "down \(Int($0.down)) B/s up \(Int($0.up)) B/s" }
        values["battery"] = readings.battery.map { "\($0.percent)% charging \($0.isCharging) minutes \($0.minutesRemaining.map(String.init) ?? "-")" }
        values["diskAvailable"] = readings.disk.map { "\($0.available)" }
        values["now"] = readings.now.formatted(.iso8601)
        values["gpu"] = readings.gpu.map { "\($0 * 100)" }
        values["gpuReported"] = readings.gpuReported.map { "\($0)" }
        for widget in store.model.widgets where widget.source.isAmbient {
            values["ambient.\(widget.id)"] = CustomItemsWidgetText.value(for: widget, readings: readings) ?? "(empty)"
        }
        for (id, result) in readings.scripts { values["script.\(id)"] = "\(result.status.rawValue): \(result.line ?? "")" }
        return DebugSnapshot(model: store.model, approvedScripts: store.approvals.keys.sorted(),
                             active: store.model.allIDs.filter(store.isActive).sorted(), readOnly: store.isReadOnly,
                             bar: bar?.snapshot(), samplers: hub.snapshot(), readings: values,
                             panelVisible: context.services[.itemPanel].isPanelVisible)
    }
    #endif
}

/// What `custom-items.toggle` may do. Commands come from URLs, shortcuts and automations,
/// so they may switch a script widget off but never on: only the settings pane does that,
/// after asking.
nonisolated enum CustomItemsCommandPolicy {
    static func mayToggle(source: CustomItemWidgetSource?, turningOn: Bool) -> Bool {
        !(turningOn && source == .script)
    }
}

#if DEBUG
/// Debug-only synthetic clicks for live tests: flag-less, private-state source, pointer
/// restored (docs/PLATFORM.md §10). Tagged clicks go through `EventSynthesizer`.
nonisolated enum CustomItemsDebugClick {
    static func click(at point: CGPoint, button: EventSynthesizer.Button, tagged: Bool, restore: Bool) {
        if tagged, restore {
            EventSynthesizer.click(at: point, button: button)
            return
        }
        guard let events = EventSynthesizer.clickEvents(at: point, button: button) else { return }
        let saved = restore ? EventSynthesizer.pointerLocation : nil
        if !tagged { for event in events { event.setIntegerValueField(.eventSourceUserData, value: 0) } }
        events[0].post(tap: .cghidEventTap)
        usleep(30_000)
        events[1].post(tap: .cghidEventTap)
        if let saved, saved != point {
            usleep(30_000)
            CGWarpMouseCursorPosition(saved)
        }
    }
}
#endif
