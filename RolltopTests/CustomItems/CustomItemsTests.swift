import AppKit
import Foundation
import RolltopCore
import Testing
@testable import Rolltop

// Pure logic of custom items: models, sampling arithmetic, formatting, membership. Every
// settings test uses a throwaway defaults suite; nothing touches the real domain.

@Suite struct CustomItemsModelTests {
    private func decode(_ json: String) throws -> CustomItemsModel {
        try JSONDecoder().decode(CustomItemsModel.self, from: Data(json.utf8))
    }

    @Test func roundTrip() throws {
        var model = CustomItemsModel()
        model.spacers = [CustomItemSpacer(id: "spacer-1", width: 20, glyph: .symbol("star"))]
        model.groups = [CustomItemGroup(id: "group-1", name: "Hidden apps", members: ["com.foo", "system:wifi"], opensOnHover: true)]
        model.widgets = [CustomItemWidget(id: "widget-1", source: .clock, clockFormat: "HH:mm:ss", timeZone: "America/New_York", label: "NY"),
                         CustomItemWidget(id: "widget-2", source: .script, isEnabled: false, scriptCommand: "echo ok")]
        let data = try JSONEncoder().encode(model)
        #expect(try JSONDecoder().decode(CustomItemsModel.self, from: data) == model)
    }

    @Test func missingAndUnknownFieldsDecode() throws {
        let model = try decode("""
        {"spacers": [{"id": "spacer-1", "future": 3}],
         "groups": [{"id": "group-1", "members": ["com.foo"], "colour": "red"}],
         "widgets": [{"id": "widget-1", "source": "cpu", "sparkline3d": true}],
         "somethingNew": {"a": 1}}
        """)
        #expect(model.spacers == [CustomItemSpacer(id: "spacer-1")])
        #expect(model.groups.first?.icon == CustomItemGroup.defaultIcon)
        #expect(model.groups.first?.isEnabled == true)
        let widget = try #require(model.widgets.first)
        #expect(widget.style == .symbolAndText)
        #expect(widget.symbol == "cpu")
        #expect(widget.action == .menu)
        #expect(widget.effectiveInterval == 2)
    }

    @Test func unknownEnumValuesFallBack() throws {
        let model = try decode("""
        {"widgets": [{"id": "widget-1", "source": "network", "style": "hologram", "network": "sideways",
                      "action": {"kind": "teleport", "target": "x"}}],
         "spacers": [{"id": "spacer-1", "glyph": {"kind": "animation", "value": "x"}, "width": "wide"}]}
        """)
        let widget = try #require(model.widgets.first)
        #expect(widget.style == .symbolAndText)
        #expect(widget.networkDirection == .both)
        #expect(widget.action.kind == .menu)
        #expect(widget.action.target == "x")
        #expect(model.spacers.first?.glyph.kind == CustomItemGlyphKind.none)
        #expect(model.spacers.first?.width == CustomItemSpacer.defaultWidth)
    }

    @Test func unreadableElementsAreKeptAndWrittenBack() throws {
        let json = """
        {"widgets": [{"id": "widget-1", "source": "future-source", "enabled": true}, {"id": "widget-2", "source": "cpu"}, 7],
         "spacers": [{"width": 10}]}
        """
        let model = try decode(json)
        #expect(model.widgets.map(\.id) == ["widget-2"])
        #expect(model.unreadableCount == 3)
        let again = try JSONDecoder().decode(CustomItemsModel.self, from: JSONEncoder().encode(model))
        #expect(again == model)
        #expect(again.unreadable["widgets"]?.first?.id == "widget-1")
    }

    @Test func duplicateIDsKeepTheFirst() throws {
        let model = try decode("""
        {"spacers": [{"id": "a", "width": 10}, {"id": "a", "width": 20}], "widgets": [{"id": "a", "source": "cpu"}]}
        """)
        #expect(model.spacers.map(\.width) == [10])
        #expect(model.widgets.isEmpty)
    }

