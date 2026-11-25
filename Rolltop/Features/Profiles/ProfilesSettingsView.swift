import AppKit
import RolltopCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings pane "Profiles": the list with apply/edit/duplicate/delete/reorder, saving the
/// current setup, import/export, the active profile's changes, and switching options.
struct ProfilesSettingsView: View {
    let context: AppContext
    let controller: ProfilesController
    var initialEditingID: String?

    @State private var editing: RolltopProfile?
    @State private var deleting: RolltopProfile?
    @State private var savingNew = false
    @State private var errorMessage: String?
    @State private var didOpenInitialEditor = false

    var body: some View {
        Form {
            Section {
                if controller.all.isEmpty {
                    Text("No profiles yet. Arrange the menu bar the way you want it, then save it as a profile.", tableName: "Profiles")
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.all) { profile in
                    ProfileRow(profile: profile, controller: controller,
                               isFirst: profile.id == controller.all.first?.id, isLast: profile.id == controller.all.last?.id,
                               onEdit: { editing = profile }, onExport: { export(profile) }, onDelete: { deleting = profile })
                }
                .onMove { controller.move(fromOffsets: $0, toOffset: $1) }
                HStack {
                    Button { savingNew = true } label: { Text("Save Current Setup…", tableName: "Profiles") }
                    Button { importProfile() } label: { Text("Import…", tableName: "Profiles") }
                }
            } header: {
                Text("Saved profiles", tableName: "Profiles")
            } footer: {
                Text("A profile remembers which section every item is in. Apply one here, from Rolltop’s menu, with a shortcut or from an automation.",
                     tableName: "Profiles")
            }

            if let active = controller.activeProfile, controller.isActiveModified {
                Section {
                    LabeledContent {
                        HStack {
                            Button { controller.revertActive() } label: { Text("Revert", tableName: "Profiles") }
                            Button { controller.updateFromCurrent(id: active.id) } label: { Text("Update Profile", tableName: "Profiles") }
                        }
                    } label: {
                        Text("“\(active.name)” has changes", tableName: "Profiles")
                        Text("The menu bar changed since this profile was applied. Update the profile to keep the changes, or revert to it.",
                             tableName: "Profiles")
                    }
                } header: {
                    Text("Active profile", tableName: "Profiles")
                }
            }

            Section {
                Toggle(isOn: Binding(get: { context.settings[ProfilesSettings.showInStatusMenu] },
                                     set: { context.settings[ProfilesSettings.showInStatusMenu] = $0 })) {
                    Text("Show profiles in Rolltop’s menu", tableName: "Profiles")
                    Text("The first five profiles appear in Rolltop’s menu.", tableName: "Profiles")
                }
                LabeledContent {
                    Text(ProfileDisplayWatcher.current().displays.map(\.name).formatted(.list(type: .and)))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                } label: {
                    Text("Displays connected now", tableName: "Profiles")
                    Text("A profile with a display rule is applied when the connected displays change to match it. When none matches, nothing changes.",
                         tableName: "Profiles")
                }
            } header: {
                Text("Switching", tableName: "Profiles")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { profile in
            ProfileEditorSheet(draft: profile, controller: controller) { editing = nil }
        }
        .sheet(isPresented: $savingNew) {
            ProfileSaveSheet(controller: controller) { savingNew = false }
        }
        .alert(Text("Delete “\(deleting?.name ?? "")”?", tableName: "Profiles"),
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { profile in
            Button(role: .destructive) { controller.delete(id: profile.id) } label: { Text("Delete", tableName: "Profiles") }
            Button(role: .cancel) {} label: { Text("Cancel", tableName: "Profiles") }
        } message: { _ in
            Text("The menu bar stays as it is. This can’t be undone.", tableName: "Profiles")
        }
        .alert(Text("Could not import the profile", tableName: "Profiles"),
               isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(role: .cancel) {} label: { Text("OK", tableName: "Profiles") }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            guard !didOpenInitialEditor else { return }
            didOpenInitialEditor = true
            if let id = initialEditingID { editing = controller.profile(id: id) }
        }
    }

    private func export(_ profile: RolltopProfile) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(profile.name).json"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try controller.exportData(id: profile.id).write(to: url, options: .atomic)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try controller.importData(Data(contentsOf: url))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Row

private struct ProfileRow: View {
    let profile: RolltopProfile
    let controller: ProfilesController
    let isFirst: Bool
    let isLast: Bool
    let onEdit: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let isActive = controller.activeProfileID == profile.id
        let isModified = isActive && controller.isActiveModified
        HStack(spacing: 10) {
            Image(systemName: profile.symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name)
                    if isActive {
                        Text(isModified ? String(localized: "Active, changed", table: "Profiles") : String(localized: "Active", table: "Profiles"))
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                }
                Text(ProfileDescriptions.summary(of: profile))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button { try? controller.applyProfile(id: profile.id, reason: .user) } label: { Text("Apply", tableName: "Profiles") }
                .disabled(isActive && !isModified)
            Menu {
                Button { onEdit() } label: { Text("Edit…", tableName: "Profiles") }
                Button { controller.duplicate(id: profile.id) } label: { Text("Duplicate", tableName: "Profiles") }
                Divider()
                Button { controller.move(id: profile.id, by: -1) } label: { Text("Move Up", tableName: "Profiles") }.disabled(isFirst)
                Button { controller.move(id: profile.id, by: 1) } label: { Text("Move Down", tableName: "Profiles") }.disabled(isLast)
                Divider()
                Button { onExport() } label: { Text("Export…", tableName: "Profiles") }
                Divider()
                Button(role: .destructive) { onDelete() } label: { Text("Delete…", tableName: "Profiles") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("More", tableName: "Profiles"))
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onEdit() }
    }
}

/// Short descriptions for rows and captions.
enum ProfileDescriptions {
    static func summary(of profile: RolltopProfile) -> String {
        var parts: [String] = []
        let hidden = profile.layout.explicitOwners(in: .hidden).count
        let alwaysHidden = profile.layout.explicitOwners(in: .alwaysHidden).count
        parts.append(String(localized: "\(hidden) hidden, \(alwaysHidden) always hidden", table: "Profiles"))
        if profile.layout.defaultSection != .shown {
            parts.append(String(localized: "new items \(sectionName(profile.layout.defaultSection))", table: "Profiles"))
        }
        if profile.includes(.appearance) { parts.append(String(localized: "appearance", table: "Profiles")) }
        if profile.includes(.secondaryBar) { parts.append(String(localized: "Rolltop Bar", table: "Profiles")) }
        if profile.applyAtLaunch { parts.append(String(localized: "at launch", table: "Profiles")) }
        if let rule = profile.displayRule { parts.append(displayRuleSummary(rule)) }
        return parts.joined(separator: " · ")
    }

    static func sectionName(_ section: RolltopCore.Section) -> String {
        switch section {
        case .shown: String(localized: "shown", table: "Profiles")
        case .hidden: String(localized: "hidden", table: "Profiles")
        case .alwaysHidden: String(localized: "always hidden", table: "Profiles")
        }
    }

    static func displayRuleSummary(_ rule: ProfileDisplayRule) -> String {
        switch rule {
        case .builtInOnly: String(localized: "with the built-in display only", table: "Profiles")
        case .externalConnected: String(localized: "with an external display", table: "Profiles")
        case .displays(let displays):
            String(localized: "with \(displays.map(\.name).joined(separator: " + "))", table: "Profiles")
        }
    }
}

// MARK: - Save sheet

private struct ProfileSaveSheet: View {
    let controller: ProfilesController
    let onClose: () -> Void
    @State private var name = ""
    @State private var symbol = RolltopProfile.defaultSymbol

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(text: $name, prompt: Text("Work", tableName: "Profiles")) { Text("Name", tableName: "Profiles") }
                    ProfileSymbolPicker(symbol: $symbol)
                } footer: {
                    Text("Saves which section every item is in. You can include appearance and Rolltop Bar settings afterward.",
                         tableName: "Profiles")
                }
            }
            .formStyle(.grouped)
            ProfileSheetButtons(doneTitle: String(localized: "Save", table: "Profiles"),
                                canFinish: !name.trimmingCharacters(in: .whitespaces).isEmpty,
                                onCancel: onClose) {
                controller.saveCurrent(name: name, symbol: symbol)
                onClose()
            }
        }
        .frame(width: 440, height: 360)
    }
}

