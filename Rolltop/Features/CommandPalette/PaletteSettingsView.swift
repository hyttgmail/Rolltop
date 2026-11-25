import RolltopCore
import SwiftUI

/// The "Search" settings pane (id `palette`). Grouped form, changes apply at once.
struct PaletteSettingsView: View {
    let context: AppContext
    let usage: PaletteUsageStore

    var body: some View {
        let settings = context.settings
        Form {
            Section {
                LabeledContent {
                    if let shortcut {
                        Text(verbatim: shortcut)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("None", tableName: "CommandPalette")
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        context.services[.settingsWindow].showSettings(paneID: PaletteCommandIDs.shortcutsPaneID)
                    } label: {
                        Text("Change in Shortcuts…", tableName: "CommandPalette")
                    }
                } label: {
                    Text("Keyboard shortcut", tableName: "CommandPalette")
                    Text("Search Menu Bar Items… is also in Rolltop’s menu.", tableName: "CommandPalette")
                }
                Picker(selection: Binding(get: { PaletteScreenChoice(setting: settings[PaletteSettings.screen]) },
                                          set: { settings[PaletteSettings.screen] = $0.rawValue })) {
                    Text("Display with the pointer", tableName: "CommandPalette").tag(PaletteScreenChoice.pointer)
                    Text("Main display", tableName: "CommandPalette").tag(PaletteScreenChoice.main)
                } label: {
                    Text("Show the panel on", tableName: "CommandPalette")
                }
                Toggle(isOn: binding(PaletteSettings.closeAfterRunning)) {
                    Text("Close after running", tableName: "CommandPalette")
                    Text("When off, the panel stays open after a command or profile runs. Menu bar items and settings always close it.",
                         tableName: "CommandPalette")
                }
            }

            Section {
                Toggle(isOn: binding(PaletteSettings.includeItems)) {
                    Text("Menu bar items", tableName: "CommandPalette")
                }
                Toggle(isOn: binding(PaletteSettings.includeProfiles)) {
                    Text("Profiles", tableName: "CommandPalette")
                }
                Toggle(isOn: binding(PaletteSettings.includeCommands)) {
                    Text("Commands", tableName: "CommandPalette")
                }
                Toggle(isOn: binding(PaletteSettings.includeSettings)) {
                    Text("Settings", tableName: "CommandPalette")
                }
                ForEach(providers, id: \.id) { provider in
                    Toggle(isOn: providerBinding(provider.id)) {
                        Text(verbatim: provider.title)
                    }
                }
            } header: {
                Text("Include in results", tableName: "CommandPalette")
            }

            Section {
                LabeledContent {
                    Button {
                        usage.clear()
                    } label: {
                        Text("Clear History", tableName: "CommandPalette")
                    }
                    .disabled(usage.usage.isEmpty)
                } label: {
                    Text("Search history", tableName: "CommandPalette")
                    Text("Results you run often or recently rank higher. The history stays on this Mac and is not part of exported settings or profiles.",
                         tableName: "CommandPalette")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var shortcut: String? {
        let hotkeys = context.services[.hotkeyBindings]
        _ = hotkeys.revision
        let combo = hotkeys.shortcut(for: PaletteCommandIDs.toggle, arguments: [:])
            ?? hotkeys.shortcut(for: PaletteCommandIDs.show, arguments: [:])
        return combo.map { hotkeys.displayString(for: $0) }
    }

    private var providers: [any PaletteResultProviding] {
        context.services[.paletteResultProviders].providers
    }

    private func binding(_ key: SettingsKey<Bool>) -> Binding<Bool> {
        Binding(get: { context.settings[key] }, set: { context.settings[key] = $0 })
    }

    private func providerBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { !context.settings[PaletteSettings.disabledProviders].contains(id) },
                set: { isOn in
                    var disabled = context.settings[PaletteSettings.disabledProviders].filter { $0 != id }
                    if !isOn { disabled.append(id) }
                    context.settings[PaletteSettings.disabledProviders] = disabled
                })
    }
}