    @Test func clampsAndIntervals() {
        #expect(CustomItemSpacer(id: "s", width: 1).clampedWidth == 4)
        #expect(CustomItemSpacer(id: "s", width: 200).clampedWidth == 64)
        #expect(CustomItemWidget(id: "w", source: .script, interval: 1, scriptCommand: "x").effectiveInterval == 5)
        #expect(CustomItemWidget(id: "w", source: .script, interval: 6, scriptTimeout: 30).effectiveScriptTimeout == 5)
        #expect(CustomItemWidget(id: "w", source: .clock, clockFormat: "HH:mm").effectiveInterval == 60)
        #expect(CustomItemWidget(id: "w", source: .clock, clockFormat: "HH:mm:ss").effectiveInterval == 1)
        #expect(CustomItemWidget(id: "w", source: .memory).effectiveInterval == 5)
        #expect(CustomItemWidget(id: "w", source: .disk).effectiveInterval == 30)
        #expect(CustomItemWidget(id: "w", source: .label).effectiveInterval == 0)
    }

    @Test func ids() {
        #expect(CustomItemsIDs.next(for: .spacer, existing: []) == "spacer-1")
        #expect(CustomItemsIDs.next(for: .spacer, existing: ["spacer-1", "spacer-3"]) == "spacer-2")
        #expect(CustomItemsIDs.autosaveName(for: "test-1") == "rolltop.custom-items.test-1")
        #expect(CustomItemsIDs.isValid("widget-12"))
        #expect(!CustomItemsIDs.isValid("Widget 1"))
    }
}

@Suite struct CustomItemsMathTests {
    @Test func counterDeltas() {
        #expect(CustomItemsCounter.delta(from: 10, to: 25) == 15)
        // 32-bit wrap.
        #expect(CustomItemsCounter.delta(from: UInt64(UInt32.max) - 9, to: 5, bits: 32) == 15)
        // A small drop is a reset, not a wrap.
        #expect(CustomItemsCounter.delta(from: 1000, to: 900, bits: 32) == nil)
        // 64-bit counters never wrap in practice: a drop is a reset.
        #expect(CustomItemsCounter.delta(from: 1000, to: 10) == nil)
    }

    @Test func cpuUsage() throws {
        let a = CustomItemsCPUTicks(user: 100, system: 50, idle: 800, nice: 50)
        let b = CustomItemsCPUTicks(user: 160, system: 70, idle: 900, nice: 70)
        let usage = try #require(CustomItemsCPUMath.usage(from: a, to: b))
        #expect(abs(usage.total - 0.5) < 1e-9)
        #expect(abs(usage.user - 0.4) < 1e-9)
        #expect(abs(usage.system - 0.1) < 1e-9)
        #expect(CustomItemsCPUMath.usage(from: a, to: a) == nil)
        // Wrapped idle counter.
        let c = CustomItemsCPUTicks(user: 0, system: 0, idle: UInt64(UInt32.max) - 99, nice: 0)
        let d = CustomItemsCPUTicks(user: 100, system: 0, idle: 100, nice: 0)
        #expect(try #require(CustomItemsCPUMath.usage(from: c, to: d)).total == 100.0 / 300.0)
    }

    @Test func networkRates() throws {
        let before = [CustomItemsInterfaceCounters(name: "en0", received: 1_000, sent: 500),
                      CustomItemsInterfaceCounters(name: "en1", received: 10_000, sent: 0),
                      CustomItemsInterfaceCounters(name: "utun3", received: 0, sent: 0),
                      CustomItemsInterfaceCounters(name: "lo0", received: 0, sent: 0)]
        let after = [CustomItemsInterfaceCounters(name: "en0", received: 5_000, sent: 1_500),
                     CustomItemsInterfaceCounters(name: "en1", received: 2_000, sent: 0),   // reset
                     CustomItemsInterfaceCounters(name: "utun3", received: 9_999, sent: 9_999),
                     CustomItemsInterfaceCounters(name: "lo0", received: 9_999, sent: 9_999),
                     CustomItemsInterfaceCounters(name: "en5", received: 9_999, sent: 9_999)]  // new
        let rates = try #require(CustomItemsNetworkMath.rates(from: before, to: after, elapsed: 2))
        #expect(rates.down == 2_000)
        #expect(rates.up == 500)
        #expect(rates.interfaces.map(\.name) == ["en0", "en1"])
        #expect(CustomItemsNetworkMath.rates(from: before, to: after, elapsed: 0) == nil)
        // 32-bit counters wrap.
        let wrapped = CustomItemsNetworkMath.rates(from: [.init(name: "en0", received: UInt64(UInt32.max) - 999, sent: 0)],
                                                   to: [.init(name: "en0", received: 1_000, sent: 0)], elapsed: 1, counterBits: 32)
        #expect(wrapped?.down == 2_000)
    }

