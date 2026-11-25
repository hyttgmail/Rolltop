import AppKit
import RolltopCore

/// Rolltop's own status items for spacers, groups and widgets. An item is created the first
/// time it is enabled, with its fixed `autosaveName`, and afterwards only shown and hidden
/// through `isVisible` (docs/PLATFORM.md §7); it is removed only when deleted. macOS keeps
/// every Rolltop item visible whenever Rolltop runs: they can never be hidden by Rolltop.
final class CustomItemsBar: NSObject, NSStatusItemExpandedInterfaceDelegate {
    final class Slot {
        let id: String
        let kind: CustomItemKind
        let item: NSStatusItem
        /// The model value last drawn: a change resets the automatic width.
        var drawnConfig: AnyHashable?
        var drawnContent: CustomItemsWidgetContent?
        var textRatchet: CGFloat = 0

        init(id: String, kind: CustomItemKind, item: NSStatusItem) {
            self.id = id
            self.kind = kind
            self.item = item
        }
    }

    private unowned let context: AppContext
    private let store: CustomItemsStore
    private let hub: CustomItemsSamplerHub
    let panels: CustomItemsPanelAdapter
    private(set) var slots: [String: Slot] = [:]
    private var sessions: [String: NSStatusItemExpandedInterfaceSession] = [:]
    private var hover = CustomItemsHoverTracker()
    private var hoverMonitors: [Any] = []
    private var hoverTimer: Timer?
    private var watchMonitors: [Any] = []
    private var watchTimer: Timer?
    private var watchButtonDown = false
    private var lastBatteryPresence: Bool?
    private(set) var events: [String] = []
    private let log = Log.logger("custom-items")

    init(context: AppContext, store: CustomItemsStore, hub: CustomItemsSamplerHub) {
        self.context = context
        self.store = store
        self.hub = hub
        panels = CustomItemsPanelAdapter(context: context)
        super.init()
        panels.onClosed = { [weak self] group in self?.groupPanelClosed(group) }
        panels.onEdit = { [weak self] id in self?.edit(id) }
    }

    func stop() {
        for id in Array(sessions.keys) { endGroup(id) }
        panels.dismiss()
        setHoverMonitoring(false)
        hub.setDemand([:], client: "bar")
        hub.setScripts([:])
    }

    /// Drawn in the bar now (enabled, approved, and for batteries: the Mac has one).
    func isShown(_ id: String) -> Bool { slots[id]?.item.isVisible == true }

    // MARK: Reconcile

    /// Brings the status items in line with the model: create, show, hide, remove, redraw.
    func reconcile() {
        let model = store.model
        let shownBefore = Set(slots.filter { $0.value.item.isVisible }.keys)
        defer {
            // Rolltop's own items are part of the catalog (the layout editor draws one image per
            // slot): refresh it once MenuBarAgent has laid out the change.
            if Set(slots.filter { $0.value.item.isVisible }.keys) != shownBefore {
                context.catalog.setNeedsRefresh(after: .milliseconds(600))
            }
        }
        var wanted: [(id: String, kind: CustomItemKind)] = []
        for spacer in model.spacers where store.isActive(spacer.id) { wanted.append((spacer.id, .spacer)) }
        for group in model.groups where store.isActive(group.id) { wanted.append((group.id, .group)) }
        let activeWidgets = model.widgets.filter { store.isActive($0.id) }
        for widget in activeWidgets where !(widget.source == .battery && hub.readings.batteryPresent == false)
            && !CustomItemsWidgetText.isEmpty(widget, readings: hub.readings) {
            wanted.append((widget.id, .widget))
        }
        let wantedIDs = Set(wanted.map(\.id))

        for (id, slot) in slots where !wantedIDs.contains(id) {
            if model.kind(of: id) == nil || model.kind(of: id) != slot.kind {
                if slot.kind == .group { endGroup(id) }
                NSStatusBar.system.removeStatusItem(slot.item)
                slots.removeValue(forKey: id)
                context.services[.ownStatusItems].unregister(id: CustomItemsIDs.autosaveName(for: id))
                log.info("removed item \(id)")
            } else if slot.item.isVisible {
                if slot.kind == .group { endGroup(id) }
                slot.item.isVisible = false
                log.info("hid item \(id)")
            }
        }
        for (id, kind) in wanted {
            let slot = slots[id].flatMap { $0.kind == kind ? $0 : nil } ?? makeSlot(id: id, kind: kind)
            if !slot.item.isVisible {
                slot.item.isVisible = true
                log.info("showed item \(id)")
            }
            draw(slot)
        }

        // Batteries are sampled once to learn whether the Mac has one.
        var demand = CustomItemsDemand.sources(for: activeWidgets)
        if hub.readings.batteryPresent == false { demand.removeValue(forKey: .battery) }
        hub.setDemand(demand, client: "bar")
        var jobs: [String: CustomItemsSamplerHub.ScriptJob] = [:]
        for widget in activeWidgets where widget.source == .script {
            jobs[widget.id] = .init(command: widget.scriptCommand, interval: widget.effectiveInterval, timeout: widget.effectiveScriptTimeout)
        }
        hub.setScripts(jobs)
        setHoverMonitoring(model.groups.contains { $0.opensOnHover && wantedIDs.contains($0.id) })
    }