// MARK: - Editor sheet

struct ProfileEditorSheet: View {
    @State var draft: RolltopProfile
    let controller: ProfilesController
    let onClose: () -> Void

    private enum DisplayChoice: Hashable { case none, builtInOnly, externalConnected, displays }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(text: $draft.name) { Text("Name", tableName: "Profiles") }
                    ProfileSymbolPicker(symbol: $draft.symbol)
                }
                Section {
                    Toggle(isOn: included(.appearance)) {
                        Text("Include menu bar appearance", tableName: "Profiles")
                    }
                    Toggle(isOn: included(.secondaryBar)) {
                        Text("Include Rolltop Bar settings", tableName: "Profiles")
                    }
                } header: {
                    Text("Also applies", tableName: "Profiles")
                } footer: {
                    Text("Turning one on stores the current settings with this profile. Applying the profile puts them back.",
                         tableName: "Profiles")
                }
                Section {
                    Toggle(isOn: $draft.applyAtLaunch) {
                        Text("Apply at launch", tableName: "Profiles")
                        Text("Only one profile can do this. A profile whose display rule matches at launch takes precedence.",
                             tableName: "Profiles")
                    }
                    Picker(selection: displayChoice) {
                        Text("Never", tableName: "Profiles").tag(DisplayChoice.none)
                        Text("Only the built-in display is connected", tableName: "Profiles").tag(DisplayChoice.builtInOnly)
                        Text("An external display is connected", tableName: "Profiles").tag(DisplayChoice.externalConnected)
                        Text("These displays are connected", tableName: "Profiles").tag(DisplayChoice.displays)
                    } label: {
                        Text("Apply when", tableName: "Profiles")
                    }
                    if case .displays(let displays) = draft.displayRule {
                        let connected = ProfileDisplayWatcher.current().ids
                        ForEach(displays) { display in
                            LabeledContent {
                                Text(connected.contains(display.id) ? String(localized: "Connected", table: "Profiles")
                                                                    : String(localized: "Not connected", table: "Profiles"))
                                    .foregroundStyle(.secondary)
                            } label: {
                                Label(display.name, systemImage: display.isBuiltIn ? "laptopcomputer" : "display")
                            }
                        }
                        Button {
                            draft.displayRule = .displays(ProfileDisplayWatcher.current().displays)
                        } label: {
                            Text("Use the Displays Connected Now", tableName: "Profiles")
                        }
                    }
                } header: {
                    Text("Apply automatically", tableName: "Profiles")
                }
            }
            .formStyle(.grouped)
            ProfileSheetButtons(doneTitle: String(localized: "Done", table: "Profiles"),
                                canFinish: !draft.name.trimmingCharacters(in: .whitespaces).isEmpty,
                                onCancel: onClose) {
                controller.update(draft)
                onClose()
            }
        }
        .frame(minWidth: 480, idealWidth: 480, minHeight: 560, idealHeight: 600)
    }

    private func included(_ group: ProfileSettingsGroup) -> Binding<Bool> {
        Binding(get: { draft.settingsPrefixes.contains(group.prefix) },
                set: { on in
                    draft.settingsPrefixes.removeAll { $0 == group.prefix }
                    if on { draft.settingsPrefixes.append(group.prefix) }
                })
    }

    private var displayChoice: Binding<DisplayChoice> {
        Binding(get: {
            switch draft.displayRule {
            case nil: .none
            case .builtInOnly: .builtInOnly
            case .externalConnected: .externalConnected
            case .displays: .displays
            }
        }, set: { choice in
            switch choice {
            case .none: draft.displayRule = nil
            case .builtInOnly: draft.displayRule = .builtInOnly
            case .externalConnected: draft.displayRule = .externalConnected
            case .displays:
                if case .displays = draft.displayRule { return }
                draft.displayRule = .displays(ProfileDisplayWatcher.current().displays)
            }
        })
    }
}