    @Test func memoryFigures() {
        let counts = CustomItemsVMCounts(pageSize: 16_384, physicalMemory: 32 * 1 << 30, free: 1000, active: 0, inactive: 0,
                                         speculative: 0, wired: 100_000, compressed: 50_000, purgeable: 10_000,
                                         external: 200_000, internal: 500_000)
        let figures = CustomItemsMemoryMath.figures(counts, pressureLevel: 2, freeLevelPercent: 60)
        #expect(figures.app == 490_000 * 16_384)
        #expect(figures.used == (490_000 + 100_000 + 50_000) * 16_384)
        #expect(figures.cached == 210_000 * 16_384)
        #expect(figures.pressure == .warning)
        #expect(figures.pressurePercent == 40)
        #expect(CustomItemsMemoryMath.figures(counts, pressureLevel: 4, freeLevelPercent: nil).pressure == .critical)
        #expect(CustomItemsMemoryMath.figures(counts, pressureLevel: nil, freeLevelPercent: nil).pressurePercent == nil)
    }

    @Test func battery() {
        let discharging = CustomItemsBatteryMath.state(current: 4_000, max: 5_000, isCharging: false, isOnAC: false, isCharged: false,
                                                       timeToEmpty: 187, timeToFull: -1)
        #expect(discharging.percent == 80)
        #expect(discharging.minutesRemaining == 187)
        #expect(CustomItemsBatteryMath.symbol(for: discharging) == "battery.75percent")
        let estimating = CustomItemsBatteryMath.state(current: 50, max: 100, isCharging: false, isOnAC: false, isCharged: false,
                                                      timeToEmpty: -1, timeToFull: nil)
        #expect(estimating.minutesRemaining == nil)
        let charging = CustomItemsBatteryMath.state(current: 99, max: 100, isCharging: true, isOnAC: true, isCharged: false,
                                                    timeToEmpty: 0, timeToFull: 12)
        #expect(charging.minutesRemaining == 12)
        #expect(CustomItemsBatteryMath.symbol(for: charging) == "battery.100percent.bolt")
    }

    @Test func formatting() {
        #expect(CustomItemsFormat.percent(0.071) == "7%")
        #expect(CustomItemsFormat.percent(1.5) == "100%")
        #expect(CustomItemsFormat.byteRate(0) == "0 KB/s")
        #expect(CustomItemsFormat.byteRate(420) == "0.4 KB/s")
        #expect(CustomItemsFormat.byteRate(4_200) == "4.2 KB/s")
        #expect(CustomItemsFormat.byteRate(42_000) == "42 KB/s")
        #expect(CustomItemsFormat.byteRate(999_600) == "1.0 MB/s")
        #expect(CustomItemsFormat.byteRate(12_345_678) == "12 MB/s")
        #expect(CustomItemsFormat.byteRate(.nan) == "0 KB/s")
        #expect(CustomItemsFormat.bytes(512_000_000) == "512 MB")
        #expect(CustomItemsFormat.bytes(12_400_000_000) == "12 GB")
        #expect(CustomItemsFormat.bytes(1_500_000_000_000) == "1.5 TB")
        #expect(CustomItemsFormat.duration(minutes: 187) == "3:07")
        // Memory in binary units, as Activity Monitor: 36 GiB reads "36 GB".
        #expect(CustomItemsFormat.memory(38_654_705_664) == "36 GB")
        #expect(CustomItemsFormat.memory(19_372_621_824) == "18 GB")
        #expect(CustomItemsFormat.memory(2_684_354_560) == "2.5 GB")
        #expect(CustomItemsFormat.memory(536_870_912) == "512 MB")
    }

    @Test func clock() throws {
        #expect(CustomItemsClock.showsSeconds(format: "HH:mm:ss"))
        #expect(!CustomItemsClock.showsSeconds(format: "HH:mm 'secs'"))
        let date = Date(timeIntervalSinceReferenceDate: 1_000_000_030.4)
        #expect(CustomItemsClock.nextTick(after: date, showsSeconds: true).timeIntervalSinceReferenceDate == 1_000_000_031)
        #expect(CustomItemsClock.nextTick(after: date, showsSeconds: false).timeIntervalSinceReferenceDate == 1_000_000_080)
        let utc = try #require(TimeZone(identifier: "UTC"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let posix = Locale(identifier: "en_US_POSIX")
        let noon = Date(timeIntervalSince1970: 12 * 3600)
        #expect(CustomItemsClock.text(for: noon, format: "HH:mm", timeZone: utc, locale: posix) == "12:00")
        #expect(CustomItemsClock.text(for: noon, format: "HH:mm", timeZone: tokyo, locale: posix) == "21:00")
        let samples = CustomItemsClock.widthSamples(format: "EEE MMM d", timeZone: utc, locale: posix)
        #expect(Set(samples.map { $0.prefix(3) }).count == 7)
    }

