import AppKit
import RolltopCore
import SwiftUI
import UniformTypeIdentifiers

/// The editor sheet for one spacer, group or widget. Edits a draft; Save writes it.
struct CustomItemsEditorSheet: View {
    let target: CustomItemsEditorTarget
    let context: AppContext
    let store: CustomItemsStore
    let hub: CustomItemsSamplerHub
    let onClose: () -> Void

    var body: some View {
        Group {
            switch target {
            case .spacer(let spacer, let isNew):
                CustomItemsSpacerEditor(draft: spacer, isNew: isNew, store: store, onClose: onClose)
            case .group(let group, let isNew):
                CustomItemsGroupEditor(draft: group, isNew: isNew, context: context, store: store, onClose: onClose)
            case .widget(let widget, let isNew):
                CustomItemsWidgetEditor(draft: widget, isNew: isNew, context: context, store: store, hub: hub, onClose: onClose)
            }
        }
        // A new draft for every item: the sheet may switch items while it is shown.
        .id(target.id)
    }
}

/// Title, live preview on a strip of bar, the form, Cancel / Save.
private struct CustomItemsEditorFrame<Content: View>: View {
    let title: Text
    let preview: CustomItemsRenderer.Rendering
    let isNew: Bool
    var canSave = true
    let onCancel: () -> Void
    let onSave: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                title.font(.headline)
                Spacer()
                CustomItemsPreview(rendering: preview)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 4)
            Form { content() }
                .formStyle(.grouped)
            HStack {
                Spacer()
                Button(role: .cancel, action: onCancel) { Text("Cancel", tableName: "CustomItems") }
                    .keyboardShortcut(.cancelAction)
                Button(action: onSave) {
                    isNew ? Text("Add", tableName: "CustomItems") : Text("Save", tableName: "CustomItems")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 520)
        .frame(minHeight: 360, idealHeight: 560)
        .controlSize(.regular)
    }
}

// MARK: - Glyph editor

/// Blank (when allowed), text, emoji or SF Symbol.
private struct CustomItemsGlyphEditor: View {
    @Binding var glyph: CustomItemGlyph
    let allowsBlank: Bool
    let suggestions: [String]

    var body: some View {
        Picker(selection: Binding(get: { glyph.kind }, set: { kind in
            glyph = CustomItemGlyph(kind: kind, value: kind == glyph.kind ? glyph.value : defaultValue(for: kind))
        })) {
            ForEach(CustomItemGlyphKind.allCases.filter { allowsBlank || $0 != .none }, id: \.self) { kind in
                Text(CustomItemsText.title(of: kind)).tag(kind)
            }
        } label: {
            Text("Content", tableName: "CustomItems")
        }
        .pickerStyle(.segmented)

        switch glyph.kind {
        case .none:
            EmptyView()
        case .text:
            TextField(text: Binding(get: { glyph.value }, set: { glyph.value = String($0.prefix(CustomItemGlyph.maximumTextLength)) })) {
                Text("Text", tableName: "CustomItems")
                Text("Up to \(CustomItemGlyph.maximumTextLength) characters.", tableName: "CustomItems")
            }
        case .emoji:
            LabeledContent {
                HStack {
                    TextField(text: Binding(get: { glyph.value }, set: { glyph.value = String($0.prefix(2)) })) { EmptyView() }
                        .labelsHidden()
                        .frame(width: 60)
                    Button { NSApp.orderFrontCharacterPalette(nil) } label: { Text("Emoji & Symbols…", tableName: "CustomItems") }
                }
            } label: {
                Text("Emoji", tableName: "CustomItems")
            }
        case .symbol:
            CustomItemsSymbolField(name: Binding(get: { glyph.value }, set: { glyph.value = $0 }), suggestions: suggestions)
        }
    }

    private func defaultValue(for kind: CustomItemGlyphKind) -> String {
        switch kind {
        case .none: ""
        case .text: "|"
        case .emoji: "✨"
        case .symbol: suggestions.first ?? "circle.fill"
        }
    }
}

/// An SF Symbol name with a few suggestions and a check that the name exists.
private struct CustomItemsSymbolField: View {
    @Binding var name: String
    let suggestions: [String]