// MARK: - Shared pieces

private struct ProfileSymbolPicker: View {
    @Binding var symbol: String

    static let symbols = [
        "square.stack.3d.up", "briefcase", "house", "building.2", "desktopcomputer", "laptopcomputer",
        "display.2", "rectangle.on.rectangle", "record.circle", "video", "mic", "person.2",
        "moon", "sun.max", "cup.and.saucer", "airplane", "book", "hammer",
        "paintbrush", "chart.bar", "music.note", "gamecontroller", "lock", "bolt",
    ]

    var body: some View {
        LabeledContent {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 4), count: 8), spacing: 4) {
                ForEach(Self.symbols, id: \.self) { name in
                    Button { symbol = name } label: {
                        Image(systemName: name)
                            .frame(width: 26, height: 22)
                            .background(symbol == name ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.clear),
                                        in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(name))
                }
            }
        } label: {
            Text("Symbol", tableName: "Profiles")
        }
    }
}

private struct ProfileSheetButtons: View {
    let doneTitle: String
    let canFinish: Bool
    let onCancel: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(role: .cancel) { onCancel() } label: { Text("Cancel", tableName: "Profiles") }
                .keyboardShortcut(.cancelAction)
            Button { onDone() } label: { Text(doneTitle) }
                .keyboardShortcut(.defaultAction)
                .disabled(!canFinish)
        }
        .padding(16)
    }
}