    @Test func history() {
        var history = CustomItemsHistory(capacity: 3)
        for value in [0.1, 0.2, 2, -1] { history.append(value) }
        #expect(history.values == [0.2, 1, 0])
        #expect(CustomItemsHistory.normalised([0, 100_000, 50_000]) == [0, 1, 0.5])
        #expect(CustomItemsHistory.normalised([100]) == [100.0 / 50_000])
    }
}

@Suite struct CustomItemsWidgetContentTests {
    @Test func cpuContent() {
        let widget = CustomItemWidget(id: "w", source: .cpu, showsHistory: true)
        var readings = CustomItemsReadings()
        var content = CustomItemsWidgetText.content(for: widget, readings: readings)
        #expect(content.text == CustomItemsWidgetContent.placeholder)
        #expect(content.symbol == "cpu")
        #expect(content.widthSamples.contains("100%"))
        readings.cpu = CustomItemsCPUUsage(total: 0.42, user: 0.3, system: 0.12)
        readings.cpuHistory = [0.1, 0.42]
        content = CustomItemsWidgetText.content(for: widget, readings: readings)
        #expect(content.text == "42%")
        #expect(content.history == [0.1, 0.42])
    }

    @Test func secondClockWithLabel() {
        var widget = CustomItemWidget(id: "w", source: .clock, clockFormat: "HH:mm", timeZone: "Asia/Tokyo", label: "TYO")
        var readings = CustomItemsReadings()
        readings.now = Date(timeIntervalSince1970: 12 * 3600)
        let content = CustomItemsWidgetText.content(for: widget, readings: readings)
        #expect(content.text == "TYO 21:00")
        #expect(content.symbol == nil)
        #expect(content.widthSamples.allSatisfy { $0.hasPrefix("TYO ") })
        widget.style = .symbolOnly
        #expect(CustomItemsWidgetText.content(for: widget, readings: readings).text == nil)
    }

    @Test func networkAndBattery() {
        var readings = CustomItemsReadings()
        readings.network = CustomItemsNetworkRates(down: 1_500_000, up: 2_000, interfaces: [])
        #expect(CustomItemsWidgetText.value(for: CustomItemWidget(id: "w", source: .network), readings: readings) == "↓1.5 MB/s ↑2.0 KB/s")
        #expect(CustomItemsWidgetText.value(for: CustomItemWidget(id: "w", source: .network, networkDirection: .up), readings: readings) == "↑2.0 KB/s")
        readings.battery = CustomItemsBatteryState(percent: 30, isCharging: false, isOnAC: false, isCharged: false, minutesRemaining: 75)
        let battery = CustomItemWidget(id: "w", source: .battery, batteryFigure: .timeRemaining)
        #expect(CustomItemsWidgetText.value(for: battery, readings: readings) == "1:15")
        #expect(CustomItemsWidgetText.content(for: battery, readings: readings).symbol == "battery.25percent")
        readings.battery?.minutesRemaining = nil
        #expect(CustomItemsWidgetText.value(for: battery, readings: readings) == "30%")
    }

    @Test func scriptAndLabel() {
        var readings = CustomItemsReadings()
        let script = CustomItemWidget(id: "s", source: .script, scriptCommand: "echo ok")
        #expect(CustomItemsWidgetText.value(for: script, readings: readings) == nil)
        readings.scripts["s"] = CustomItemsScriptResult(status: .ok, line: "ok", exitCode: 0, duration: 0.01)
        #expect(CustomItemsWidgetText.content(for: script, readings: readings).text == "ok")
        let label = CustomItemWidget(id: "l", source: .label, label: "Mail")
        #expect(CustomItemsWidgetText.content(for: label, readings: readings).text == "Mail")
    }

    @Test func demand() {
        let widgets = [CustomItemWidget(id: "a", source: .cpu), CustomItemWidget(id: "b", source: .cpu, interval: 1),
                       CustomItemWidget(id: "c", source: .network), CustomItemWidget(id: "d", source: .label),
                       CustomItemWidget(id: "e", source: .script, scriptCommand: "x"),
                       CustomItemWidget(id: "f", source: .clock, clockFormat: "HH:mm")]
        let demand = CustomItemsDemand.sources(for: widgets)
        #expect(demand == [.cpu: 1, .network: 2, .clock: 60])
        #expect(CustomItemsDemand.sources(for: []).isEmpty)
        #expect(CustomItemsDemand.merge([[.cpu: 2, .disk: 30], [.cpu: 5, .memory: 5]]) == [.cpu: 2, .disk: 30, .memory: 5])
    }
}

