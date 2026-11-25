import AppKit
import RolltopCore
import SwiftUI
import UniformTypeIdentifiers

/// The "Shelf" settings pane (id `shelf`). Grouped form; changes apply at once. Section
/// options stay visible (disabled) while their section is off, so the pane says what each
/// section would do before the user turns it on.
struct ShelfSettingsView: View {
    let context: AppContext
    let controller: ShelfController
    @State private var confirmClear = false

    var body: some View {
        let settings = context.settings
        let clipboardOn = settings[ShelfSettings.clipboardEnabled]
        let filesOn = settings[ShelfSettings.filesEnabled]
        let upNextOn = settings[ShelfSettings.upNextEnabled]
        Form {
            Section {
                Toggle(isOn: binding(ShelfSettings.openOnHover)) {
                    Text("Open when the pointer rests on the notch", tableName: "Shelf")
                    Text("On a display without a notch, the top center of the menu bar. “Shelf” in Rolltop’s menu and its shortcut always open it.", tableName: "Shelf")
                }
                Picker(selection: Binding(get: { Self.nearest(settings[ShelfSettings.hoverDelay], in: ShelfSettings.hoverDelayChoices) },
                                          set: { settings[ShelfSettings.hoverDelay] = $0 })) {
                    ForEach(ShelfSettings.hoverDelayChoices, id: \.self) { delay in
                        Text("\(delay.formatted(.number.precision(.fractionLength(1)))) seconds", tableName: "Shelf").tag(delay)
                    }
                } label: {
                    Text("Delay", tableName: "Shelf")
                }
                .disabled(!settings[ShelfSettings.openOnHover])
                Toggle(isOn: Binding(get: { filesOn && settings[ShelfSettings.openOnDrag] },
                                     set: { settings[ShelfSettings.openOnDrag] = $0 })) {
                    Text("Open when dragging files to the top of the screen", tableName: "Shelf")
                    Text("Drag files toward the notch or the top center, then drop them on the shelf. Needs the file shelf.", tableName: "Shelf")
                }
                .disabled(!filesOn)
                Picker(selection: Binding(get: { ShelfPanelSize(setting: settings[ShelfSettings.panelSize]) },
                                          set: { settings[ShelfSettings.panelSize] = $0.rawValue })) {
                    Text("Small", tableName: "Shelf").tag(ShelfPanelSize.small)
                    Text("Medium", tableName: "Shelf").tag(ShelfPanelSize.medium)
                    Text("Large", tableName: "Shelf").tag(ShelfPanelSize.large)
                } label: {
                    Text("Panel size", tableName: "Shelf")
                }
            } header: {
                Text("Opening", tableName: "Shelf")
            }

            Section {
                Toggle(isOn: binding(ShelfSettings.hintsEnabled)) {
                    Text("Show hints", tableName: "Shelf")
                    Text("A small expansion of the shelf briefly shows what changed. macOS shows its own volume and brightness indicator; Rolltop’s hint appears in addition to it.", tableName: "Shelf")
                }
                Group {
                    Toggle(isOn: binding(ShelfSettings.hintsVolume)) { Text("Volume", tableName: "Shelf") }
                    Toggle(isOn: binding(ShelfSettings.hintsBrightness)) { Text("Brightness", tableName: "Shelf") }
                    Toggle(isOn: binding(ShelfSettings.hintsBattery)) {
                        Text("Battery", tableName: "Shelf")
                        Text("Plugged in, unplugged, fully charged, and when the battery runs low.", tableName: "Shelf")
                    }
                }
                .disabled(!settings[ShelfSettings.hintsEnabled])
            } header: {
                Text("Hints", tableName: "Shelf")
            }

            Section {
                Toggle(isOn: binding(ShelfSettings.nowPlayingCard)) {
                    Text("Now playing", tableName: "Shelf")
                    Text("Shows what is playing in Music or Spotify, with controls, once Rolltop may read that app (Settings › Permissions).", tableName: "Shelf")
                }
                Toggle(isOn: binding(ShelfSettings.weatherCard)) {
                    Text("Weather", tableName: "Shelf")
                    Text("Shows the weather for the place chosen in Weather settings, while weather is on.", tableName: "Shelf")
                }
            } header: {
                Text("Cards", tableName: "Shelf")
            }

            Section {
                Toggle(isOn: binding(ShelfSettings.clipboardEnabled)) {
                    Text("Clipboard history", tableName: "Shelf")
                    Text("Records the text, rich text, links, file references and images you copy, on this Mac only. Skips what apps mark as concealed or temporary and anything copied in an ignored app. Turning it off deletes the history.", tableName: "Shelf")
                }
                Picker(selection: binding(ShelfSettings.clipboardLimit)) {
                    ForEach(ShelfSettings.clipboardLimitChoices, id: \.self) { count in
                        Text("\(count) clips", tableName: "Shelf").tag(count)
                    }
                } label: {
                    Text("Keep up to", tableName: "Shelf")
                }
                .disabled(!clipboardOn)
                Picker(selection: binding(ShelfSettings.clipboardMaxAgeDays)) {
                    ForEach(ShelfSettings.clipboardAgeChoices, id: \.self) { days in
                        Text("\(days) days", tableName: "Shelf").tag(days)
                    }
                } label: {
                    Text("Keep for", tableName: "Shelf")
                    Text("Pinned clips stay until you unpin or delete them.", tableName: "Shelf")
                }
                .disabled(!clipboardOn)
                Toggle(isOn: binding(ShelfSettings.clipboardClearOnQuit)) {
                    Text("Clear when Rolltop quits", tableName: "Shelf")
                }
                .disabled(!clipboardOn)
                LabeledContent {
                    if controller.pausedUntil != nil {
                        Button { controller.resume() } label: { Text("Resume", tableName: "Shelf") }
                    } else {
                        Menu {
                            ForEach(ShelfSettings.pauseChoices, id: \.self) { minutes in
                                Button { controller.pause(minutes: minutes) } label: { ShelfFormat.pauseTitle(minutes) }
                            }
                        } label: {
                            Text("Pause", tableName: "Shelf")
                        }
                        .fixedSize()
                    }
                } label: {
                    Text("Recording", tableName: "Shelf")
                    if let until = controller.pausedUntil {
                        Text("Paused until \(until.formatted(date: .omitted, time: .shortened)). What you copy meanwhile is not recorded.", tableName: "Shelf")
                    }
                }
                .disabled(!clipboardOn)
                Picker(selection: Binding(get: { ShelfChooseAction(setting: settings[ShelfSettings.chooseAction]) },
                                          set: { settings[ShelfSettings.chooseAction] = $0.rawValue })) {
                    Text("Copy it", tableName: "Shelf").tag(ShelfChooseAction.copy)
                    Text("Copy and paste it into the frontmost app", tableName: "Shelf").tag(ShelfChooseAction.paste)
                } label: {
                    Text("When you choose a clip", tableName: "Shelf")
                    Text("Pasting needs Device Control and Data Access and sends one ⌘V to the frontmost app. Option-click a clip in the shelf, or press ⌘Return in Search, to do the other.", tableName: "Shelf")
                }
                .disabled(!clipboardOn)
                ShelfIgnoredAppsEditor(context: context)
                    .disabled(!clipboardOn)
                LabeledContent {
                    Button(role: .destructive) { confirmClear = true } label: { Text("Clear History…", tableName: "Shelf") }
                        .disabled(!clipboardOn || controller.history.clips.isEmpty)
                } label: {
                    Text("\(controller.history.clips.count) clips stored", tableName: "Shelf")
                }
                .confirmationDialog(Text("Clear the clipboard history?", tableName: "Shelf"), isPresented: $confirmClear) {
                    Button(role: .destructive) { controller.clearHistory() } label: { Text("Clear History", tableName: "Shelf") }
                } message: {
                    Text("Every clip except pinned ones is deleted from this Mac.", tableName: "Shelf")
                }
                if clipboardOn {
                    ShelfPasteboardAccessNote(behavior: controller.generalAccessBehavior, refused: controller.clipboardReadRefused)
                }
            } header: {
                Text("Clipboard history", tableName: "Shelf")
            }

            Section {
                Toggle(isOn: binding(ShelfSettings.filesEnabled)) {
                    Text("File shelf", tableName: "Shelf")
                    Text("A holding area for files and folders: drop them on the shelf, drag them out later. Rolltop keeps a reference, never a copy; turning it off empties the shelf, not your files.", tableName: "Shelf")
                }
                Picker(selection: binding(ShelfSettings.filesLifetimeHours)) {
                    Text("After 1 hour", tableName: "Shelf").tag(1)
                    Text("After 24 hours", tableName: "Shelf").tag(24)
                    Text("After 7 days", tableName: "Shelf").tag(24 * 7)
                    Text("Never", tableName: "Shelf").tag(0)
                } label: {
                    Text("Remove files", tableName: "Shelf")
                }
                .disabled(!filesOn)
                Toggle(isOn: binding(ShelfSettings.filesRemoveAfterDrag)) {
                    Text("Remove a file after dragging it out", tableName: "Shelf")
                }
                .disabled(!filesOn)
            } header: {
                Text("File shelf", tableName: "Shelf")
            }

            Section {
                Toggle(isOn: Binding(get: { settings[ShelfSettings.upNextEnabled] }, set: { on in
                    settings[ShelfSettings.upNextEnabled] = on
                    // The user's click on this switch is the one moment Rolltop may ask macOS.
                    if on, controller.currentCalendarAccess == .notDetermined { controller.requestCalendarAccess() }
                })) {
                    Text("Up next", tableName: "Shelf")
                    Text("Shows the next events of today and tomorrow, with a Join button for Zoom, Google Meet, Teams, Webex and FaceTime links. Turning it on asks for access to your calendars.", tableName: "Shelf")
                }
                Picker(selection: binding(ShelfSettings.upNextCount)) {
                    ForEach(ShelfSettings.upNextCountChoices, id: \.self) { count in
                        Text("\(count) events", tableName: "Shelf").tag(count)
                    }
                } label: {
                    Text("Show up to", tableName: "Shelf")
                }
                .disabled(!upNextOn)
                if upNextOn {
                    ShelfCalendarAccessRow(controller: controller)
                }
            } header: {
                Text("Up next", tableName: "Shelf")
            }

            Section {
                LabeledContent {
                    EmptyView()
                } label: {
                    Text("What is stored where", tableName: "Shelf")
                    Text("Clipboard history and the file shelf’s references are stored only on this Mac, in ~/Library/Application Support/Rolltop/Shelf, readable only by your user account and left out of Time Machine. Calendar events are read when the shelf opens and never stored. Nothing leaves this Mac.", tableName: "Shelf")
                }
            } header: {
                Text("Privacy", tableName: "Shelf")
            }
        }
        .formStyle(.grouped)
        .onAppear { controller.refreshCalendarAccess() }
    }