    var body: some View {
        TextField(text: $name) {
            Text("Symbol name", tableName: "CustomItems")
            if !name.isEmpty, NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil {
                Text("No SF Symbol has this name.", tableName: "CustomItems").foregroundStyle(.orange)
            } else {
                Text("Any SF Symbol name, as shown in the SF Symbols app.", tableName: "CustomItems")
            }
        }
        LabeledContent {
            HStack(spacing: 4) {
                ForEach(suggestions, id: \.self) { symbol in
                    Button { name = symbol } label: {
                        Image(systemName: symbol)
                            .frame(width: 22, height: 18)
                    }
                    .buttonStyle(.borderless)
                    .help(symbol)
                }
            }
        } label: {
            Text("Suggestions", tableName: "CustomItems")
        }
    }
}

// MARK: - Spacer

private struct CustomItemsSpacerEditor: View {
    @State var draft: CustomItemSpacer
    let isNew: Bool
    let store: CustomItemsStore
    let onClose: () -> Void

    var body: some View {
        CustomItemsEditorFrame(title: isNew ? Text("New Spacer", tableName: "CustomItems") : Text("Edit Spacer", tableName: "CustomItems"),
                               preview: CustomItemsRenderer.spacer(draft), isNew: isNew, onCancel: onClose,
                               onSave: { store.upsert(spacer: draft); onClose() }) {
            Section {
                LabeledContent {
                    HStack {
                        Slider(value: Binding(get: { draft.width }, set: { draft.width = $0.rounded() }), in: CustomItemSpacer.widthRange) { EmptyView() }
                            .labelsHidden()
                        Text("\(Int(draft.clampedWidth)) pt", tableName: "CustomItems")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                } label: {
                    Text("Width", tableName: "CustomItems")
                    Text("macOS adds its usual gap on both sides.", tableName: "CustomItems")
                }
                CustomItemsGlyphEditor(glyph: $draft.glyph, allowsBlank: true,
                                       suggestions: ["circle.fill", "smallcircle.filled.circle", "star.fill", "diamond.fill", "minus", "poweron", "chevron.compact.right", "sparkle"])
            } footer: {
                Text("Content is drawn quietly, in the menu bar’s secondary style.", tableName: "CustomItems")
            }
        }
    }
}

// MARK: - Group

private struct CustomItemsGroupEditor: View {
    @State var draft: CustomItemGroup
    let isNew: Bool
    let context: AppContext
    let store: CustomItemsStore
    let onClose: () -> Void
    /// A member just added that is shown in the bar.
    @State private var suggestHiding: OwnerID?