    private func makeSlot(id: String, kind: CustomItemKind) -> Slot {
        if let stale = slots[id] { NSStatusBar.system.removeStatusItem(stale.item) }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Before the first draw, so macOS files the item under its own stable name.
        item.autosaveName = CustomItemsIDs.autosaveName(for: id)
        // AppKit restores a previous `isVisible = false` stored under that name.
        item.isVisible = true
        if let button = item.button {
            button.identifier = NSUserInterfaceItemIdentifier(id)
            button.target = self
            button.action = #selector(buttonClicked(_:))
            // Groups open through the expanded-interface session on a left click; the
            // button only takes right clicks.
            button.sendAction(on: kind == .group ? [.rightMouseUp] : [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.title = ""
        }
        if kind == .group { item.expandedInterfaceDelegate = self }
        // The core tells Rolltop's main icon from these and draws them from their own images.
        context.services[.ownStatusItems].register(item, id: CustomItemsIDs.autosaveName(for: id))
        let slot = Slot(id: id, kind: kind, item: item)
        slots[id] = slot
        log.info("created item \(id) (\(kind.rawValue)), autosave \(item.autosaveName ?? "")")
        return slot
    }

    private func draw(_ slot: Slot) {
        let model = store.model
        let rendering: CustomItemsRenderer.Rendering
        let label: String
        switch slot.kind {
        case .spacer:
            guard let spacer = model.spacer(slot.id) else { return }
            if slot.drawnConfig == AnyHashable(spacer) { return }
            slot.drawnConfig = spacer
            rendering = CustomItemsRenderer.spacer(spacer)
            label = String(localized: "Spacer", table: "CustomItems")
        case .group:
            guard let group = model.group(slot.id) else { return }
            if slot.drawnConfig == AnyHashable(group) { return }
            slot.drawnConfig = group
            rendering = CustomItemsRenderer.group(group)
            label = group.name.isEmpty ? String(localized: "Group", table: "CustomItems") : group.name
            slot.item.button?.toolTip = label
        case .widget:
            guard let widget = model.widget(slot.id) else { return }
            if slot.drawnConfig != AnyHashable(widget) {
                slot.drawnConfig = widget
                slot.textRatchet = 0
                slot.drawnContent = nil
            }
            let content = CustomItemsWidgetText.content(for: widget, readings: hub.readings)
            if content == slot.drawnContent { return }
            slot.drawnContent = content
            // The weather licence wants the attribution next to the data.
            let tip = widget.source == .weather ? WeatherAttribution.openMeteo.text : nil
            if slot.item.button?.toolTip != tip { slot.item.button?.toolTip = tip }
            rendering = CustomItemsRenderer.widget(content, fixedWidth: widget.clampedFixedWidth, minimumTextWidth: slot.textRatchet)
            slot.textRatchet = max(slot.textRatchet, rendering.textWidth)
            label = content.accessibilityText.isEmpty ? CustomItemsText.title(of: widget.source) : content.accessibilityText
        }
        slot.item.button?.image = rendering.image
        if slot.item.length != rendering.length { slot.item.length = rendering.length }
        slot.item.button?.setAccessibilityLabel(label)
    }

    /// Redraws the widgets fed by `source` (or one script widget).
    func refreshWidgets(source: CustomItemWidgetSource, scriptID: String?) {
        if source == .battery, hub.readings.batteryPresent != lastBatteryPresence {
            // Presence decides whether battery widgets show at all.
            lastBatteryPresence = hub.readings.batteryPresent
            reconcile()
            return
        }
        if source.hidesWhenEmpty, store.model.widgets.contains(where: {
            $0.source == source && store.isActive($0.id) && isShown($0.id) == CustomItemsWidgetText.isEmpty($0, readings: hub.readings)
        }) {
            // Something appears or leaves: reconcile on the next turn (this may run inside
            // a reconcile that is starting samplers).
            scheduleReconcile()
            return
        }
        for widget in store.model.widgets where widget.source == source && (scriptID == nil || widget.id == scriptID) {
            if let slot = slots[widget.id], slot.item.isVisible { draw(slot) }
        }
    }

    private var reconcilePending = false

    private func scheduleReconcile() {
        guard !reconcilePending else { return }
        reconcilePending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.reconcilePending = false
            self.reconcile()
        }
    }

    // MARK: Geometry

    /// The item's frame in global AppKit coordinates, nil when it is not in a menu bar.
    func frame(of id: String) -> CGRect? {
        slots[id].flatMap { OwnStatusItemRegistry.frame(of: $0.item) }
    }

    private func id(of item: NSStatusItem) -> String? {
        slots.values.first { $0.item === item }?.id
    }

    // MARK: Clicks

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        guard let id = sender.identifier?.rawValue, let slot = slots[id] else { return }
        let event = NSApp.currentEvent
        // MenuBarAgent forwards clicks without modifier flags: read the live state too.
        let modifiers = (event?.modifierFlags ?? []).union(NSEvent.modifierFlags)
        let secondary = event?.type == .rightMouseUp || event?.type == .rightMouseDown || modifiers.contains(.control)
        note("click \(id) type \(event?.type.rawValue ?? 0) secondary \(secondary)")
        switch slot.kind {
        case .spacer:
            if secondary { showMenu(spacerMenu(id), on: slot) }
        case .group:
            if secondary { showMenu(groupMenu(id), on: slot) } else { toggleGroup(id) }
        case .widget:
            guard let widget = store.model.widget(id) else { return }
            if secondary { showMenu(detailsMenu(widget), on: slot) } else { perform(widget, slot: slot) }
        }
    }

