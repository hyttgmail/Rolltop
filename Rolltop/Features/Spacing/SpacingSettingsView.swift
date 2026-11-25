import SwiftUI

/// Settings › Item Spacing.
struct SpacingSettingsView: View {
    let store: SpacingStore
    /// Items on the main display's bar, for the "about N more items" estimate.
    let itemCount: () -> Int

    @State private var showsAdvanced = false
    @State private var customSpacing = 8
    @State private var customPadding = 8
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                Picker(selection: presetBinding) {
                    ForEach(SpacingPreset.allCases) { preset in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.title(preset))
                            Text(caption(preset))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(Optional(preset))
                    }
                    if case .custom = store.reading.choice {
                        Text("Custom", tableName: "Spacing").tag(SpacingPreset?.none)
                    }
                } label: {
                    Text("Space between items", tableName: "Spacing")
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("Applies to each app after it is relaunched, and everywhere after you log out and back in.", tableName: "Spacing")
            }

            Section {
                LabeledContent {
                    Text(valueText(store.reading.spacing, effective: store.reading.effective.spacing))
                } label: {
                    Text("Item spacing", tableName: "Spacing")
                }
                LabeledContent {
                    Text(valueText(store.reading.padding, effective: store.reading.effective.padding))
                } label: {
                    Text("Selection padding", tableName: "Spacing")
                }
                if store.isSetElsewhere {
                    Label {
                        Text("These values were set outside Rolltop, for example by another app or in Terminal.", tableName: "Spacing")
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.callout)
                }
                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button {
                        perform { try store.resetToDefault() }
                    } label: {
                        Text("Reset to Default", tableName: "Spacing")
                    }
                    .disabled(store.reading.isAbsent)
                }
            } header: {
                Text("Current values", tableName: "Spacing")
            }

            Section {
                DisclosureGroup(isExpanded: $showsAdvanced) {
                    Stepper(value: $customSpacing, in: SpacingValues.range) {
                        LabeledContent {
                            Text(verbatim: "\(customSpacing) pt").monospacedDigit()
                        } label: {
                            Text("Item spacing", tableName: "Spacing")
                        }
                    }
                    Stepper(value: $customPadding, in: SpacingValues.range) {
                        LabeledContent {
                            Text(verbatim: "\(customPadding) pt").monospacedDigit()
                        } label: {
                            Text("Selection padding", tableName: "Spacing")
                        }
                    }
                    Text("Selection padding is the room around an item’s highlight; keep it at or below the spacing so highlights do not overlap.", tableName: "Spacing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button {
                            perform { try store.write(SpacingValues(spacing: customSpacing, padding: customPadding)) }
                        } label: {
                            Text("Apply Custom Values", tableName: "Spacing")
                        }
                    }
                } label: {
                    Text("Advanced", tableName: "Spacing")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            store.reload()
            let effective = store.reading.effective
            customSpacing = effective.spacing
            customPadding = effective.padding
        }
    }

    private var presetBinding: Binding<SpacingPreset?> {
        Binding {
            if case .preset(let preset) = store.reading.choice { return preset }
            return nil
        } set: { newValue in
            guard let newValue else { return }
            perform { try store.apply(newValue) }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func caption(_ preset: SpacingPreset) -> String {
        guard let values = preset.values else {
            return String(localized: "macOS spacing (16 pt, padding 16 pt)", table: "Spacing")
        }
        let extra = SpacingEstimate.extraItems(itemCount: itemCount(), values: values)
        return String(localized: "\(values.spacing) pt, padding \(values.padding) pt; room for about \(extra) more", table: "Spacing")
    }

    private func valueText(_ stored: Int?, effective: Int) -> String {
        if stored == nil {
            return String(localized: "\(effective) pt (macOS default)", table: "Spacing")
        }
        return String(localized: "\(effective) pt", table: "Spacing")
    }

    static func title(_ preset: SpacingPreset) -> String {
        switch preset {
        case .default: String(localized: "Default", table: "Spacing")
        case .small: String(localized: "Small", table: "Spacing")
        case .tiny: String(localized: "Tiny", table: "Spacing")
        case .none: String(localized: "None", table: "Spacing")
        }
    }
}
