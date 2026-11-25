import AppKit
import RolltopCore
import SwiftUI

/// What the editor sheet edits.
enum CustomItemsEditorTarget: Identifiable {
    case spacer(CustomItemSpacer, isNew: Bool)
    case group(CustomItemGroup, isNew: Bool)
    case widget(CustomItemWidget, isNew: Bool)

    var id: String {
        switch self {
        case .spacer(let spacer, _): spacer.id
        case .group(let group, _): group.id
        case .widget(let widget, _): widget.id
        }
    }
}

/// Settings pane "Custom Items": spacers, groups and widgets with on/off switches, live
/// previews, reordering (for this list only) and editor sheets.
struct CustomItemsSettingsView: View {
    let context: AppContext
    let store: CustomItemsStore
    let hub: CustomItemsSamplerHub
    let openGroup: (String) -> Void

    @State private var editing: CustomItemsEditorTarget?
    @State private var deleting: String?
    @State private var approving: CustomItemWidget?
    @State private var isWindowVisible = true

    private var model: CustomItemsModel { store.model }

    var body: some View {
        Form {
            Section {
                LimitationNote(Text("These items belong to Rolltop, so macOS shows them whenever Rolltop runs: they cannot be hidden with your other items. Hold ⌘ and drag an item to move it in the menu bar.",
                                    tableName: "CustomItems"))
                if store.isReadOnly {
                    LimitationNote(Text("Stored custom items could not be read. They are left untouched and cannot be changed here.", tableName: "CustomItems"),
                                   tone: .warning)
                }
                if model.unreadableCount > 0 {
                    LimitationNote(Text("\(model.unreadableCount) items made by a newer version of Rolltop are kept but not shown.", tableName: "CustomItems"))
                }
            }

            if model.isEmpty {
                Section {
                    templateButtons
                } header: {
                    Text("Get started", tableName: "CustomItems")
                } footer: {
                    Text("Start from a template; you can change everything afterward.", tableName: "CustomItems")
                }
            }

            spacersSection
            groupsSection
            widgetsSection
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { target in
            CustomItemsEditorSheet(target: target, context: context, store: store, hub: hub) { editing = nil }
        }
        .alert(Text("Delete “\(deleting.map(name(of:)) ?? "")”?", tableName: "CustomItems"),
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { id in
            Button(role: .destructive) { store.remove(id) } label: { Text("Delete", tableName: "CustomItems") }
            Button(role: .cancel) {} label: { Text("Cancel", tableName: "CustomItems") }
        } message: { _ in
            Text("The item leaves the menu bar.", tableName: "CustomItems")
        }
        .alert(Text("Run this script on this Mac?", tableName: "CustomItems"),
               isPresented: Binding(get: { approving != nil }, set: { if !$0 { approving = nil } }), presenting: approving) { widget in
            Button { store.approveAndEnable(widget.id) } label: { Text("Turn On", tableName: "CustomItems") }
            Button(role: .cancel) {} label: { Text("Cancel", tableName: "CustomItems") }
        } message: { widget in
            Text("Rolltop will run “\(widget.scriptCommand)” every \(Duration.seconds(Int(widget.effectiveInterval)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))) with your account’s permissions. Only turn on scripts you wrote or trust.",
                 tableName: "CustomItems")
        }
        // The settings window keeps its panes alive when it closes: follow the window
        // itself, so previews stop sampling once it is closed or fully covered.
        .background(CustomItemsWindowVisibility { visible in
            isWindowVisible = visible
            updatePreviewDemand()
        })
        .onAppear {
            updatePreviewDemand()
            openPendingEditor()
        }
        .onDisappear {
            isWindowVisible = false
            updatePreviewDemand()
        }
        .onChange(of: store.pendingEditID) { openPendingEditor() }
        .onChange(of: model.widgets) { updatePreviewDemand() }
    }

    // MARK: Sections

    private var spacersSection: some View {
        Section {
            ForEach(model.spacers) { spacer in
                CustomItemsRow(title: Text("Spacer", tableName: "CustomItems"),
                               subtitle: Text(CustomItemsSettingsView.describe(spacer)),
                               preview: CustomItemsRenderer.spacer(spacer),
                               isOn: binding(for: spacer.id),
                               onEdit: { editing = .spacer(spacer, isNew: false) },
                               onDelete: { deleting = spacer.id })
            }
            .onMove { store.move(.spacer, fromOffsets: $0, toOffset: $1) }
            Button { editing = .spacer(CustomItemSpacer(id: store.newID(.spacer)), isNew: true) } label: {
                Text("Add Spacer", tableName: "CustomItems")
            }
        } header: {
            Text("Spacers", tableName: "CustomItems")
        } footer: {
            Text("A gap between items, blank or with a short text, an emoji or a symbol. Right-click a spacer in the menu bar to edit or remove it.",
                 tableName: "CustomItems")
        }
    }

    private var groupsSection: some View {
        Section {
            ForEach(model.groups) { group in
                CustomItemsRow(title: Text(group.name.isEmpty ? String(localized: "Group", table: "CustomItems") : group.name),
                               subtitle: Text("\(group.members.count) items", tableName: "CustomItems"),
                               preview: CustomItemsRenderer.group(group),
                               isOn: binding(for: group.id),
                               onEdit: { editing = .group(group, isNew: false) },
                               onDelete: { deleting = group.id },
                               extraMenu: store.isActive(group.id) ? AnyView(Button { openGroup(group.id) } label: { Text("Show Items", tableName: "CustomItems") }) : nil)
            }
            .onMove { store.move(.group, fromOffsets: $0, toOffset: $1) }
            Menu {
                Button { editing = .group(newGroup(hiddenApps: false), isNew: true) } label: { Text("Empty Group", tableName: "CustomItems") }
                Button { editing = .group(newGroup(hiddenApps: true), isNew: true) } label: { Text("“Hidden apps” Group", tableName: "CustomItems") }
            } label: {
                Text("Add Group", tableName: "CustomItems")
            }
            .fixedSize()
        } header: {
            Text("Groups", tableName: "CustomItems")
        } footer: {
            Text("One icon that collects other items: clicking it shows them in the Rolltop Bar right below. Put the members in Hidden so the group tidies the bar; members that are not running are skipped.",
                 tableName: "CustomItems")
        }
    }

    private var widgetsSection: some View {
        Section {
            ForEach(model.widgets) { widget in
                let content = CustomItemsWidgetText.content(for: widget, readings: hub.readings)
                CustomItemsRow(title: Text(CustomItemsText.title(of: widget.source)),
                               subtitle: Text(CustomItemsText.summary(of: widget)),
                               preview: CustomItemsRenderer.widget(content, fixedWidth: widget.clampedFixedWidth),
                               isOn: widgetBinding(for: widget),
                               onEdit: { editing = .widget(widget, isNew: false) },
                               onDelete: { deleting = widget.id },
                               note: note(for: widget))
            }
            .onMove { store.move(.widget, fromOffsets: $0, toOffset: $1) }
            Menu {
                ForEach(CustomItemsTemplates.widgetChoices(batteryPresent: hub.readings.batteryPresent), id: \.self) { choice in
                    Button { editing = .widget(CustomItemsTemplates.widget(choice, id: store.newID(.widget)), isNew: true) } label: {
                        Text(CustomItemsTemplates.title(of: choice))
                    }
                }
            } label: {
                Text("Add Widget", tableName: "CustomItems")
            }
            .fixedSize()
        } header: {
            Text("Widgets", tableName: "CustomItems")
        } footer: {
            Text("Small live read-outs. A click can open an app, a file or a link, run a Rolltop command or show details. Sampling pauses while the displays sleep.",
                 tableName: "CustomItems")
        }
    }

    private var templateButtons: some View {
        HStack(spacing: 8) {
            Button { store.upsert(spacer: CustomItemSpacer(id: store.newID(.spacer), glyph: .symbol("circle.fill"))) } label: {
                Text("Spacer", tableName: "CustomItems")
            }
            Button { store.upsert(group: newGroup(hiddenApps: true)) } label: { Text("Hidden apps", tableName: "CustomItems") }
            Button { store.upsert(widget: CustomItemsTemplates.widget(.cpu, id: store.newID(.widget))) } label: { Text("CPU", tableName: "CustomItems") }
            Button { store.upsert(widget: CustomItemsTemplates.widget(.network, id: store.newID(.widget))) } label: { Text("Network", tableName: "CustomItems") }
            Button { store.upsert(widget: CustomItemsTemplates.widget(.secondClock, id: store.newID(.widget))) } label: { Text("Second clock", tableName: "CustomItems") }
        }
    }

    // MARK: Helpers

    private func newGroup(hiddenApps: Bool) -> CustomItemGroup {
        let id = store.newID(.group)
        guard hiddenApps else { return CustomItemGroup(id: id, name: String(localized: "Group", table: "CustomItems")) }
        let members = CustomItemsGroupLogic.hiddenAppsMembers(layout: context.layout.layout, entries: context.catalog.entries)
        return CustomItemGroup(id: id, name: String(localized: "Hidden apps", table: "CustomItems"), icon: .symbol("eye.slash"), members: members)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { store.isActive(id) }, set: { store.setEnabled(id, $0) })
    }

    /// Script widgets ask before they run for the first time on this Mac.
    private func widgetBinding(for widget: CustomItemWidget) -> Binding<Bool> {
        Binding(get: { store.isActive(widget.id) }, set: { on in
            if on, widget.source == .script, !store.isApproved(widget) {
                approving = widget
            } else {
                store.setEnabled(widget.id, on)
            }
        })
    }

    private func note(for widget: CustomItemWidget) -> Text? {
        if widget.source == .script, widget.isEnabled, !store.isApproved(widget) {
            return Text("Turned off until you allow it to run on this Mac.", tableName: "CustomItems")
        }
        if widget.source == .battery, hub.readings.batteryPresent == false {
            return Text("This Mac has no battery: the widget is not shown.", tableName: "CustomItems")
        }
        return nil
    }

    private func name(of id: String) -> String {
        if let group = model.group(id) { return group.name }
        if let widget = model.widget(id) { return CustomItemsText.title(of: widget.source) }
        return String(localized: "Spacer", table: "CustomItems")
    }

    static func describe(_ spacer: CustomItemSpacer) -> String {
        let width = String(localized: "\(Int(spacer.clampedWidth)) pt", table: "CustomItems")
        return spacer.glyph.isBlank ? width : "\(width) · \(CustomItemsText.title(of: spacer.glyph.kind))"
    }

    /// Previews sample every widget's source while the pane is open (scripts excepted).
    private func updatePreviewDemand() {
        hub.setDemand(isWindowVisible ? CustomItemsDemand.sources(for: model.widgets) : [:], client: "settings")
    }

    private func openPendingEditor() {
        guard let id = store.pendingEditID else { return }
        store.pendingEditID = nil
        if let spacer = model.spacer(id) { editing = .spacer(spacer, isNew: false) }
        else if let group = model.group(id) { editing = .group(group, isNew: false) }
        else if let widget = model.widget(id) { editing = .widget(widget, isNew: false) }
    }
}

// MARK: - Row

private struct CustomItemsRow: View {
    let title: Text
    let subtitle: Text
    let preview: CustomItemsRenderer.Rendering
    let isOn: Binding<Bool>
    let onEdit: () -> Void
    let onDelete: () -> Void
    var note: Text?
    var extraMenu: AnyView?