    private func showMenu(_ menu: NSMenu, on slot: Slot) {
        note("menu \(slot.id): \(menu.numberOfItems) items")
        #if DEBUG
        if let timeout = debugMenuTimeout {
            debugMenuTimeout = nil
            debugOpenMenu = menu
            let timer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.debugOpenMenu?.cancelTracking() }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        #endif
        let delegate = slot.item.expandedInterfaceDelegate
        slot.item.expandedInterfaceDelegate = nil
        slot.item.menu = menu
        slot.item.button?.performClick(nil)
        slot.item.menu = nil
        slot.item.expandedInterfaceDelegate = delegate
        note("menu \(slot.id) closed")
    }

    #if DEBUG
    /// Live tests: the next menu closes itself after this many seconds (no Escape key).
    var debugMenuTimeout: TimeInterval?
    private weak var debugOpenMenu: NSMenu?
    #endif

    private func perform(_ widget: CustomItemWidget, slot: Slot) {
        let action = widget.action
        switch action.kind {
        case .none:
            break
        case .menu:
            let services = context.services
            switch CustomItemsAmbientClick.action(for: widget.source, canControl: services[.nowPlaying].canControl) {
            case .details:
                showMenu(detailsMenu(widget), on: slot)
            case .playPause:
                Task { [weak self] in
                    let done = await services[.nowPlaying].perform(.playPause)
                    if !done { self?.log.notice("widget \(widget.id): play/pause not done") }
                    self?.hub.refresh(source: .music)
                }
            case .openPane(let pane):
                services[.settingsWindow].showSettings(paneID: pane)
            }
        case .open:
            guard let url = CustomItemsActionTarget.url(for: action.target) else {
                log.error("widget \(widget.id): nothing to open")
                return
            }
            if url.pathExtension == "app" {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error { Log.logger("custom-items").error("open app failed: \(error.localizedDescription)") }
                }
            } else {
                NSWorkspace.shared.open(url)
            }
        case .command:
            guard !action.command.isEmpty else { return }
            let id = CommandID(action.command)
            let declared = context.commands.command(id)?.arguments ?? []
            context.commands.runDetached(id, arguments: CustomItemsCommandArguments.forClick(action.arguments, declared: declared.map {
                (name: $0.name, allowedValues: $0.allowedValues)
            }), source: .customItem)
        }
    }

    // MARK: Menus

    private func menuItem(_ title: String, action: Selector?, id: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = id
        item.isEnabled = action != nil
        // macOS 27 adds its own symbols to standard items; these identify nothing.
        item.preferredImageVisibility = .hidden
        return item
    }

    private func spacerMenu(_ id: String) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(menuItem(String(localized: "Edit Spacer…", table: "CustomItems"), action: #selector(editItem(_:)), id: id))
        menu.addItem(menuItem(String(localized: "Remove Spacer", table: "CustomItems"), action: #selector(removeItem(_:)), id: id))
        return menu
    }

    private func groupMenu(_ id: String) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let group = store.model.group(id) {
            let title = menuItem(group.name.isEmpty ? String(localized: "Group", table: "CustomItems") : group.name, action: nil)
            menu.addItem(title)
            menu.addItem(.separator())
        }
        menu.addItem(menuItem(String(localized: "Edit Group…", table: "CustomItems"), action: #selector(editItem(_:)), id: id))
        menu.addItem(menuItem(String(localized: "Remove Group", table: "CustomItems"), action: #selector(removeItem(_:)), id: id))
        return menu
    }

    private func detailsMenu(_ widget: CustomItemWidget) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for line in CustomItemsText.details(for: widget, readings: hub.readings) {
            menu.addItem(menuItem(line, action: nil))
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        if widget.source != .label, widget.source != .clock {
            menu.addItem(menuItem(String(localized: "Refresh Now", table: "CustomItems"), action: #selector(refreshItem(_:)), id: widget.id))
        }
        menu.addItem(menuItem(String(localized: "Edit Widget…", table: "CustomItems"), action: #selector(editItem(_:)), id: widget.id))
        return menu
    }

    @objc private func editItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        edit(id)
    }

    @objc private func removeItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        store.remove(id)
    }

    @objc private func refreshItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let widget = store.model.widget(id) else { return }
        hub.refresh(source: widget.source, scriptID: widget.id)
    }

    func edit(_ id: String) {
        store.pendingEditID = id
        context.services[.settingsWindow].showSettings(paneID: CustomItemsFeature.paneID)
    }

    // MARK: Groups

    /// Shows a group's members under its item (or its empty state), or closes them when
    /// they are showing.
    func toggleGroup(_ id: String) {
        if panels.visibleGroup == id { panels.dismiss() } else { openGroup(id) }
    }

    /// Presents the group under its item; under Rolltop's item when the group's is not drawn.
    /// `gesture`: how it was opened (decides how the panel closes); hover never shows the
    /// empty state.
    func openGroup(_ id: String, gesture: ItemPanelGesture = .click) {
        let viaHover = gesture == .hover
        guard let group = store.model.group(id) else { return }
        let running = Set(context.catalog.runningApps.compactMap(\.bundleID))
        let members = CustomItemsGroupLogic.presentableMembers(group.members, runningBundleIDs: running,
                                                                presentOwners: context.catalog.presentOwners,
                                                                ownBundleIDs: context.ownBundleIDs)
        let frame = frame(of: id)
        if members.isEmpty {
            guard !viaHover else { return }
            let message = group.members.isEmpty
                ? String(localized: "This group has no items yet. Add menu bar items to it in Settings.", table: "CustomItems")
                : String(localized: "None of this group’s items are running right now.", table: "CustomItems")
            panels.presentEmptyState(group: id, message: message, below: frame)
        } else {
            panels.present(group: id, owners: members, anchor: frame.map { .rect($0) } ?? .statusItem, gesture: gesture)
        }
        note("open group \(id): \(members.count) members, \(gesture.rawValue)")
    }

    private func endGroup(_ id: String) {
        if panels.visibleGroup == id { panels.dismiss() }
        sessions.removeValue(forKey: id)?.cancel()
        updateSessionWatch()
    }

    private func groupPanelClosed(_ id: String) {
        hover.panelClosed(group: id)
        if let session = sessions.removeValue(forKey: id) {
            note("cancel session \(id) (panel closed)")
            session.cancel()
        }
        updateSessionWatch()
    }

    // NSStatusItemExpandedInterfaceDelegate

    func statusItem(_ statusItem: NSStatusItem, didBegin expandedInterfaceSession: NSStatusItemExpandedInterfaceSession) {
        guard let id = id(of: statusItem) else { expandedInterfaceSession.cancel(); return }
        let lastClosed = panels.lastClosed.map { (group: $0.group, secondsAgo: Date().timeIntervalSince($0.at)) }
        let decision = CustomItemsGroupLogic.decideSessionBegin(group: id, panelVisibleFor: panels.visibleGroup, lastClosed: lastClosed)
        note("session began \(id): \(decision == .present ? "present" : "cancel") (event \(NSApp.currentEvent?.type.rawValue ?? 0))")
        if decision == .cancel {
            if panels.visibleGroup == id { panels.dismiss() }
            expandedInterfaceSession.cancel()
            return
        }
        sessions[id] = expandedInterfaceSession
        openGroup(id)
        if panels.visibleGroup != id {
            // Nothing could be shown.
            sessions.removeValue(forKey: id)?.cancel()
        }
        updateSessionWatch()
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        guard let id = id(of: statusItem) else { return }
        note("session ended \(id)")
        sessions.removeValue(forKey: id)
        if panels.visibleGroup == id { panels.dismiss() }
        updateSessionWatch()
    }

    // MARK: Second click

    /// While a group's session runs, a second click on the group's own item produces no
    /// session callback and no button action (measured on 27.2.1 with synthetic clicks; a
    /// hardware click is unverified). Watch for it here: a global mouse-down monitor saw the
    /// untagged clicks, the pressed-button state the tagged ones.
    private func updateSessionWatch() {
        let active = !sessions.isEmpty
        if active, watchTimer == nil {
            watchButtonDown = NSEvent.pressedMouseButtons & 1 != 0
            let mouseDowns: NSEvent.EventTypeMask = [.leftMouseDown]
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDowns, handler: { [weak self] _ in
                self?.sessionPress(at: NSEvent.mouseLocation, via: "global")
            }) { watchMonitors.append(monitor) }
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: mouseDowns, handler: { [weak self] event in
                self?.sessionPress(at: NSEvent.mouseLocation, via: "local")
                return event
            }) { watchMonitors.append(monitor) }
            let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollButton() }
            }
            RunLoop.main.add(timer, forMode: .common)
            watchTimer = timer
        } else if !active, let timer = watchTimer {
            timer.invalidate()
            watchTimer = nil
            watchMonitors.forEach(NSEvent.removeMonitor)
            watchMonitors.removeAll()
        }
    }

    private func pollButton() {
        let down = NSEvent.pressedMouseButtons & 1 != 0
        defer { watchButtonDown = down }
        if down, !watchButtonDown { sessionPress(at: NSEvent.mouseLocation, via: "poll") }
    }

    private func sessionPress(at location: CGPoint, via source: String) {
        for id in Array(sessions.keys) where frame(of: id)?.insetBy(dx: 0, dy: -1).contains(location) == true {
            note("second click on \(id) (\(source)): closing")
            if panels.visibleGroup == id { panels.dismiss() }
            sessions.removeValue(forKey: id)?.cancel()
        }
        updateSessionWatch()
    }

    // MARK: Hover

    private func setHoverMonitoring(_ on: Bool) {
        guard on != !hoverMonitors.isEmpty else { return }
        if on {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in self?.pointerMoved() }) {
                hoverMonitors.append(monitor)
            }
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
                self?.pointerMoved()
                return event
            }) { hoverMonitors.append(monitor) }
        } else {
            hoverMonitors.forEach(NSEvent.removeMonitor)
            hoverMonitors.removeAll()
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
    }

    private func pointerMoved() {
        let mouse = NSEvent.mouseLocation
        let groups = store.model.groups.filter { $0.opensOnHover && isShown($0.id) }
        let over = groups.first { frame(of: $0.id)?.insetBy(dx: 0, dy: -1).contains(mouse) == true }?.id
        switch hover.pointerOver(group: over, panelVisibleFor: panels.visibleGroup) {
        case .wait(let group):
            hoverTimer?.invalidate()
            let timer = Timer(timeInterval: CustomItemsHoverTracker.dwell, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.hover.dwellElapsed(group: group) else { return }
                    self.openGroup(group, gesture: .hover)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            hoverTimer = timer
        case .cancelWait:
            hoverTimer?.invalidate()
            hoverTimer = nil
        case .nothing:
            break
        }
    }

    // MARK: Debug

    private func note(_ event: String) {
        log.info(event)
        events.append("\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(event)")
        if events.count > 60 { events.removeFirst(events.count - 60) }
    }

    struct Snapshot: Codable {
        struct Item: Codable {
            var id: String
            var kind: String
            var visible: Bool
            var length: CGFloat
            var autosaveName: String
            /// Global top-left points (CGEvent coordinates), nil when not in a bar.
            var frame: CGRect?
            var hasImage: Bool
            var accessibilityLabel: String?
            var session: Bool
        }
        var items: [Item]
        var visibleGroup: String?
        var emptyState: Bool
        var lastDismissal: String?
        var hoverMonitoring: Bool
        var sessionWatch: Bool
        var events: [String]
    }

    func snapshot() -> Snapshot {
        let items = slots.values.sorted { $0.id < $1.id }.map { slot in
            Snapshot.Item(id: slot.id, kind: slot.kind.rawValue, visible: slot.item.isVisible, length: slot.item.length,
                          autosaveName: slot.item.autosaveName, frame: frame(of: slot.id).map(ScreenGeometry.topLeftRect(fromAppKit:)),
                          hasImage: slot.item.button?.image != nil, accessibilityLabel: slot.item.button?.accessibilityLabel(),
                          session: sessions[slot.id] != nil)
        }
        return Snapshot(items: items, visibleGroup: panels.visibleGroup, emptyState: panels.isShowingEmptyState,
                        lastDismissal: panels.lastDismissal, hoverMonitoring: !hoverMonitors.isEmpty,
                        sessionWatch: watchTimer != nil, events: events)
    }
}

