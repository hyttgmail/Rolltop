import AppKit
import RolltopCore
import SwiftUI
import UniformTypeIdentifiers

/// What the editor works on: a copy of the rule plus which of its scripts the user allows.
struct AutomationEditorDraft: Identifiable {
    let id = UUID()
    var rule: AutomationRule
    var isNew = false
    /// Script condition ids the user allowed to run (approval is per Mac, not in the rule).
    var approvedScripts: Set<String>
    /// Template "show an app's item while it is frontmost": choosing the app also shows its item.
    var linkAppToItems = false

    init(rule: AutomationRule, controller: AutomationsController) {
        self.rule = rule
        approvedScripts = Set(rule.scriptConditions.filter {
            controller.isApproved(rule: rule, conditionID: $0.id, command: $0.script.command)
        }.map(\.id))
    }
}

/// The rule editor sheet: name, conditions (all/any) with live state, actions, recent log.
struct AutomationRuleEditor: View {
    @State var draft: AutomationEditorDraft
    let context: AppContext
    let controller: AutomationsController
    let location: any LocationProviding
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(text: $draft.rule.name) { Text("Name", tableName: "Automations") }
                    Toggle(isOn: $draft.rule.isEnabled) { Text("On", tableName: "Automations") }
                }

                Section {
                    Picker(selection: $draft.rule.match) {
                        Text("All conditions hold", tableName: "Automations").tag(AutomationMatchMode.all)
                        Text("Any condition holds", tableName: "Automations").tag(AutomationMatchMode.any)
                    } label: {
                        Text("Active when", tableName: "Automations")
                    }
                    ForEach($draft.rule.conditions) { $condition in
                        AutomationConditionEditor(condition: $condition, draft: $draft, context: context,
                                                  controller: controller, location: location) {
                            draft.rule.conditions.removeAll { $0.id == condition.id }
                            draft.approvedScripts.remove(condition.id)
                        }
                    }
                    Menu {
                        ForEach(AutomationConditionChoice.allCases, id: \.self) { choice in
                            Button { addCondition(choice) } label: { Label(choice.title, systemImage: choice.symbol) }
                        }
                    } label: {
                        Text("Add Condition", tableName: "Automations")
                    }
                    .fixedSize()
                } header: {
                    Text("Conditions", tableName: "Automations")
                }

                Section {
                    ForEach(draft.rule.actions.showItems, id: \.self) { owner in
                        LabeledContent {
                            Button { draft.rule.actions.showItems.removeAll { $0 == owner } } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("Remove", tableName: "Automations"))
                        } label: {
                            AutomationOwnerLabel(owner: owner, context: context)
                        }
                    }
                    AutomationOwnerMenu(context: context, excluded: Set(draft.rule.actions.showItems)) { owner in
                        draft.rule.actions.showItems.append(owner)
                    }
                } header: {
                    Text("Show these items while active", tableName: "Automations")
                } footer: {
                    Text("They appear even when their section is hidden, and hide again by themselves when the automation ends.",
                         tableName: "Automations")
                }

                Section {
                    Picker(selection: profileSelection) {
                        Text("None", tableName: "Automations").tag(String?.none)
                        ForEach(context.services[.profiles].profiles) { profile in
                            Text(profile.name).tag(String?.some(profile.id))
                        }
                    } label: {
                        Text("Apply profile", tableName: "Automations")
                    }
                    if draft.rule.actions.profile != nil {
                        Toggle(isOn: Binding(get: { draft.rule.actions.profile?.restorePrevious ?? false },
                                             set: { draft.rule.actions.profile?.restorePrevious = $0 })) {
                            Text("Restore the previous profile when it ends", tableName: "Automations")
                            Text("Unless you switched profiles yourself in the meantime.", tableName: "Automations")
                        }
                    }
                    AutomationCommandPicker(title: String(localized: "Run command", table: "Automations"),
                                            call: $draft.rule.actions.commandOnStart, context: context)
                } header: {
                    Text("When it becomes active", tableName: "Automations")
                }

                Section {
                    AutomationCommandPicker(title: String(localized: "Run command", table: "Automations"),
                                            call: $draft.rule.actions.commandOnEnd, context: context)
                } header: {
                    Text("When it ends", tableName: "Automations")
                }

                if !draft.isNew {
                    Section {
                        let entries = controller.logs[draft.rule.id] ?? []
                        if entries.isEmpty {
                            Text("No changes since Rolltop started.", tableName: "Automations").foregroundStyle(.secondary)
                        }
                        ForEach(entries.reversed()) { entry in
                            LabeledContent {
                                Text(entry.date, style: .time).foregroundStyle(.secondary)
                            } label: {
                                Label {
                                    Text(AutomationEditorText.logTitle(entry))
                                } icon: {
                                    Image(systemName: AutomationEditorText.logSymbol(entry.kind))
                                        .foregroundStyle(entry.kind == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                                }
                            }
                        }
                    } header: {
                        Text("Recent changes", tableName: "Automations")
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                AutomationLiveState(rule: draft.rule, isNew: draft.isNew, controller: controller)
                Spacer()
                Button(role: .cancel) { onClose() } label: { Text("Cancel", tableName: "Automations") }
                    .keyboardShortcut(.cancelAction)
                Button { save() } label: {
                    draft.isNew ? Text("Add", tableName: "Automations") : Text("Done", tableName: "Automations")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.rule.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 560, idealWidth: 560, minHeight: 600, idealHeight: 680)
    }

    private var profileSelection: Binding<String?> {
        Binding(get: { draft.rule.actions.profile?.profileID },
                set: { id in
                    if let id {
                        let restore = draft.rule.actions.profile?.restorePrevious ?? true
                        draft.rule.actions.profile = AutomationProfileAction(profileID: id, restorePrevious: restore)
                    } else {
                        draft.rule.actions.profile = nil
                    }
                })
    }

    private func addCondition(_ choice: AutomationConditionChoice) {
        let condition = AutomationCondition(choice.makeDefault())
        draft.rule.conditions.append(condition)
        // The user is writing this script now: it may run.
        if case .script = condition.kind { draft.approvedScripts.insert(condition.id) }
    }

    private func save() {
        var rule = draft.rule
        rule.name = rule.name.trimmingCharacters(in: .whitespaces)
        let approved = draft.approvedScripts.intersection(rule.scriptConditions.map(\.id))
        if draft.isNew {
            controller.add(rule, approvingScripts: approved)
        } else {
            controller.update(rule, approvingScripts: approved)
        }
        onClose()
    }
}

/// "Would be active now" for the draft, so the user sees the effect of their edits.
private struct AutomationLiveState: View {
    let rule: AutomationRule
    let isNew: Bool
    let controller: AutomationsController

    var body: some View {
        let holds = AutomationEvaluator.evaluate(rule, in: controller.environment)
        HStack(spacing: 5) {
            Circle().fill(holds ? AnyShapeStyle(.green) : AnyShapeStyle(.quaternary)).frame(width: 8, height: 8)
            Text(holds ? String(localized: "Conditions hold now", table: "Automations")
                       : String(localized: "Conditions do not hold now", table: "Automations"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Conditions

enum AutomationConditionChoice: CaseIterable {
    case power, wifi, app, time, displays, place, script

    var title: String {
        switch self {
        case .power: String(localized: "Power", table: "Automations")
        case .wifi: String(localized: "Wi-Fi", table: "Automations")
        case .app: String(localized: "App", table: "Automations")
        case .time: String(localized: "Time", table: "Automations")
        case .displays: String(localized: "Displays", table: "Automations")
        case .place: String(localized: "Place", table: "Automations")
        case .script: String(localized: "Script", table: "Automations")
        }
    }

    var symbol: String {
        switch self {
        case .power: "battery.75percent"
        case .wifi: "wifi"
        case .app: "app"
        case .time: "clock"
        case .displays: "display.2"
        case .place: "mappin.and.ellipse"
        case .script: "terminal"
        }
    }

    func makeDefault() -> AutomationCondition.Kind {
        switch self {
        case .power: .power(.init(test: .onBattery))
        case .wifi: .wifi(.init(test: .notConnected))
        case .app: .app(.init(bundleID: "", test: .running))
        case .time: .time(.init(weekdays: AutomationTimeCondition.workdays, start: 9 * 60, end: 17 * 60))
        case .displays: .displays(.init(test: .externalConnected))
        case .place: .place(.init(test: .at, place: AutomationPlace()))
        case .script: .script(.init(command: ""))
        }
    }
}

private struct AutomationConditionEditor: View {
    @Binding var condition: AutomationCondition
    @Binding var draft: AutomationEditorDraft
    let context: AppContext
    let controller: AutomationsController
    let location: any LocationProviding
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: symbol).font(.headline)
                Spacer()
                if case .place = condition.kind, controller.placeHolds(condition) == nil {
                    Text("Location unknown", tableName: "Automations").font(.caption).foregroundStyle(.secondary)
                } else {
                    let holds = controller.conditionHolds(condition)
                    Text(holds ? String(localized: "Holds now", table: "Automations") : String(localized: "Does not hold", table: "Automations"))
                        .font(.caption)
                        .foregroundStyle(holds ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                }
                Button { onRemove() } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Remove condition", tableName: "Automations"))
            }
            content
        }
        .padding(.vertical, 2)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        switch condition.kind {
        case .power: AutomationConditionChoice.power.title
        case .wifi: AutomationConditionChoice.wifi.title
        case .app: AutomationConditionChoice.app.title
        case .time: AutomationConditionChoice.time.title
        case .displays: AutomationConditionChoice.displays.title
        case .script: AutomationConditionChoice.script.title
        case .place: AutomationConditionChoice.place.title
        case .itemChanged: String(localized: "Item changed", table: "Automations")
        case .unsupported(let type, _): type
        }
    }

    private var symbol: String {
        switch condition.kind {
        case .power: AutomationConditionChoice.power.symbol
        case .wifi: AutomationConditionChoice.wifi.symbol
        case .app: AutomationConditionChoice.app.symbol
        case .time: AutomationConditionChoice.time.symbol
        case .displays: AutomationConditionChoice.displays.symbol
        case .script: AutomationConditionChoice.script.symbol
        case .place: AutomationConditionChoice.place.symbol
        case .itemChanged, .unsupported: "questionmark.circle"
        }
    }

    @ViewBuilder private var content: some View {
        switch condition.kind {
        case .power(let power):
            powerEditor(power)
        case .wifi(let wifi):
            wifiEditor(wifi)
        case .app(let app):
            AutomationAppConditionEditor(app: app, context: context) { updated in
                condition.kind = .app(updated)
                if draft.linkAppToItems, !updated.bundleID.isEmpty {
                    draft.rule.actions.showItems = [.app(updated.bundleID)]
                }
            }
        case .time(let time):
            AutomationTimeEditor(time: time) { condition.kind = .time($0) }
        case .displays(let displays):
            displaysEditor(displays)
        case .script(let script):
            AutomationScriptEditor(script: script, conditionID: condition.id, controller: controller,
                                   approved: Binding(get: { draft.approvedScripts.contains(condition.id) },
                                                     set: { on in
                                                         if on { draft.approvedScripts.insert(condition.id) }
                                                         else { draft.approvedScripts.remove(condition.id) }
                                                     })) { condition.kind = .script($0) }
        case .place(let place):
            AutomationPlaceEditor(condition: place, location: location) { condition.kind = .place($0) }
        case .itemChanged, .unsupported:
            Text("This version of Rolltop does not support this condition; it never holds.", tableName: "Automations")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func powerEditor(_ power: AutomationPowerCondition) -> some View {
        HStack {
            Picker(selection: Binding(get: { power.test }, set: { var p = power; p.test = $0; condition.kind = .power(p) })) {
                Text("On battery power", tableName: "Automations").tag(AutomationPowerCondition.Test.onBattery)
                Text("On power adapter", tableName: "Automations").tag(AutomationPowerCondition.Test.onAC)
                Text("Charging", tableName: "Automations").tag(AutomationPowerCondition.Test.charging)
                Text("Not charging", tableName: "Automations").tag(AutomationPowerCondition.Test.notCharging)
                Text("Battery level below", tableName: "Automations").tag(AutomationPowerCondition.Test.levelBelow)
                Text("Battery level above", tableName: "Automations").tag(AutomationPowerCondition.Test.levelAbove)
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .fixedSize()
            if power.test == .levelBelow || power.test == .levelAbove {
                Text(Double(power.percent) / 100, format: .percent).monospacedDigit()
                Stepper(value: Binding(get: { power.percent }, set: { var p = power; p.percent = $0; condition.kind = .power(p) }),
                        in: 1...99, step: 5) {
                    Text("Battery level", tableName: "Automations")
                }
                .labelsHidden()
            }
            Spacer(minLength: 0)
        }
    }

    private func wifiEditor(_ wifi: AutomationWiFiCondition) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(selection: Binding(get: { wifi.test }, set: { var w = wifi; w.test = $0; condition.kind = .wifi(w) })) {
                Text("Connected", tableName: "Automations").tag(AutomationWiFiCondition.Test.connected)
                Text("Not connected", tableName: "Automations").tag(AutomationWiFiCondition.Test.notConnected)
                Text("Connected to one of these networks", tableName: "Automations").tag(AutomationWiFiCondition.Test.connectedTo)
            } label: {
                EmptyView()
            }
            .labelsHidden()
            if wifi.test == .connectedTo {
                AutomationNetworkNamesField(networks: wifi.networks) { names in
                    var w = wifi
                    w.networks = names
                    condition.kind = .wifi(w)
                }
                AutomationLocationRow(location: location)
            }
        }
    }

    private func displaysEditor(_ displays: AutomationDisplayCondition) -> some View {
        HStack {
            Picker(selection: Binding(get: { displays.test }, set: { var d = displays; d.test = $0; condition.kind = .displays(d) })) {
                Text("Only the built-in display", tableName: "Automations").tag(AutomationDisplayCondition.Test.builtInOnly)
                Text("An external display is connected", tableName: "Automations").tag(AutomationDisplayCondition.Test.externalConnected)
                Text("At least this many displays", tableName: "Automations").tag(AutomationDisplayCondition.Test.countAtLeast)
                Text("Exactly this many displays", tableName: "Automations").tag(AutomationDisplayCondition.Test.countExactly)
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .fixedSize()
            if displays.test == .countAtLeast || displays.test == .countExactly {
                Text(displays.count, format: .number).monospacedDigit()
                Stepper(value: Binding(get: { displays.count }, set: { var d = displays; d.count = $0; condition.kind = .displays(d) }),
                        in: 1...8) {
                    Text("Number of displays", tableName: "Automations")
                }
                .labelsHidden()
            }
            Spacer(minLength: 0)
        }
    }
}

/// Comma-separated network names. Keeps what the user types (a trailing comma or space)
/// and only parses it into the list.
private struct AutomationNetworkNamesField: View {
    let onChange: ([String]) -> Void
    @State private var text: String

    init(networks: [String], onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
        _text = State(initialValue: networks.joined(separator: ", "))
    }

    var body: some View {
        TextField(text: $text, prompt: Text("Office, Home", tableName: "Automations")) {
            Text("Network names", tableName: "Automations")
        }
        .onChange(of: text) { _, newValue in
            onChange(Self.parse(newValue))
        }
    }

    nonisolated static func parse(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

private struct AutomationAppConditionEditor: View {
    let app: AutomationAppCondition
    let context: AppContext
    let onChange: (AutomationAppCondition) -> Void

    var body: some View {
        HStack {
            Menu {
                let running = context.catalog.runningApps
                    .compactMap { record -> (String, String)? in
                        guard let id = record.bundleID, let name = record.name, id != Bundle.main.bundleIdentifier else { return nil }
                        return (id, name)
                    }
                    .reduce(into: [String: String]()) { $0[$1.0] = $1.1 }
                    .sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
                Section(String(localized: "Running apps", table: "Automations")) {
                    ForEach(running, id: \.key) { id, name in
                        Button { choose(id: id, name: name) } label: {
                            Label { Text(name) } icon: { AutomationAppIcon(bundleID: id) }
                        }
                        .labelStyle(.titleAndIcon)
                    }
                }
                Divider()
                Button { chooseFromDisk() } label: { Text("Choose…", tableName: "Automations") }
            } label: {
                if app.bundleID.isEmpty {
                    Text("Choose an app", tableName: "Automations")
                } else {
                    Label { Text(app.name ?? app.bundleID) } icon: { AutomationAppIcon(bundleID: app.bundleID) }
                        .labelStyle(.titleAndIcon)
                }
            }
            .fixedSize()
            Picker(selection: Binding(get: { app.test }, set: { var a = app; a.test = $0; onChange(a) })) {
                Text("is running", tableName: "Automations").tag(AutomationAppCondition.Test.running)
                Text("is not running", tableName: "Automations").tag(AutomationAppCondition.Test.notRunning)
                Text("is frontmost", tableName: "Automations").tag(AutomationAppCondition.Test.frontmost)
                Text("is not frontmost", tableName: "Automations").tag(AutomationAppCondition.Test.notFrontmost)
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private func choose(id: String, name: String?) {
        var updated = app
        updated.bundleID = id
        updated.name = name
        onChange(updated)
    }

    /// An open panel in /Applications (the user's click; no folder outside it is read).
    private func chooseFromDisk() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            choose(id: id, name: name)
        }
    }
}

private struct AutomationAppIcon: View {
    let bundleID: String

    var body: some View {
        if let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map({ NSWorkspace.shared.icon(forFile: $0.path) }) {
            Image(nsImage: image).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: "app")
        }
    }
}

private struct AutomationTimeEditor: View {
    let time: AutomationTimeCondition
    let onChange: (AutomationTimeCondition) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                let symbols = Calendar.current.veryShortWeekdaySymbols
                ForEach(AutomationWeekdays.ordered, id: \.self) { day in
                    let on = time.weekdays.contains(day)
                    Button {
                        var t = time
                        if on { t.weekdays.removeAll { $0 == day } } else { t.weekdays = (t.weekdays + [day]).sorted() }
                        onChange(t)
                    } label: {
                        Text(symbols[day - 1])
                            .frame(width: 24, height: 22)
                            .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(Calendar.current.weekdaySymbols[day - 1]))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            HStack(spacing: 8) {
                Text("From", tableName: "Automations")
                DatePicker(selection: minutesBinding(\.start), displayedComponents: .hourAndMinute) {
                    Text("From", tableName: "Automations")
                }
                .labelsHidden()
                .fixedSize()
                Text("to", tableName: "Automations")
                DatePicker(selection: minutesBinding(\.end), displayedComponents: .hourAndMinute) {
                    Text("to", tableName: "Automations")
                }
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
            }
            if time.end < time.start {
                Text("Ends the next day.", tableName: "Automations").font(.caption).foregroundStyle(.secondary)
            } else if time.end == time.start {
                Text("All day.", tableName: "Automations").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func minutesBinding(_ keyPath: WritableKeyPath<AutomationTimeCondition, Int>) -> Binding<Date> {
        Binding(get: {
            let minutes = time[keyPath: keyPath]
            return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            var t = time
            t[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            onChange(t)
        })
    }
}

private struct AutomationScriptEditor: View {
    let script: AutomationScriptCondition
    let conditionID: String
    let controller: AutomationsController
    @Binding var approved: Bool
    let onChange: (AutomationScriptCondition) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(text: Binding(get: { script.command }, set: { var s = script; s.command = $0; onChange(s) }),
                      prompt: Text("test -e ~/Library/Caches/flag", tableName: "Automations"), axis: .vertical) {
                Text("Command", tableName: "Automations")
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(.body.monospaced())
            .lineLimit(2...5)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text("Every \(script.effectiveInterval) s", tableName: "Automations").monospacedDigit()
                Stepper(value: Binding(get: { script.effectiveInterval }, set: { var s = script; s.interval = $0; onChange(s) }),
                        in: AutomationScriptCondition.minimumInterval...3600, step: 5) {
                    Text("Interval", tableName: "Automations")
                }
                .labelsHidden()
                Text("Time limit \(script.effectiveTimeout) s", tableName: "Automations").monospacedDigit()
                    .padding(.leading, 12)
                Stepper(value: Binding(get: { script.effectiveTimeout }, set: { var s = script; s.timeout = $0; onChange(s) }),
                        in: 1...AutomationScriptCondition.maximumTimeout) {
                    Text("Time limit", tableName: "Automations")
                }
                .labelsHidden()
                Spacer(minLength: 0)
            }
            Toggle(isOn: $approved) {
                Text("Allow Rolltop to run this command", tableName: "Automations")
                Text("Runs with /bin/sh and a minimal environment. It holds while the command exits with 0. Commands from an import never run until you allow them.",
                     tableName: "Automations")
            }
            if let outcome = controller.environment.scripts[conditionID] {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AutomationEditorText.outcome(outcome)).font(.caption).foregroundStyle(.secondary)
                    if !outcome.output.isEmpty {
                        Text(outcome.output)
                            .font(.caption.monospaced())
                            .lineLimit(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            } else if !approved {
                Text("Not run until you allow it.", tableName: "Automations").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// "At" / "away from", the place's name, coordinates, radius and "Use current location".
/// Location is asked for only by this editor's buttons (a click), never by evaluation.
private struct AutomationPlaceEditor: View {
    let condition: AutomationPlaceCondition
    let location: any LocationProviding
    let onChange: (AutomationPlaceCondition) -> Void

    @State private var latitudeText: String
    @State private var longitudeText: String
    @State private var isLocating = false
    @State private var locateError: String?

    init(condition: AutomationPlaceCondition, location: any LocationProviding,
         onChange: @escaping (AutomationPlaceCondition) -> Void) {
        self.condition = condition
        self.location = location
        self.onChange = onChange
        _latitudeText = State(initialValue: condition.place.latitude.map(AutomationPlaceDecision.format) ?? "")
        _longitudeText = State(initialValue: condition.place.longitude.map(AutomationPlaceDecision.format) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(selection: Binding(get: { condition.test }, set: { var c = condition; c.test = $0; onChange(c) })) {
                Text("At this place", tableName: "Automations").tag(AutomationPlaceCondition.Test.at)
                Text("Away from this place", tableName: "Automations").tag(AutomationPlaceCondition.Test.awayFrom)
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .fixedSize()
            TextField(text: Binding(get: { condition.place.name }, set: { var c = condition; c.place.name = $0; onChange(c) }),
                      prompt: Text("Office", tableName: "Automations")) {
                Text("Place name", tableName: "Automations")
            }
            HStack {
                TextField(text: $latitudeText, prompt: Text(verbatim: "51.4779")) { Text("Latitude", tableName: "Automations") }
                TextField(text: $longitudeText, prompt: Text(verbatim: "-0.0015")) { Text("Longitude", tableName: "Automations") }
            }
            .onChange(of: latitudeText) { commitCoordinates() }
            .onChange(of: longitudeText) { commitCoordinates() }
            if !coordinatesValid {
                Text("Enter a latitude from −90 to 90 and a longitude from −180 to 180.", tableName: "Automations")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Text("Radius", tableName: "Automations")
                Slider(value: Binding(get: { condition.place.effectiveRadius },
                                      set: { var c = condition; c.place.radius = $0.rounded(); onChange(c) }),
                       in: AutomationPlace.radiusRange, step: 50) {
                    Text("Radius", tableName: "Automations")
                }
                .labelsHidden()
                Text(Measurement(value: condition.place.effectiveRadius, unit: UnitLength.meters),
                     format: .measurement(width: .abbreviated, usage: .asProvided))
                    .monospacedDigit()
                    .frame(minWidth: 64, alignment: .trailing)
            }
            HStack {
                Button { useCurrentLocation() } label: { Text("Use Current Location", tableName: "Automations") }
                    .disabled(isLocating)
                if isLocating { ProgressView().controlSize(.small) }
                if let locateError { Text(locateError).font(.caption).foregroundStyle(.secondary) }
            }
            AutomationLocationRow(location: location, purpose: .places)
            Text("Places are saved with your automations, so they are included in exports and backups.", tableName: "Automations")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var coordinatesValid: Bool {
        (latitudeText.isEmpty && longitudeText.isEmpty)
            || (AutomationPlaceDecision.parseCoordinate(latitudeText, limit: 90) != nil
                && AutomationPlaceDecision.parseCoordinate(longitudeText, limit: 180) != nil)
    }

    /// Stores both coordinates only when both are valid; clears them when both are empty.
    private func commitCoordinates() {
        let latitude = AutomationPlaceDecision.parseCoordinate(latitudeText, limit: 90)
        let longitude = AutomationPlaceDecision.parseCoordinate(longitudeText, limit: 180)
        var c = condition
        if let latitude, let longitude {
            c.place.latitude = latitude
            c.place.longitude = longitude
        } else if latitudeText.isEmpty, longitudeText.isEmpty {
            c.place.latitude = nil
            c.place.longitude = nil
        } else {
            return
        }
        if c != condition { onChange(c) }
    }

    /// The user's click: one fix when allowed; otherwise asks (not determined) or opens
    /// System Settings (refused).
    private func useCurrentLocation() {
        location.activate()
        locateError = nil
        switch location.authorization {
        case .notDetermined:
            location.requestAuthorization()
        case .denied, .restricted:
            NSWorkspace.shared.open(LocationAccess.settingsURL)
        case .authorized:
            isLocating = true
            Task {
                defer { isLocating = false }
                do {
                    let fix = try await location.currentLocation()
                    latitudeText = AutomationPlaceDecision.format(fix.coordinate.latitude)
                    longitudeText = AutomationPlaceDecision.format(fix.coordinate.longitude)
                } catch {
                    locateError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Owners and commands

struct AutomationOwnerLabel: View {
    let owner: OwnerID
    let context: AppContext

    var body: some View {
        Label {
            Text(AutomationEditorText.displayName(of: owner, context: context))
        } icon: {
            if let image = context.services[.itemImages].image(for: owner, itemIndex: 0, height: 16) {
                // Exactly 16 pt tall at its own width (ItemImageProviding).
                Image(nsImage: image).renderingMode(image.isTemplate ? .template : .original)
            } else {
                Image(systemName: "questionmark.square.dashed")
            }
        }
        .labelStyle(.titleAndIcon)
    }
}

/// "Add item" menu over the catalog's assignable entries (with their images) plus the
/// system modules that are not in the bar right now.
private struct AutomationOwnerMenu: View {
    let context: AppContext
    let excluded: Set<OwnerID>
    let onPick: (OwnerID) -> Void

    var body: some View {
        Menu {
            let entries = context.catalog.entries.filter { $0.owner != nil && !$0.isOwn && !excluded.contains($0.owner!) }
            Section(String(localized: "In the menu bar", table: "Automations")) {
                ForEach(entries) { entry in
                    Button { onPick(entry.owner!) } label: { AutomationOwnerLabel(owner: entry.owner!, context: context) }
                }
            }
            let present = Set(entries.compactMap(\.owner))
            let modules = SystemModule.allCases.filter(\.isVerified).map(OwnerID.system)
                .filter { !present.contains($0) && !excluded.contains($0) }
            if !modules.isEmpty {
                Section(String(localized: "System items", table: "Automations")) {
                    ForEach(modules, id: \.self) { owner in
                        Button { onPick(owner) } label: { AutomationOwnerLabel(owner: owner, context: context) }
                    }
                }
            }
        } label: {
            Text("Add Item", tableName: "Automations")
        }
        .fixedSize()
    }
}

private struct AutomationCommandPicker: View {
    let title: String
    @Binding var call: AutomationCommandCall?
    let context: AppContext

    var body: some View {
        let commands = context.commands.commands
            // Rules run commands with source `.automation`, which never runs destructive
            // commands (rules can arrive through an import): offer only the others.
            .filter { !$0.id.isDebugOnly && !$0.id.rawValue.hasPrefix("profiles.apply-")
                && CommandEffectPolicy.allows($0.resolvedEffect, from: .automation) }
            .sorted { $0.localizedTitle.localizedStandardCompare($1.localizedTitle) == .orderedAscending }
        Picker(selection: Binding(get: { call?.id }, set: { id in call = id.map { AutomationCommandCall(id: $0) } })) {
            Text("None", tableName: "Automations").tag(CommandID?.none)
            ForEach(commands, id: \.id) { command in
                Text(command.localizedTitle).tag(CommandID?.some(command.id))
            }
        } label: {
            Text(title)
        }
        if let current = call, let command = context.commands.command(current.id) {
            ForEach(command.arguments, id: \.name) { argument in
                let value = Binding(get: { call?.arguments[argument.name] ?? "" },
                                    set: { call?.arguments[argument.name] = $0.isEmpty ? nil : $0 })
                if let allowed = argument.allowedValues {
                    Picker(selection: value) {
                        Text("Choose", tableName: "Automations").tag("")
                        ForEach(allowed, id: \.self) { Text($0).tag($0) }
                    } label: {
                        Text(String(localized: argument.title)).padding(.leading, 12)
                    }
                } else {
                    TextField(text: value) { Text(String(localized: argument.title)).padding(.leading, 12) }
                }
            }
        }
    }
}

enum AutomationEditorText {
    static func outcome(_ outcome: AutomationScriptOutcome) -> String {
        let time = outcome.finishedAt.formatted(date: .omitted, time: .standard)
        if let error = outcome.launchError { return String(localized: "Last run \(time): could not start (\(error))", table: "Automations") }
        if outcome.timedOut { return String(localized: "Last run \(time): stopped after the time limit, does not hold", table: "Automations") }
        let status = outcome.exitStatus.map(String.init) ?? "?"
        return outcome.succeeded
            ? String(localized: "Last run \(time): exit status \(status), holds", table: "Automations")
            : String(localized: "Last run \(time): exit status \(status), does not hold", table: "Automations")
    }

    static func logTitle(_ entry: AutomationLogEntry) -> String {
        switch entry.kind {
        case .activated: String(localized: "Became active", table: "Automations")
        case .deactivated: String(localized: "Ended", table: "Automations")
        case .note, .error: entry.message ?? ""
        }
    }

    static func logSymbol(_ kind: AutomationLogEntry.Kind) -> String {
        switch kind {
        case .activated: "play.circle"
        case .deactivated: "stop.circle"
        case .note: "info.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    /// The catalog's fixed name (system modules never carry live state there).
    static func displayName(of owner: OwnerID, context: AppContext) -> String {
        context.catalog.displayName(for: owner)
    }
}
