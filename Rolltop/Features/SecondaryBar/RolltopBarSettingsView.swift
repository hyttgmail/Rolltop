import SwiftUI

/// The "Rolltop Bar" settings pane (id `secondary-bar`). Grouped form, changes apply at once.
struct RolltopBarSettingsView: View {
    let context: AppContext

    var body: some View {
        let settings = context.settings
        Form {
            Section {
                Toggle(isOn: Binding(get: { settings[RolltopBarSettings.enabled] },
                                     set: { settings[RolltopBarSettings.enabled] = $0 })) {
                    Text("Show hidden items in the Rolltop Bar", tableName: "SecondaryBar")
                    Text("Hidden items appear in a bar below the menu bar instead of in the menu bar itself, so nothing moves. Option-clicking Rolltop’s icon still shows all items in the menu bar.",
                         tableName: "SecondaryBar")
                }
                Toggle(isOn: Binding(get: { settings[RolltopBarSettings.onlyWithNotch] },
                                     set: { settings[RolltopBarSettings.onlyWithNotch] = $0 })) {
                    Text("Use the Rolltop Bar only on displays with a notch", tableName: "SecondaryBar")
                    Text("On other displays, hidden items appear in the menu bar.", tableName: "SecondaryBar")
                }
                .disabled(!settings[RolltopBarSettings.enabled])
                Toggle(isOn: Binding(get: { settings[RolltopBarSettings.whenFull] },
                                     set: { settings[RolltopBarSettings.whenFull] = $0 })) {
                    Text("Use the Rolltop Bar when the menu bar is full", tableName: "SecondaryBar")
                    Text("The menu bar is full when macOS shows its » button for items that don’t fit. Hidden items then open in the Rolltop Bar, even where it is otherwise off.",
                         tableName: "SecondaryBar")
                    Text("The first time hidden items don’t fit on a display, they appear in the menu bar for a moment before moving to the Rolltop Bar.",
                         tableName: "SecondaryBar")
                }
                Picker(selection: Binding(get: { RolltopBarStyle(setting: settings[RolltopBarSettings.style]) },
                                          set: { settings[RolltopBarSettings.style] = $0.rawValue })) {
                    Text("Adaptive", tableName: "SecondaryBar").tag(RolltopBarStyle.adaptive)
                    Text("Light", tableName: "SecondaryBar").tag(RolltopBarStyle.light)
                    Text("Dark", tableName: "SecondaryBar").tag(RolltopBarStyle.dark)
                    Text("Accent color", tableName: "SecondaryBar").tag(RolltopBarStyle.accent)
                    Text("Frosted", tableName: "SecondaryBar").tag(RolltopBarStyle.frosted)
                } label: {
                    Text("Style", tableName: "SecondaryBar")
                    Text("Adaptive follows what is behind the bar. Frosted is more opaque, for legibility.", tableName: "SecondaryBar")
                }
                Picker(selection: Binding(get: { RolltopBarItemSize(setting: settings[RolltopBarSettings.itemSize]) },
                                          set: { settings[RolltopBarSettings.itemSize] = $0.rawValue })) {
                    Text("Small", tableName: "SecondaryBar").tag(RolltopBarItemSize.small)
                    Text("Same as the menu bar", tableName: "SecondaryBar").tag(RolltopBarItemSize.regular)
                    Text("Large", tableName: "SecondaryBar").tag(RolltopBarItemSize.large)
                } label: {
                    Text("Item size", tableName: "SecondaryBar")
                }
                Picker(selection: Binding(get: { AlwaysHiddenPresentation(setting: settings[RolltopBarSettings.alwaysHidden]) },
                                          set: { settings[RolltopBarSettings.alwaysHidden] = $0.rawValue })) {
                    Text("Behind a disclosure", tableName: "SecondaryBar").tag(AlwaysHiddenPresentation.disclosure)
                    Text("Always", tableName: "SecondaryBar").tag(AlwaysHiddenPresentation.always)
                } label: {
                    Text("Show always-hidden items", tableName: "SecondaryBar")
                    Text("Hold Option while opening the Rolltop Bar to include them once.", tableName: "SecondaryBar")
                }
                Picker(selection: Binding(get: { Self.timeoutChoice(settings[RolltopBarSettings.idleTimeout]) },
                                          set: { settings[RolltopBarSettings.idleTimeout] = $0 })) {
                    Text("After 5 seconds", tableName: "SecondaryBar").tag(5.0)
                    Text("After 10 seconds", tableName: "SecondaryBar").tag(10.0)
                    Text("After 30 seconds", tableName: "SecondaryBar").tag(30.0)
                    Text("Never", tableName: "SecondaryBar").tag(0.0)
                } label: {
                    Text("Close when idle", tableName: "SecondaryBar")
                    Text("Opened by hovering, the Rolltop Bar closes when the pointer leaves it and the menu bar.",
                         tableName: "SecondaryBar")
                }
            }
            ContributedSettingsSections(paneID: "secondary-bar", registry: context.settingsPanes)
        }
        .formStyle(.grouped)
    }

    static func timeoutChoice(_ value: Double) -> Double {
        [5.0, 10.0, 30.0, 0.0].min { abs($0 - value) < abs($1 - value) } ?? 10
    }
}