    var body: some View {
        CustomItemsEditorFrame(title: isNew ? Text("New Group", tableName: "CustomItems") : Text("Edit Group", tableName: "CustomItems"),
                               preview: CustomItemsRenderer.group(draft), isNew: isNew, onCancel: onClose,
                               onSave: { store.upsert(group: draft); onClose() }) {
            Section {
                TextField(text: $draft.name) { Text("Name", tableName: "CustomItems") }
                CustomItemsGlyphEditor(glyph: $draft.icon, allowsBlank: false,
                                       suggestions: ["square.grid.2x2", "eye.slash", "tray.full", "folder", "ellipsis.circle", "star", "bolt", "gearshape"])
                Toggle(isOn: $draft.opensOnHover) {
                    Text("Open on hover", tableName: "CustomItems")
                    Text("Shows the items when the pointer rests on the group’s icon.", tableName: "CustomItems")
                }
            }

            Section {
                if draft.members.isEmpty {
                    Text("No items yet. Add some from the list below.", tableName: "CustomItems").foregroundStyle(.secondary)
                }
                ForEach(draft.members, id: \.self) { raw in
                    memberRow(raw)
                }
                .onMove { draft.members.move(fromOffsets: $0, toOffset: $1) }
                if let owner = suggestHiding, sectionOf(owner) == .shown {
                    LimitationNote(text: Text("“\(context.catalog.displayName(for: owner))” is shown in the menu bar. Move it to Hidden so the group tidies the bar.",
                                              tableName: "CustomItems")) {
                        HStack {
                            Button { context.layout.setSection(.hidden, for: owner); suggestHiding = nil } label: {
                                Text("Move to Hidden", tableName: "CustomItems")
                            }
                            Button { suggestHiding = nil } label: { Text("Keep Shown", tableName: "CustomItems") }
                        }
                    }
                }
            } header: {
                Text("Items in this group", tableName: "CustomItems")
            } footer: {
                Text("Items that are not running are skipped when the group opens.", tableName: "CustomItems")
            }

            Section {
                let candidates = CustomItemsGroupLogic.candidates(entries: context.catalog.entries, members: draft.members)
                if candidates.isEmpty {
                    Text("Every menu bar item is already in this group.", tableName: "CustomItems").foregroundStyle(.secondary)
                }
                ForEach(candidates, id: \.self) { owner in
                    HStack {
                        OwnerIcon(owner: owner, services: context.services, size: 18)
                        Text(context.catalog.displayName(for: owner))
                        Spacer()
                        sectionLabel(sectionOf(owner))
                        Button {
                            draft.members.append(owner.stringValue)
                            if CustomItemsGroupLogic.suggestsHiding(section: sectionOf(owner)) { suggestHiding = owner }
                        } label: {
                            Image(systemName: "plus.circle")
                                .accessibilityLabel(Text("Add", tableName: "CustomItems"))
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Menu bar items", tableName: "CustomItems")
            }
        }
    }

    private func memberRow(_ raw: String) -> some View {
        let owner = OwnerID(stringValue: raw)
        let running = owner.map { owner in
            switch owner {
            case .app(let id): context.catalog.runningApps.contains { $0.bundleID == id }
            case .system: context.catalog.presentOwners.contains(owner)
            }
        } ?? false
        return HStack {
            OwnerIcon(owner: owner, services: context.services, size: 18)
            VStack(alignment: .leading) {
                Text(owner.map { context.catalog.displayName(for: $0) } ?? raw)
                if !running {
                    Text("Not running", tableName: "CustomItems").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let owner { sectionLabel(sectionOf(owner)) }
            Button { draft.members.removeAll { $0 == raw } } label: {
                Image(systemName: "minus.circle")
                    .accessibilityLabel(Text("Remove", tableName: "CustomItems"))
            }
            .buttonStyle(.borderless)
        }
    }

    private func sectionOf(_ owner: OwnerID) -> RolltopCore.Section {
        context.layout.layout.section(for: owner)
    }

    private func sectionLabel(_ section: RolltopCore.Section) -> some View {
        let text: Text = switch section {
        case .shown: Text("Shown", tableName: "CustomItems")
        case .hidden: Text("Hidden", tableName: "CustomItems")
        case .alwaysHidden: Text("Always hidden", tableName: "CustomItems")
        }
        return text.font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - Widget

private struct CustomItemsWidgetEditor: View {
    @State var draft: CustomItemWidget
    let isNew: Bool
    let context: AppContext
    let store: CustomItemsStore
    let hub: CustomItemsSamplerHub
    let onClose: () -> Void

    /// Pattern presets, with dates in the order the user's locale writes them ("M月d日 EEE HH:mm").
    private static let clockFormats: [String] = {
        func pattern(_ template: String) -> String {
            DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: .autoupdatingCurrent) ?? template
        }
        return ["HH:mm", "HH:mm:ss", pattern("hmma"), "EEE HH:mm", pattern("EEEdMMM") + " HH:mm", pattern("dMMM"), "yyyy-MM-dd"]
    }()

    var body: some View {
        let content = CustomItemsWidgetText.content(for: draft, readings: hub.readings)
        CustomItemsEditorFrame(title: isNew ? Text("New Widget", tableName: "CustomItems") : Text("Edit Widget", tableName: "CustomItems"),
                               preview: CustomItemsRenderer.widget(content, fixedWidth: draft.clampedFixedWidth), isNew: isNew,
                               canSave: draft.source != .script || !draft.scriptCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               onCancel: onClose, onSave: save) {
            Section {
                Picker(selection: Binding(get: { draft.source }, set: changeSource)) {
                    ForEach(CustomItemWidgetSource.allCases, id: \.self) { source in
                        Text(CustomItemsText.title(of: source)).tag(source)
                    }
                } label: {
                    Text("Shows", tableName: "CustomItems")
                }
                sourceOptions
            }

            Section {
                Picker(selection: $draft.style) {
                    ForEach(CustomItemWidgetStyle.allCases, id: \.self) { Text(CustomItemsText.title(of: $0)).tag($0) }
                } label: {
                    Text("Style", tableName: "CustomItems")
                }
                if draft.style != .textOnly {
                    CustomItemsSymbolField(name: $draft.symbol, suggestions: [draft.source.defaultSymbol, "gauge.with.dots.needle.33percent", "chart.bar", "waveform.path.ecg", "globe", "bolt", "star", "app.badge"])
                }
                if draft.source != .label, draft.style != .symbolOnly {
                    TextField(text: $draft.label) {
                        Text("Prefix", tableName: "CustomItems")
                        Text("A short text before the value, such as a city for a second clock.", tableName: "CustomItems")
                    }
                }
                Picker(selection: Binding(get: { draft.fixedWidth == nil }, set: { draft.fixedWidth = $0 ? nil : 80 })) {
                    Text("Automatic", tableName: "CustomItems").tag(true)
                    Text("Fixed", tableName: "CustomItems").tag(false)
                } label: {
                    Text("Width", tableName: "CustomItems")
                    Text("Automatic reserves room for the widest value, so neighboring items do not move.", tableName: "CustomItems")
                }
                if let width = draft.fixedWidth {
                    LabeledContent {
                        HStack {
                            Slider(value: Binding(get: { width }, set: { draft.fixedWidth = $0.rounded() }), in: CustomItemWidget.fixedWidthRange) { EmptyView() }
                                .labelsHidden()
                            Text("\(Int(width)) pt", tableName: "CustomItems").monospacedDigit().frame(width: 52, alignment: .trailing)
                        }
                    } label: {
                        Text("Fixed width", tableName: "CustomItems")
                    }
                }
                if draft.source.supportsHistory {
                    Toggle(isOn: $draft.showsHistory) {
                        Text("Show history", tableName: "CustomItems")
                        Text("A tiny graph of the last readings.", tableName: "CustomItems")
                    }
                }
            } header: {
                Text("Appearance", tableName: "CustomItems")
            }

            Section {
                Picker(selection: $draft.action.kind) {
                    ForEach(CustomItemWidgetActionKind.allCases, id: \.self) { Text(CustomItemsText.title(of: $0, source: draft.source)).tag($0) }
                } label: {
                    Text("When clicked", tableName: "CustomItems")
                    Text("A right-click always shows the details and “Edit Widget…”.", tableName: "CustomItems")
                }
                actionOptions
            } header: {
                Text("Click", tableName: "CustomItems")
            }
        }
    }

    // MARK: Source options

    @ViewBuilder private var sourceOptions: some View {
        switch draft.source {
        case .memory:
            Picker(selection: $draft.memoryFigure) {
                ForEach(CustomItemMemoryFigure.allCases, id: \.self) { Text(CustomItemsText.title(of: $0)).tag($0) }
            } label: { Text("Figure", tableName: "CustomItems") }
            intervalStepper
        case .network:
            Picker(selection: $draft.networkDirection) {
                ForEach(CustomItemNetworkDirection.allCases, id: \.self) { Text(CustomItemsText.title(of: $0)).tag($0) }
            } label: { Text("Direction", tableName: "CustomItems") }
            intervalStepper
        case .battery:
            Picker(selection: $draft.batteryFigure) {
                ForEach(CustomItemBatteryFigure.allCases, id: \.self) { Text(CustomItemsText.title(of: $0)).tag($0) }
            } label: { Text("Figure", tableName: "CustomItems") }
            if hub.readings.batteryPresent == false {
                LimitationNote(Text("This Mac has no battery: the widget is not shown.", tableName: "CustomItems"))
            }
        case .cpu, .disk:
            intervalStepper
        case .clock:
            LabeledContent {
                HStack {
                    TextField(text: $draft.clockFormat) { EmptyView() }.labelsHidden()
                    Menu {
                        ForEach(Self.clockFormats, id: \.self) { format in
                            Button(format) { draft.clockFormat = format }
                        }
                    } label: { Text("Presets", tableName: "CustomItems") }
                    .fixedSize()
                }
            } label: {
                Text("Format", tableName: "CustomItems")
                Text("Date format pattern: HH hours, mm minutes, ss seconds, EEE weekday, d day, MMM month.", tableName: "CustomItems")
            }
            Picker(selection: Binding(get: { draft.timeZone ?? "" }, set: { draft.timeZone = $0.isEmpty ? nil : $0 })) {
                Text("System time zone", tableName: "CustomItems").tag("")
                Divider()
                ForEach(TimeZone.knownTimeZoneIdentifiers.sorted(), id: \.self) { Text($0).tag($0) }
            } label: {
                Text("Time zone", tableName: "CustomItems")
                Text("Pick another zone to use the widget as a second clock.", tableName: "CustomItems")
            }
        case .label:
            TextField(text: $draft.label) { Text("Text", tableName: "CustomItems") }
        case .script:
            LabeledContent {
                // Monospaced for the command only, not for the row's caption.
                TextField(text: $draft.scriptCommand, axis: .vertical) { EmptyView() }
                    .labelsHidden()
                    .lineLimit(1...4)
                    .font(.body.monospaced())
            } label: {
                Text("Command", tableName: "CustomItems")
                Text("Runs with /bin/sh in a minimal environment; the first line of its output is shown.", tableName: "CustomItems")
            }
            Stepper(value: Binding(get: { draft.interval ?? draft.source.defaultInterval }, set: { draft.interval = max($0, CustomItemWidget.minimumScriptInterval) }),
                    in: CustomItemWidget.minimumScriptInterval...3600, step: 5) {
                Text("Every \(Int(draft.effectiveInterval)) seconds", tableName: "CustomItems")
            }
            Stepper(value: $draft.scriptTimeout, in: CustomItemWidget.scriptTimeoutRange, step: 1) {
                Text("Stop after \(Int(draft.effectiveScriptTimeout)) seconds", tableName: "CustomItems")
            }
            LimitationNote(Text("A script widget runs only after you turn it on in this list on this Mac. Imported or restored script widgets start turned off, and changing the command turns it off again.",
                                tableName: "CustomItems"))
        case .gpu:
            intervalStepper
            if hub.readings.gpuReported == false {
                LimitationNote(Text("This Mac does not report GPU usage: the widget shows a dash.", tableName: "CustomItems"), tone: .warning)
            } else {
                LimitationNote(Text("Reads the graphics processor’s usage. No permission needed.", tableName: "CustomItems"))
            }
        case .music:
            LimitationNote(text: Text("Shows what plays in Music or Spotify once you allow that app in Settings › Permissions. A click plays or pauses; the widget is hidden while nothing plays.",
                                tableName: "CustomItems")) {
                if !context.services[.nowPlaying].canControl { openPaneButton("permissions") }
            }
        case .calendar:
            if context.services[.upNext].isAuthorized {
                LimitationNote(Text("Shows the next event that starts within 24 hours, using the Calendars access you allowed for the Shelf.", tableName: "CustomItems"))
            } else {
                LimitationNote(text: Text("Allow Calendars in Settings › Permissions to show your next event. Until then the widget is hidden.", tableName: "CustomItems"),
                               tone: .warning) { openPaneButton("permissions") }
            }
        case .focus:
            LimitationNote(text: Text(verbatim: context.services[.focusState].sourceNote)) {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") { NSWorkspace.shared.open(url) }
                } label: { Text("Open Focus Settings…", tableName: "CustomItems") }
            }
        case .weather:
            let weather = context.services[.weather]
            if weather.isEnabled, weather.report != nil {
                LimitationNote(Text("Shows the weather for the place chosen in Settings › Weather.", tableName: "CustomItems"))
            } else {
                LimitationNote(text: Text("Weather is off or has no place yet: the widget is hidden. Turn it on and choose a place in Settings › Weather.", tableName: "CustomItems"),
                               tone: .warning) { openPaneButton("weather") }
            }
            Link(weather.attribution.text, destination: weather.attribution.url)
        }
    }

    /// Opens another settings pane (the editor closes; nothing is saved).
    private func openPaneButton(_ pane: String) -> some View {
        Button {
            onClose()
            context.services[.settingsWindow].showSettings(paneID: pane)
        } label: {
            pane == "weather" ? Text("Open Weather Settings", tableName: "CustomItems") : Text("Open Permissions", tableName: "CustomItems")
        }
    }

    private var intervalStepper: some View {
        Stepper(value: Binding(get: { draft.effectiveInterval }, set: { draft.interval = $0 == draft.source.defaultInterval ? nil : $0 }),
                in: 1...600, step: 1) {
            Text("Update every \(Int(draft.effectiveInterval)) seconds", tableName: "CustomItems")
        }
    }

    // MARK: Action options

    @ViewBuilder private var actionOptions: some View {
        switch draft.action.kind {
        case .none, .menu:
            EmptyView()
        case .open:
            LabeledContent {
                HStack {
                    TextField(text: $draft.action.target, prompt: Text("https://… or /Applications/…", tableName: "CustomItems")) { EmptyView() }
                        .labelsHidden()
                    Button { chooseTarget() } label: { Text("Choose…", tableName: "CustomItems") }
                }
            } label: {
                Text("Open", tableName: "CustomItems")
                if !draft.action.target.isEmpty, CustomItemsActionTarget.url(for: draft.action.target) == nil {
                    Text("Enter a link with its scheme (https://…) or a path starting with / or ~.", tableName: "CustomItems").foregroundStyle(.orange)
                }
            }
        case .command:
            // A click runs with source `.customItem`, which never runs destructive commands
            // (custom items can arrive through an import): offer only the others.
            let commands = context.commands.commands
                .filter { !$0.id.isDebugOnly && CommandEffectPolicy.allows($0.resolvedEffect, from: .customItem) }
                .sorted { $0.localizedTitle < $1.localizedTitle }
            Picker(selection: Binding(get: { draft.action.command }, set: { draft.action.command = $0; draft.action.arguments = [:] })) {
                Text("Choose a command", tableName: "CustomItems").tag("")
                ForEach(commands, id: \.id) { command in
                    Text(command.localizedTitle).tag(command.id.rawValue)
                }
            } label: {
                Text("Command", tableName: "CustomItems")
            }
            if let command = commands.first(where: { $0.id.rawValue == draft.action.command }) {
                ForEach(command.arguments, id: \.name) { argument in
                    argumentField(argument)
                }
            }
        }
    }

    @ViewBuilder private func argumentField(_ argument: CommandArgument) -> some View {
        let binding = Binding(get: { draft.action.arguments[argument.name] ?? "" },
                              set: { draft.action.arguments[argument.name] = $0.isEmpty ? nil : $0 })
        if let allowed = argument.allowedValues {
            Picker(selection: binding) {
                if !argument.isRequired { Text("Default", tableName: "CustomItems").tag("") }
                ForEach(allowed, id: \.self) { Text($0).tag($0) }
            } label: {
                Text(argument.title)
            }
        } else {
            TextField(text: binding) { Text(argument.title) }
        }
    }

    private func chooseTarget() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(filePath: "/Applications")
        panel.prompt = String(localized: "Choose", table: "CustomItems")
        if panel.runModal() == .OK, let url = panel.url { draft.action.target = url.path }
    }

    private func changeSource(_ source: CustomItemWidgetSource) {
        guard source != draft.source else { return }
        let fresh = CustomItemWidget(id: draft.id, source: source, isEnabled: source == .script ? false : draft.isEnabled)
        draft.source = source
        draft.style = fresh.style
        draft.symbol = fresh.symbol
        draft.interval = nil
        draft.showsHistory = draft.showsHistory && source.supportsHistory
        if source == .script { draft.isEnabled = false }
    }

    private func save() {
        store.upsert(widget: draft)
        onClose()
    }
}