@Suite struct CustomItemsGroupTests {
    private func entry(_ owner: OwnerID?, own: Bool = false, section: Section? = .shown) -> CatalogEntry {
        CatalogEntry(id: owner?.stringValue ?? "pid:1", kind: owner == nil ? .unidentified : .app, owner: owner,
                     displayName: owner?.stringValue ?? "?", section: section, hasExplicitSection: false, itemCount: 1,
                     pids: [], axIdentifiers: [], slots: [], lastKnownFrames: [], runsOutsideApplications: false,
                     isUnreadable: false, isOwn: own, isCarriedOver: false)
    }

    @Test func presentableMembers() {
        let members = ["com.a", "com.b", "com.alphapengwang.rolltop", "system:wifi", "system:battery", "com.a", "bad id"]
        let result = CustomItemsGroupLogic.presentableMembers(members, runningBundleIDs: ["com.a", "com.alphapengwang.rolltop"],
                                                              presentOwners: [.system(.wifi)], ownBundleIDs: ["com.alphapengwang.rolltop"])
        #expect(result == [.app("com.a"), .system(.wifi)])
    }

    @Test func candidatesAndTemplate() {
        let entries = [entry(.app("com.a")), entry(.app("com.alphapengwang.rolltop"), own: true), entry(nil), entry(.app("com.b")),
                       entry(.system(.wifi))]
        #expect(CustomItemsGroupLogic.candidates(entries: entries, members: ["com.b"]) == [.app("com.a"), .system(.wifi)])
        let layout = Layout(sections: [.app("com.b"): .hidden, .app("com.z"): .hidden, .app("com.a"): .shown])
        #expect(CustomItemsGroupLogic.hiddenAppsMembers(layout: layout, entries: entries) == ["com.b", "com.z"])
        #expect(CustomItemsGroupLogic.suggestsHiding(section: .shown))
        #expect(!CustomItemsGroupLogic.suggestsHiding(section: .alwaysHidden))
    }

    @Test func sessionDecisions() {
        // Closed, nothing recent: open.
        #expect(CustomItemsGroupLogic.decideSessionBegin(group: "g", panelVisibleFor: nil, lastClosed: nil) == .present)
        // Still showing (the session began before the panel noticed the click): close.
        #expect(CustomItemsGroupLogic.decideSessionBegin(group: "g", panelVisibleFor: "g", lastClosed: nil) == .cancel)
        // The same click closed it a moment ago: stay closed.
        #expect(CustomItemsGroupLogic.decideSessionBegin(group: "g", panelVisibleFor: nil, lastClosed: ("g", 0.1)) == .cancel)
        #expect(CustomItemsGroupLogic.decideSessionBegin(group: "g", panelVisibleFor: nil, lastClosed: ("g", 2)) == .present)
        // Another group's panel: open this one.
        #expect(CustomItemsGroupLogic.decideSessionBegin(group: "g", panelVisibleFor: "h", lastClosed: ("h", 0.1)) == .present)
    }

    @Test func hoverTracker() {
        var tracker = CustomItemsHoverTracker()
        let r1 = tracker.pointerOver(group: nil, panelVisibleFor: nil)
        #expect(r1 == .nothing)
        let r2 = tracker.pointerOver(group: "g", panelVisibleFor: nil)
        #expect(r2 == .wait("g"))
        let r3 = tracker.pointerOver(group: "g", panelVisibleFor: nil)
        #expect(r3 == .nothing)
        let r4 = tracker.dwellElapsed(group: "g")
        #expect(r4)
        let r5 = tracker.dwellElapsed(group: "g")
        #expect(!r5)
        // Closed under the pointer: no reopening until the pointer leaves.
        tracker.panelClosed(group: "g")
        let r6 = tracker.pointerOver(group: "g", panelVisibleFor: nil)
        #expect(r6 == .nothing)
        let r7 = tracker.pointerOver(group: nil, panelVisibleFor: nil)
        #expect(r7 == .nothing)
        let r8 = tracker.pointerOver(group: "g", panelVisibleFor: nil)
        #expect(r8 == .wait("g"))
        let r9 = tracker.pointerOver(group: nil, panelVisibleFor: nil)
        #expect(r9 == .cancelWait)
        let r10 = tracker.dwellElapsed(group: "g")
        #expect(!r10)
    }

