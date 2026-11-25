import AppKit
import RolltopCore
import SwiftUI

/// Settings pane "Automations": rules with on/off switches and a live "active" indicator,
/// templates, timing, Location state for Wi-Fi names, and the rule editor sheet.
struct AutomationsSettingsView: View {
    let context: AppContext
    let controller: AutomationsController
    let location: any LocationProviding
    var initialEditingID: String?

    @State private var editing: AutomationEditorDraft?
    @State private var deleting: AutomationRule?
    @State private var didOpenInitialEditor = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { controller.isPaused }, set: { controller.setPaused($0) })) {
                    Text("Pause all automations", tableName: "Automations")
                    Text("While paused, no automation is active: the items they show hide again, and the profiles they applied are undone where “Restore the previous profile when it ends” is on.",
                         tableName: "Automations")
                }
            }

            Section {
                if controller.rules.isEmpty {
                    Text("No automations yet. Start from a template or from scratch.", tableName: "Automations")
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.rules) { rule in
                    AutomationRuleRow(rule: rule, context: context, controller: controller,
                                      onEdit: { editing = AutomationEditorDraft(rule: rule, controller: controller) },
                                      onDelete: { deleting = rule })
                }
                .onMove { controller.move(fromOffsets: $0, toOffset: $1) }
                Menu {
                    Button { startNew(AutomationRule(name: String(localized: "New automation", table: "Automations"))) } label: {
                        Text("Blank Automation", tableName: "Automations")
                    }
                    Divider()
                    ForEach(AutomationTemplate.allCases, id: \.self) { template in
                        Button { startNew(template.makeRule(name: AutomationText.title(of: template)), linkApp: template == .appFrontmost) } label: {
                            Text(AutomationText.title(of: template))
                        }
                    }
                } label: {
                    Text("Add Automation", tableName: "Automations")
                }
                .fixedSize()
            } header: {
                Text("Your automations", tableName: "Automations")
            } footer: {
                Text("An automation is active while its conditions hold. Items it shows hide again by themselves when it ends.",
                     tableName: "Automations")
            }

            Section {
                Picker(selection: Binding(get: { controller.stability }, set: { controller.setStability($0) })) {
                    ForEach(AutomationsSettings.stabilityChoices, id: \.self) { seconds in
                        Text(AutomationText.seconds(seconds)).tag(seconds)
                    }
                } label: {
                    Text("Wait before switching", tableName: "Automations")
                    Text("Conditions must hold this long before an automation switches, so a flapping connection does not make items flicker.",
                         tableName: "Automations")
                }
            } header: {
                Text("Timing", tableName: "Automations")
            }

            if controller.usesNetworkNames {
                Section {
                    AutomationLocationRow(location: location)
                } header: {
                    Text("Wi-Fi network names", tableName: "Automations")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { draft in
            AutomationRuleEditor(draft: draft, context: context, controller: controller, location: location) { editing = nil }
        }
        .alert(Text("Delete “\(deleting?.name ?? "")”?", tableName: "Automations"),
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { rule in
            Button(role: .destructive) { controller.delete(id: rule.id) } label: { Text("Delete", tableName: "Automations") }
            Button(role: .cancel) {} label: { Text("Cancel", tableName: "Automations") }
        } message: { _ in
            Text("If the automation is active, it ends first.", tableName: "Automations")
        }
        .onAppear {
            guard !didOpenInitialEditor else { return }
            didOpenInitialEditor = true
            if let id = initialEditingID {
                if let template = AutomationTemplate(rawValue: id) {
                    startNew(template.makeRule(name: AutomationText.title(of: template)), linkApp: template == .appFrontmost)
                } else if let rule = controller.rule(id: id) {
                    editing = AutomationEditorDraft(rule: rule, controller: controller)
                }
            }
        }
    }

    private func startNew(_ rule: AutomationRule, linkApp: Bool = false) {
        var draft = AutomationEditorDraft(rule: rule, controller: controller)
        draft.isNew = true
        draft.linkAppToItems = linkApp
        editing = draft
    }
}

// MARK: - Row

private struct AutomationRuleRow: View {
    let rule: AutomationRule
    let context: AppContext
    let controller: AutomationsController
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { rule.isEnabled }, set: { controller.setEnabled($0, id: rule.id) })) {
                Text(rule.name)
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name.isEmpty ? String(localized: "Untitled", table: "Automations") : rule.name)
                Text(AutomationText.summary(of: rule, context: context))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            AutomationStatusBadge(rule: rule, controller: controller)
            Menu {
                Button { onEdit() } label: { Text("Edit…", tableName: "Automations") }
                Button { controller.duplicate(id: rule.id) } label: { Text("Duplicate", tableName: "Automations") }
                Divider()
                Button(role: .destructive) { onDelete() } label: { Text("Delete…", tableName: "Automations") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("More", tableName: "Automations"))
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onEdit() }
    }
}