    private func binding<Value: Codable & Sendable>(_ key: SettingsKey<Value>) -> Binding<Value> {
        let settings = context.settings
        return Binding(get: { settings[key] }, set: { settings[key] = $0 })
    }

    static func nearest(_ value: Double, in choices: [Double]) -> Double {
        choices.min { abs($0 - value) < abs($1 - value) } ?? value
    }
}

/// macOS asks before Rolltop reads the general pasteboard (since 15.4).
private struct ShelfPasteboardAccessNote: View {
    let behavior: NSPasteboard.AccessBehavior
    let refused: Bool

    var body: some View {
        switch behavior {
        case .alwaysAllow:
            EmptyView()
        case .alwaysDeny:
            LimitationNote(Text("macOS does not let Rolltop read what you copy. Allow pasting from other apps for Rolltop in System Settings › Privacy & Security.", tableName: "Shelf"),
                           tone: .warning)
        default:
            LimitationNote(Text("macOS asks before Rolltop reads what you copy. To record without being asked each time, allow pasting from other apps for Rolltop in System Settings › Privacy & Security.", tableName: "Shelf"),
                           tone: refused ? .warning : .info)
        }
    }
}

private struct ShelfCalendarAccessRow: View {
    let controller: ShelfController

    var body: some View {
        LabeledContent {
            switch controller.calendarAccess {
            case .granted:
                Label { Text("Allowed", tableName: "Shelf") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            case .notDetermined:
                Button { controller.requestCalendarAccess() } label: { Text("Allow Access…", tableName: "Shelf") }
            case .denied, .restricted, .writeOnly:
                Button { controller.requestCalendarAccess() } label: { Text("Open Privacy Settings", tableName: "Shelf") }
            }
        } label: {
            Text("Calendar access", tableName: "Shelf")
            if controller.calendarAccess != .granted {
                Text("Without it, Up next explains what it needs instead of listing events.", tableName: "Shelf")
            }
        }
    }
}

/// The user-editable ignore list (bundle ids), seeded with password managers.
private struct ShelfIgnoredAppsEditor: View {
    let context: AppContext
    @State private var isExpanded = false