    @Test func commandsNeverTurnScriptsOn() {
        #expect(!CustomItemsCommandPolicy.mayToggle(source: .script, turningOn: true))
        #expect(CustomItemsCommandPolicy.mayToggle(source: .script, turningOn: false))
        #expect(CustomItemsCommandPolicy.mayToggle(source: .cpu, turningOn: true))
        #expect(CustomItemsCommandPolicy.mayToggle(source: nil, turningOn: true))
    }

    @Test func clickArguments() {
        let declared: [(name: String, allowedValues: [String]?)] = [("anchor", ["pointer", "status-item"]), ("gesture", ["click", "hover", "scroll"])]
        #expect(CustomItemsCommandArguments.forClick([:], declared: declared) == ["gesture": "click"])
        #expect(CustomItemsCommandArguments.forClick(["gesture": "hover"], declared: declared) == ["gesture": "hover"])
        #expect(CustomItemsCommandArguments.forClick(["id": "x"], declared: [("id", nil)]) == ["id": "x"])
    }

    @Test func actionTargets() {
        #expect(CustomItemsActionTarget.url(for: "https://example.com")?.absoluteString == "https://example.com")
        #expect(CustomItemsActionTarget.url(for: "/Applications/Safari.app")?.path == "/Applications/Safari.app")
        #expect(CustomItemsActionTarget.url(for: "~/x.txt")?.path == NSHomeDirectory() + "/x.txt")
        #expect(CustomItemsActionTarget.url(for: "not a url") == nil)
        #expect(CustomItemsActionTarget.url(for: "  ") == nil)
    }
}

@Suite struct CustomItemsStoreTests {
    private func makeStore() throws -> (CustomItemsStore, SettingsStore, UserDefaults, String) {
        let suite = "com.alphapengwang.rolltop.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = SettingsStore(defaults: defaults)
        return (CustomItemsStore(settings: settings), settings, defaults, suite)
    }