/// Hover-to-open for groups: a short dwell over the item opens it; after its panel closes
/// with the pointer still on the item, the pointer must leave before hover opens it again.
nonisolated struct CustomItemsHoverTracker: Sendable {
    enum Action: Equatable {
        case wait(String)
        case cancelWait
        case nothing
    }

    static let dwell: TimeInterval = 0.3

    private(set) var pending: String?
    private(set) var suppressed: String?
    private var lastOver: String?

    mutating func pointerOver(group: String?, panelVisibleFor visible: String?) -> Action {
        defer { lastOver = group }
        if suppressed != nil, group != suppressed { suppressed = nil }
        // Still over the same group (or still outside every group).
        if group == lastOver { return .nothing }
        let hadPending = pending != nil
        pending = nil
        guard let group, visible != group, suppressed != group else { return hadPending ? .cancelWait : .nothing }
        pending = group
        return .wait(group)
    }

    /// The dwell timer fired: open if the pointer is still on the same group.
    mutating func dwellElapsed(group: String) -> Bool {
        guard pending == group else { return false }
        pending = nil
        return true
    }

    mutating func panelClosed(group: String) {
        if lastOver == group { suppressed = group }
    }
}

/// Arguments for a command a widget click runs: the user's, plus `gesture=click` when the
/// command takes a gesture the user left unset (a synthetic or forwarded click cannot be
/// inferred as one, docs/PLATFORM.md §10).
nonisolated enum CustomItemsCommandArguments {
    static func forClick(_ arguments: [String: String], declared: [(name: String, allowedValues: [String]?)]) -> [String: String] {
        var result = arguments
        if result["gesture"] == nil, let gesture = declared.first(where: { $0.name == "gesture" }),
           gesture.allowedValues?.contains("click") ?? true {
            result["gesture"] = "click"
        }
        return result
    }
}

/// Turns a widget's "open" target into a URL: a URL string with a scheme, or a file path
/// (`~` expanded).
nonisolated enum CustomItemsActionTarget {
    static func url(for target: String) -> URL? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return URL(filePath: (trimmed as NSString).expandingTildeInPath)
        }
        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty { return url }
        return nil
    }
}