    var body: some View {
        let settings = context.settings
        let apps = settings[ShelfSettings.clipboardIgnoredApps]
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(apps, id: \.self) { bundleID in
                HStack(spacing: 8) {
                    if let icon = ShelfAppIcons.icon(for: bundleID) {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16).accessibilityHidden(true)
                    } else {
                        Image(systemName: "app.dashed").frame(width: 16, height: 16).foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                    Text(verbatim: Self.name(for: bundleID))
                    Spacer()
                    Button {
                        settings[ShelfSettings.clipboardIgnoredApps] = apps.filter { $0 != bundleID }
                    } label: {
                        Image(systemName: "minus.circle").accessibilityLabel(Text("Remove", tableName: "Shelf"))
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                Button { addApp() } label: { Text("Add App…", tableName: "Shelf") }
                Spacer()
                Button { settings.reset(ShelfSettings.clipboardIgnoredApps) } label: { Text("Restore Defaults", tableName: "Shelf") }
                    .disabled(!settings.hasValue(for: ShelfSettings.clipboardIgnoredApps))
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ignored apps", tableName: "Shelf")
                Text("Nothing is recorded while one of these apps is in front. Password managers are listed already.", tableName: "Shelf")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path(percentEncoded: false)).replacingOccurrences(of: ".app", with: "")
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.prompt = String(localized: "Ignore", table: "Shelf")
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        var apps = context.settings[ShelfSettings.clipboardIgnoredApps]
        for id in ids where !apps.contains(id) { apps.append(id) }
        context.settings[ShelfSettings.clipboardIgnoredApps] = apps
    }
}