    @Test func writesAndApprovals() throws {
        let (store, settings, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = store.newID(.widget)
        store.upsert(widget: CustomItemWidget(id: id, source: .script, scriptCommand: "echo ok"))
        #expect(settings[CustomItemsSettings.model].widgets.count == 1)
        // Enabled in the model but never approved here: not active.
        #expect(!store.isActive(id))
        store.approveAndEnable(id)
        #expect(store.isActive(id))
        // The approval is runtime state: never exported.
        #expect(settings.exportAll()[CustomItemsSettings.scriptApprovals.name] == nil)
        // Changing the command needs approval again.
        var widget = try #require(store.model.widget(id))
        widget.scriptCommand = "echo other"
        store.upsert(widget: widget)
        #expect(!store.isActive(id))
        #expect(store.approvals.isEmpty)
    }

    @Test func importsRevokeApprovals() throws {
        let (store, settings, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.upsert(widget: CustomItemWidget(id: "widget-1", source: .script, scriptCommand: "echo ok"))
        store.approveAndEnable("widget-1")
        #expect(store.isActive("widget-1"))
        // An import writes the same widget plus another one.
        var imported = store.model
        imported.spacers = [CustomItemSpacer(id: "spacer-1")]
        let exported = settings.exportAll()
        settings.replaceAll(with: exported)
        settings[CustomItemsSettings.model] = imported
        store.reloadFromSettings()
        #expect(store.model == imported)
        #expect(!store.isActive("widget-1"))
        #expect(store.isActive("spacer-1"))
    }

    @Test func unreadableDataIsNotOverwritten() throws {
        let suite = "com.alphapengwang.rolltop.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: CustomItemsSettings.model.name)
        let store = CustomItemsStore(settings: SettingsStore(defaults: defaults))
        #expect(store.isReadOnly)
        store.upsert(spacer: CustomItemSpacer(id: "spacer-1"))
        #expect(defaults.data(forKey: CustomItemsSettings.model.name) == Data("not json".utf8))
    }

    @Test func toggleMoveRemove() throws {
        let (store, _, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.upsert(spacer: CustomItemSpacer(id: "spacer-1"))
        store.upsert(spacer: CustomItemSpacer(id: store.newID(.spacer)))
        #expect(store.model.spacers.map(\.id) == ["spacer-1", "spacer-2"])
        store.move(.spacer, fromOffsets: [1], toOffset: 0)
        #expect(store.model.spacers.map(\.id) == ["spacer-2", "spacer-1"])
        store.setEnabled("spacer-1", false)
        #expect(!store.isActive("spacer-1"))
        store.remove("spacer-2")
        #expect(store.model.spacers.map(\.id) == ["spacer-1"])
        #expect(store.newID(.spacer) == "spacer-2")
    }
}

@Suite struct CustomItemsScriptTests {
    @Test func firstLineAndEnvironment() {
        #expect(CustomItemsScriptRunner.firstLine(of: "\n  \n  hello world  \nsecond") == "hello world")
        #expect(CustomItemsScriptRunner.firstLine(of: "") == nil)
        #expect(CustomItemsScriptRunner.firstLine(of: String(repeating: "x", count: 100))?.count == CustomItemsScriptRunner.maximumLineLength)
        let environment = CustomItemsScriptRunner.environment(home: "/Users/x")
        #expect(Set(environment.keys) == ["PATH", "HOME", "LANG", "LC_ALL", "TMPDIR"])
    }

    @Test func runsAndTimesOut() async {
        let ok = await CustomItemsScriptRunner.run("echo ok; echo more", timeout: 3)
        #expect(ok.status == .ok)
        #expect(ok.line == "ok")
        let failed = await CustomItemsScriptRunner.run("echo partial; exit 3", timeout: 3)
        #expect(failed.status == .failed)
        #expect(failed.exitCode == 3)
        let slow = await CustomItemsScriptRunner.run("sleep 5", timeout: 0.3)
        #expect(slow.status == .timedOut)
        #expect(slow.duration < 2)
        // The environment is not inherited.
        let env = await CustomItemsScriptRunner.run("echo ${TYPESAFE_API_KEY:-unset}", timeout: 3)
        #expect(env.line == "unset")
    }
}

@Suite struct CustomItemsSamplerHubTests {
    @Test func samplersFollowDemandAndSleep() {
        let hub = CustomItemsSamplerHub()
        #expect(hub.runningTimerCount == 0)
        hub.setDemand([.cpu: 2, .clock: 60], client: "bar")
        hub.setDemand([.cpu: 1], client: "settings")
        #expect(hub.runningTimerCount == 2)
        // One shared sampler per source, at the shortest interval asked for.
        #expect(hub.activeIntervals == [.cpu: 1, .clock: 60])
        hub.setAsleep(true)
        #expect(hub.runningTimerCount == 0)
        hub.setDemand([.cpu: 2, .network: 2], client: "bar")
        #expect(hub.runningTimerCount == 0)
        hub.setAsleep(false)
        #expect(hub.activeIntervals == [.cpu: 1, .network: 2])
        hub.setDemand([:], client: "settings")
        #expect(hub.activeIntervals == [.cpu: 2, .network: 2])
        hub.setDemand([:], client: "bar")
        #expect(hub.runningTimerCount == 0)
        #expect(hub.effectiveDemand.isEmpty)
    }

    @Test func scriptsStopWhileAsleep() {
        let hub = CustomItemsSamplerHub()
        hub.setScripts(["w": .init(command: "true", interval: 30, timeout: 3)])
        #expect(hub.activeScriptIDs == ["w"])
        hub.setAsleep(true)
        #expect(hub.runningTimerCount == 0)
        hub.setAsleep(false)
        #expect(hub.activeScriptIDs == ["w"])
        hub.setScripts([:])
        #expect(hub.runningTimerCount == 0)
    }
}

@Suite struct CustomItemsAmbientTests {
    @Test func gpuTakesTheBusiestAccelerator() {
        #expect(CustomItemsGPUMath.utilization(from: [["Device Utilization %": 23], ["Device Utilization %": NSNumber(value: 41)]]) == 0.41)
        #expect(CustomItemsGPUMath.utilization(from: [["Renderer Utilization %": 5], [:]]) == nil)
        #expect(CustomItemsGPUMath.utilization(from: [["Device Utilization %": 140]]) == 1)
        var readings = CustomItemsReadings()
        readings.gpuReported = false
        let widget = CustomItemWidget(id: "widget-1", source: .gpu)
        #expect(CustomItemsWidgetText.content(for: widget, readings: readings).text == CustomItemsWidgetContent.placeholder)
    }

    @Test func musicTextAndTruncation() {
        let state = NowPlayingState(player: .music, title: "Clair de lune", artist: "Claude Debussy", isPlaying: true)
        #expect(CustomItemsAmbientText.music(state) == "Clair de lune – Claude Debussy")
        #expect(CustomItemsAmbientText.music(NowPlayingState(player: .spotify, title: "Song", isPlaying: false)) == "Song")
        let short = CustomItemsAmbientText.music(state, limit: 10)
        #expect(short == "Clair de…")
        var readings = CustomItemsReadings()
        let widget = CustomItemWidget(id: "widget-1", source: .music)
        #expect(CustomItemsWidgetText.isEmpty(widget, readings: readings))
        readings.ambient.nowPlaying = NowPlayingState(player: .music, title: "Song", isPlaying: false)
        #expect(!CustomItemsWidgetText.isEmpty(widget, readings: readings))
        #expect(CustomItemsWidgetText.content(for: widget, readings: readings).symbol == "pause.fill")
    }

    @Test func calendarLookahead() throws {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        func event(in minutes: Double, allDay: Bool = false) -> UpNextEvent {
            UpNextEvent(id: "e", title: "Standup", start: now.addingTimeInterval(minutes * 60),
                        end: now.addingTimeInterval(minutes * 60 + 1800), isAllDay: allDay)
        }
        #expect(CustomItemsAmbientText.event(event(in: 25), authorized: true, now: now) != nil)
        #expect(CustomItemsAmbientText.event(event(in: -10), authorized: true, now: now) != nil)   // in progress
        #expect(CustomItemsAmbientText.event(event(in: -40), authorized: true, now: now) == nil)   // ended
        #expect(CustomItemsAmbientText.event(event(in: 25 * 60), authorized: true, now: now) == nil)
        #expect(CustomItemsAmbientText.event(event(in: 25, allDay: true), authorized: true, now: now) == nil)
        #expect(CustomItemsAmbientText.event(event(in: 25), authorized: false, now: now) == nil)
        let utc = try #require(TimeZone(identifier: "UTC"))
        let text = CustomItemsAmbientText.calendar(event(in: 0), timeFormat: "HH:mm", timeZone: utc)
        #expect(text == "\(CustomItemsClock.text(for: now, format: "HH:mm", timeZone: utc)) Standup")
    }

    @Test func focusNeverSaysOff() {
        #expect(CustomItemsAmbientText.focus(isFocused: nil, label: "Work") == nil)
        #expect(CustomItemsAmbientText.focus(isFocused: false, label: nil) == nil)
        #expect(CustomItemsAmbientText.focus(isFocused: true, label: "Work") == "Work")
        #expect(CustomItemsAmbientText.focus(isFocused: true, label: nil) == String(localized: "Focus", table: "CustomItems"))
        let widget = CustomItemWidget(id: "widget-1", source: .focus)
        let quiet = CustomItemsWidgetText.content(for: widget, readings: CustomItemsReadings())
        #expect(quiet.text == nil && quiet.symbol == "moon")
    }

    @Test func weatherAndClicks() {
        let widget = CustomItemWidget(id: "widget-1", source: .weather)
        var readings = CustomItemsReadings()
        readings.ambient.weather = WeatherReport.sample
        #expect(CustomItemsWidgetText.isEmpty(widget, readings: readings))   // disabled
        readings.ambient.weatherEnabled = true
        let content = CustomItemsWidgetText.content(for: widget, readings: readings)
        #expect(content.symbol == WeatherReport.sample.symbolName)
        #expect(content.text?.contains("°") == true)
        #expect(CustomItemsAmbientClick.action(for: .music, canControl: true) == .playPause)
        #expect(CustomItemsAmbientClick.action(for: .music, canControl: false) == .openPane("permissions"))
        #expect(CustomItemsAmbientClick.action(for: .weather, canControl: false) == .openPane("weather"))
        #expect(CustomItemsAmbientClick.action(for: .gpu, canControl: false) == .details)
    }

    @Test func newSourcesRoundTripAndHaveSymbols() throws {
        var model = CustomItemsModel()
        model.widgets = [CustomItemWidgetSource.gpu, .music, .calendar, .focus, .weather].enumerated().map {
            CustomItemWidget(id: "widget-\($0.offset + 1)", source: $0.element)
        }
        let data = try JSONEncoder().encode(model)
        #expect(try JSONDecoder().decode(CustomItemsModel.self, from: data) == model)
        for name in model.widgets.map(\.symbol) + ["play.fill", "pause.fill", "moon.fill"] {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
    }
}