    var body: some View {
        HStack(spacing: 10) {
            CustomItemsPreview(rendering: preview, maxWidth: 120)
                .frame(width: 120, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                title
                subtitle
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note {
                    note.font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            Menu {
                Button(action: onEdit) { Text("Edit…", tableName: "CustomItems") }
                if let extraMenu { extraMenu }
                Divider()
                Button(role: .destructive, action: onDelete) { Text("Delete…", tableName: "CustomItems") }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel(Text("More", tableName: "CustomItems"))
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            Toggle(isOn: isOn) { title }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
    }
}

/// An item as it looks in the bar: the same template image, on a strip of bar. Items wider
/// than `maxWidth` are scaled down to fit.
struct CustomItemsPreview: View {
    let rendering: CustomItemsRenderer.Rendering
    var maxWidth: CGFloat = 200

    var body: some View {
        let length = max(rendering.length, 8)
        let scale = min(1, maxWidth / length)
        let height = CustomItemsRenderer.height
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(.quaternary)
            if let image = rendering.image {
                Image(nsImage: image)
                    .renderingMode(image.isTemplate ? .template : .original)
                    .resizable()
                    .foregroundStyle(.primary)
                    .frame(width: rendering.length * scale, height: height * scale)
            } else {
                // A blank spacer: show its extent.
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .padding(.vertical, 6 * scale)
            }
        }
        .frame(width: length * scale, height: height * scale + 2)
        .clipped()
        .accessibilityHidden(true)
    }
}

// MARK: - Templates

enum CustomItemsTemplates {
    enum WidgetChoice: Hashable {
        case cpu, memory, network, battery, disk, clock, secondClock, label, script
        case gpu, music, calendar, focus, weather
    }

    static func widgetChoices(batteryPresent: Bool?) -> [WidgetChoice] {
        var choices: [WidgetChoice] = [.cpu, .gpu, .memory, .network]
        if batteryPresent != false { choices.append(.battery) }
        choices += [.disk, .clock, .secondClock, .music, .calendar, .focus, .weather, .label, .script]
        return choices
    }

    static func title(of choice: WidgetChoice) -> String {
        switch choice {
        case .cpu: CustomItemsText.title(of: .cpu)
        case .memory: CustomItemsText.title(of: .memory)
        case .network: CustomItemsText.title(of: .network)
        case .battery: CustomItemsText.title(of: .battery)
        case .disk: CustomItemsText.title(of: .disk)
        case .clock: CustomItemsText.title(of: .clock)
        case .secondClock: String(localized: "Second clock", table: "CustomItems")
        case .label: String(localized: "Label (launcher)", table: "CustomItems")
        case .script: String(localized: "Script output", table: "CustomItems")
        case .gpu: CustomItemsText.title(of: .gpu)
        case .music: CustomItemsText.title(of: .music)
        case .calendar: CustomItemsText.title(of: .calendar)
        case .focus: CustomItemsText.title(of: .focus)
        case .weather: CustomItemsText.title(of: .weather)
        }
    }

    static func widget(_ choice: WidgetChoice, id: String) -> CustomItemWidget {
        switch choice {
        case .cpu: CustomItemWidget(id: id, source: .cpu, showsHistory: true)
        case .memory: CustomItemWidget(id: id, source: .memory)
        case .network: CustomItemWidget(id: id, source: .network, networkDirection: .both)
        case .battery: CustomItemWidget(id: id, source: .battery)
        case .disk: CustomItemWidget(id: id, source: .disk)
        case .clock: CustomItemWidget(id: id, source: .clock, clockFormat: "EEE HH:mm")
        case .secondClock:
            CustomItemWidget(id: id, source: .clock, clockFormat: "HH:mm", timeZone: secondTimeZone.identifier,
                             label: secondTimeZone.abbreviation() ?? "UTC")
        case .label:
            CustomItemWidget(id: id, source: .label, style: .symbolOnly, symbol: "app.badge",
                             action: CustomItemWidgetAction(kind: .open, target: "/System/Applications/Utilities/Activity Monitor.app"))
        // Script widgets start off: they run only after the user turns them on here.
        case .script: CustomItemWidget(id: id, source: .script, isEnabled: false, interval: 60, scriptCommand: "date +%H:%M")
        case .gpu: CustomItemWidget(id: id, source: .gpu)
        case .music: CustomItemWidget(id: id, source: .music)
        case .calendar: CustomItemWidget(id: id, source: .calendar, style: .textOnly)
        case .focus: CustomItemWidget(id: id, source: .focus)
        case .weather: CustomItemWidget(id: id, source: .weather)
        }
    }

    /// UTC, or New York when this Mac already runs on UTC.
    static var secondTimeZone: TimeZone {
        let utc = TimeZone(identifier: "UTC") ?? .gmt
        return TimeZone.current.secondsFromGMT() == 0 ? (TimeZone(identifier: "America/New_York") ?? utc) : utc
    }
}

/// Reports whether the window hosting a view is on screen and not fully covered.
struct CustomItemsWindowVisibility: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> Reporter {
        let view = Reporter()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: Reporter, context: Context) {
        view.onChange = onChange
    }

    final class Reporter: NSView {
        var onChange: ((Bool) -> Void)?
        private var lastReported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: window)
                }
            }
            report(window.map { $0.occlusionState.contains(.visible) } ?? false)
        }

        @objc private func windowChanged(_ notification: Notification) {
            report(notification.name != NSWindow.willCloseNotification && window?.occlusionState.contains(.visible) == true)
        }

        private func report(_ visible: Bool) {
            guard visible != lastReported else { return }
            lastReported = visible
            // Not during a view update.
            DispatchQueue.main.async { [weak self] in self?.onChange?(visible) }
        }
    }
}
