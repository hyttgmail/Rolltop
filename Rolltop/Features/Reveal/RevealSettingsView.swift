import RolltopCore
import SwiftUI

/// Settings pane "Reveal" (id `reveal`): how hidden items are shown and hidden again.
struct RevealSettingsView: View {
    let context: AppContext

    private var settings: SettingsStore { context.settings }

    /// The Rolltop Bar (or another panel) shows hidden items instead of the menu bar.
    private var usesPanel: Bool { context.services[.revealRouting].presentsHiddenInPanel }

    var body: some View {
        Form {
            triggers
            rehide
            makeRoom
            hideEverything
        }
        .formStyle(.grouped)
    }

    // MARK: Sections

    private var triggers: some View {
        Section {
            if !context.permissions.accessibility {
                LabeledContent {
                    Button { context.permissions.openSettings(for: .accessibility) } label: {
                        Text("Open Settings", tableName: "Reveal")
                    }
                } label: {
                    Text("Device Control and Data Access is off", tableName: "Reveal")
                    Text("Rolltop needs it to tell empty menu bar space from items. Until then only Rolltop’s icon and shortcuts show hidden items.",
                         tableName: "Reveal")
                }
            }
            Toggle(isOn: binding(RevealSettings.clickEmptySpace)) {
                Text("Click an empty part of the menu bar", tableName: "Reveal")
                Text("A second click hides them again. Option-click also shows always-hidden items.", tableName: "Reveal")
            }
            Toggle(isOn: binding(RevealSettings.hover)) {
                Text("Hover over the menu bar", tableName: "Reveal")
                if usesPanel {
                    Text("The Rolltop Bar closes when the pointer leaves it and the menu bar. Hold ⌘ to rearrange items without showing them.",
                         tableName: "Reveal")
                } else {
                    Text("They hide again when the pointer leaves the menu bar. Hold ⌘ to rearrange items without showing them.",
                         tableName: "Reveal")
                }
            }
            if settings[RevealSettings.hover] {
                LabeledContent {
                    HStack {
                        Slider(value: binding(RevealSettings.hoverDelay), in: RevealSettings.hoverDelayRange, step: 0.1)
                            .frame(maxWidth: 220)
                        Text(Self.seconds(settings[RevealSettings.hoverDelay]))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                } label: {
                    Text("Hover delay", tableName: "Reveal")
                }
            }
            Toggle(isOn: binding(RevealSettings.scroll)) {
                Text("Scroll or swipe in the menu bar", tableName: "Reveal")
                Text("Down or left shows hidden items, up or right hides them. Scrolling over an item is left to that item.",
                     tableName: "Reveal")
            }
            if settings[RevealSettings.scroll] {
                Toggle(isOn: binding(RevealSettings.scrollRevealsAlwaysHidden)) {
                    Text("Scroll again to show always-hidden items", tableName: "Reveal")
                }
            }
        } header: {
            Text("Show hidden items when I", tableName: "Reveal")
        }
    }

    private var rehide: some View {
        Section {
            Picker(selection: binding(RevealSettings.rehideDelay)) {
                ForEach(RevealSettings.rehideChoices, id: \.self) { seconds in
                    Text(Self.rehideTitle(seconds)).tag(seconds)
                }
            } label: {
                Text("Hide automatically", tableName: "Reveal")
                Text("Counted from your last action. Waits while the pointer is in the menu bar or a menu is open.",
                     tableName: "Reveal")
            }
            Toggle(isOn: binding(RevealSettings.rehideOnClickOutside)) {
                Text("When I click outside the menu bar", tableName: "Reveal")
            }
            Toggle(isOn: binding(RevealSettings.rehideOnAppSwitch)) {
                Text("When I switch to another app", tableName: "Reveal")
                Text("Not when an item you clicked opens its own app.", tableName: "Reveal")
            }
        } header: {
            Text("Hide them again", tableName: "Reveal")
        } footer: {
            if usesPanel {
                caption(Text("The Rolltop Bar closes on its own (see Rolltop Bar). These apply when items show in the menu bar, as after Option-click.",
                             tableName: "Reveal"))
            }
        }
    }

    private var makeRoom: some View {
        Section {
            Toggle(isOn: binding(RevealSettings.makeRoom)) {
                Text("Make room for hidden items", tableName: "Reveal")
                if usesPanel {
                    Text("Hidden items open in the Rolltop Bar and need no room. When items show in the menu bar, as after Option-click, the other items step aside, except \(pinnedNames).",
                         tableName: "Reveal")
                } else {
                    Text("While hidden items are shown, the other items step aside, except \(pinnedNames).", tableName: "Reveal")
                }
            }
            Picker(selection: binding(RevealSettings.makeRoomScope)) {
                Text("On every display", tableName: "Reveal").tag(RevealModes.MakeRoomScope.always.rawValue)
                Text("Only on displays with a notch", tableName: "Reveal").tag(RevealModes.MakeRoomScope.notchedDisplays.rawValue)
            } label: {
                Text("Applies", tableName: "Reveal")
                Text("Decided by the display under the pointer when the items are shown.", tableName: "Reveal")
            }
            .disabled(!settings[RevealSettings.makeRoom])
        } header: {
            Text("Make room", tableName: "Reveal")
        }
    }

    private var hideEverything: some View {
        Section {
            Toggle(isOn: Binding(get: { settings[RevealSettings.hideEverything] },
                                 set: { on in
                                     guard on != settings[RevealSettings.hideEverything] else { return }
                                     context.commands.runDetached(.revealToggleHideEverything, source: .internal)
                                 })) {
                Text("Hide everything", tableName: "Reveal")
                if usesPanel {
                    Text("Hides all items except \(keptNames) until you turn it off. The Rolltop Bar still lists the hidden items, not the ones you normally see. macOS also hides AirDrop, Focus and Now Playing while anything is hidden.",
                         tableName: "Reveal")
                } else {
                    Text("Hides all items except \(keptNames) until you turn it off. Showing hidden items puts them in place of the ones you normally see. macOS also hides AirDrop, Focus and Now Playing while anything is hidden.",
                         tableName: "Reveal")
                }
            }
            Toggle(isOn: binding(RevealSettings.hideEverythingPersists)) {
                Text("Keep it on after Rolltop restarts", tableName: "Reveal")
            }
        } header: {
            Text("Minimal menu bar", tableName: "Reveal")
        }
    }

    // MARK: Helpers

    private func caption(_ text: Text) -> some View {
        text.fixedSize(horizontal: false, vertical: true)
    }

    private func binding<Value>(_ key: SettingsKey<Value>) -> Binding<Value> {
        let settings = settings
        return Binding(get: { settings[key] }, set: { settings[key] = $0 })
    }

    /// "Clock and Control Center" from the pinned owners.
    private var pinnedNames: String { Self.list(settings[CoreSettings.pinned].map { context.catalog.displayName(for: $0) }) }

    /// "Clock, Control Center and Rolltop": what hide everything keeps.
    private var keptNames: String {
        Self.list(settings[CoreSettings.pinned].map { context.catalog.displayName(for: $0) } + ["Rolltop"])
    }

    /// Joined in the language the app shows, not the system's ("Clock和Control Center").
    private static func list(_ names: [String]) -> String {
        let language = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return names.formatted(.list(type: .and).locale(language))
    }

    static func seconds(_ value: Double) -> String {
        Measurement(value: value, unit: UnitDuration.seconds)
            .formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(1))))
    }

    static func rehideTitle(_ seconds: Int) -> String {
        switch seconds {
        case 0: String(localized: "Never", table: "Reveal")
        case 60: String(localized: "After 1 minute", table: "Reveal")
        default: String(localized: "After \(seconds) seconds", table: "Reveal")
        }
    }
}