private struct AutomationStatusBadge: View {
    let rule: AutomationRule
    let controller: AutomationsController

    var body: some View {
        let active = controller.isActive(rule.id)
        let pending = controller.isPending(rule.id)
        let since = controller.logs[rule.id]?.last { $0.kind == .activated || $0.kind == .deactivated }?.date
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 5) {
                Circle()
                    .fill(active ? AnyShapeStyle(.green) : AnyShapeStyle(.quaternary))
                    .frame(width: 8, height: 8)
                Text(status(active: active, pending: pending))
                    .font(.caption)
                    .foregroundStyle(active ? .primary : .secondary)
            }
            if let since, rule.isEnabled {
                Text(since, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func status(active: Bool, pending: Bool) -> String {
        if !rule.isEnabled { return String(localized: "Off", table: "Automations") }
        if controller.isPaused { return String(localized: "Paused", table: "Automations") }
        if pending { return String(localized: "Switching…", table: "Automations") }
        if !active, controller.hasUnknownPlace(rule) { return String(localized: "Location unknown", table: "Automations") }
        return active ? String(localized: "Active now", table: "Automations") : String(localized: "Inactive", table: "Automations")
    }
}

// MARK: - Location

struct AutomationLocationRow: View {
    enum Purpose { case networkNames, places }

    let location: any LocationProviding
    var purpose: Purpose = .networkNames

    var body: some View {
        LabeledContent {
            switch location.authorization {
            case .authorized:
                Text("Allowed", tableName: "Automations").foregroundStyle(.secondary)
            case .notDetermined:
                // The only place Rolltop asks for Location: the user's click.
                Button { location.requestAuthorization() } label: { Text("Allow…", tableName: "Automations") }
            case .denied, .restricted:
                Button { NSWorkspace.shared.open(LocationAccess.settingsURL) } label: {
                    Text("Open System Settings", tableName: "Automations")
                }
            }
        } label: {
            Text("Location access", tableName: "Automations")
            Text(caption)
        }
        .onAppear { location.activate() }
    }

    private var caption: String {
        if purpose == .places {
            return switch location.authorization {
            case .authorized:
                String(localized: "Rolltop can tell whether this Mac is at your places.", table: "Automations")
            case .notDetermined:
                String(localized: "Place conditions need Location access. Until you allow it, the location is unknown and they don’t hold.",
                       table: "Automations")
            case .denied, .restricted:
                String(localized: "Location access is off for Rolltop, so the location is unknown and place conditions don’t hold.",
                       table: "Automations")
            }
        }
        return switch location.authorization {
        case .authorized:
            String(localized: "Rolltop can read the name of the current Wi-Fi network.", table: "Automations")
        case .notDetermined:
            String(localized: "macOS shows network names only to apps with Location access. Until then, “connected to” conditions count as not holding.",
                   table: "Automations")
        case .denied, .restricted:
            String(localized: "Location access is off for Rolltop, so “connected to” conditions count as not holding.", table: "Automations")
        }
    }
}

// MARK: - Text

enum AutomationText {
    static func title(of template: AutomationTemplate) -> String {
        switch template {
        case .batteryOnBattery: String(localized: "Show battery when on battery power", table: "Automations")
        case .wifiNotConnected: String(localized: "Show Wi-Fi when not connected", table: "Automations")
        case .appFrontmost: String(localized: "Show an app’s item while it is frontmost", table: "Automations")
        }
    }

    static func seconds(_ value: Double) -> String {
        value < 1 ? String(localized: "\(value.formatted()) seconds", table: "Automations")
            : String(localized: "\(Int(value)) seconds", table: "Automations")
    }

    static func summary(of rule: AutomationRule, context: AppContext) -> String {
        let conditions = rule.conditions.isEmpty
            ? String(localized: "No conditions", table: "Automations")
            : rule.conditions.map { describe($0.kind) }.formatted(.list(type: rule.match == .all ? .and : .or))
        var actions: [String] = []
        if !rule.actions.showItems.isEmpty {
            let names = rule.actions.showItems.map { AutomationEditorText.displayName(of: $0, context: context) }
            actions.append(String(localized: "show \(names.formatted(.list(type: .and)))", table: "Automations"))
        }
        if let profile = rule.actions.profile {
            let name = context.services[.profiles].profiles.first { $0.id == profile.profileID }?.name ?? profile.profileID
            actions.append(String(localized: "apply “\(name)”", table: "Automations"))
        }
        if rule.actions.commandOnStart != nil || rule.actions.commandOnEnd != nil {
            actions.append(String(localized: "run a command", table: "Automations"))
        }
        let does = actions.isEmpty ? String(localized: "does nothing yet", table: "Automations") : actions.formatted(.list(type: .and))
        return "\(conditions) → \(does)"
    }

    static func describe(_ kind: AutomationCondition.Kind) -> String {
        switch kind {
        case .power(let power):
            switch power.test {
            case .onBattery: return String(localized: "on battery power", table: "Automations")
            case .onAC: return String(localized: "on power adapter", table: "Automations")
            case .charging: return String(localized: "charging", table: "Automations")
            case .notCharging: return String(localized: "not charging", table: "Automations")
            case .levelBelow: return String(localized: "battery below \(power.percent)%", table: "Automations")
            case .levelAbove: return String(localized: "battery above \(power.percent)%", table: "Automations")
            }
        case .wifi(let wifi):
            switch wifi.test {
            case .connected: return String(localized: "Wi-Fi connected", table: "Automations")
            case .notConnected: return String(localized: "Wi-Fi not connected", table: "Automations")
            case .connectedTo: return String(localized: "on \(wifi.networks.formatted(.list(type: .or)))", table: "Automations")
            }
        case .app(let app):
            let name = app.name ?? (app.bundleID.isEmpty ? String(localized: "an app", table: "Automations") : app.bundleID)
            switch app.test {
            case .running: return String(localized: "\(name) is running", table: "Automations")
            case .notRunning: return String(localized: "\(name) is not running", table: "Automations")
            case .frontmost: return String(localized: "\(name) is frontmost", table: "Automations")
            case .notFrontmost: return String(localized: "\(name) is not frontmost", table: "Automations")
            }
        case .time(let time):
            return String(localized: "\(weekdays(time.weekdays)) \(clock(time.start))–\(clock(time.end))", table: "Automations")
        case .displays(let displays):
            switch displays.test {
            case .builtInOnly: return String(localized: "built-in display only", table: "Automations")
            case .externalConnected: return String(localized: "external display connected", table: "Automations")
            case .countAtLeast: return String(localized: "at least \(displays.count) displays", table: "Automations")
            case .countExactly: return String(localized: "exactly \(displays.count) displays", table: "Automations")
            }
        case .script: return String(localized: "script succeeds", table: "Automations")
        case .place(let place):
            // The name only, never the coordinates.
            let name = place.place.name.isEmpty ? String(localized: "a place", table: "Automations") : place.place.name
            switch place.test {
            case .at: return String(localized: "at \(name)", table: "Automations")
            case .awayFrom: return String(localized: "away from \(name)", table: "Automations")
            }
        case .itemChanged: return String(localized: "an item changed", table: "Automations")
        case .unsupported: return String(localized: "unsupported condition", table: "Automations")
        }
    }

    static func clock(_ minutes: Int) -> String {
        let date = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func weekdays(_ days: [Int]) -> String {
        let set = Set(days)
        if set.count == 7 { return String(localized: "Every day", table: "Automations") }
        if set == Set(AutomationTimeCondition.workdays) { return String(localized: "Weekdays", table: "Automations") }
        if set == [1, 7] { return String(localized: "Weekends", table: "Automations") }
        if set.isEmpty { return String(localized: "No days", table: "Automations") }
        let symbols = Calendar.current.shortWeekdaySymbols
        return AutomationWeekdays.ordered.filter(set.contains).map { symbols[$0 - 1] }.joined(separator: " ")
    }
}

enum AutomationWeekdays {
    /// Weekday numbers in the user's week order.
    static var ordered: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }
}
