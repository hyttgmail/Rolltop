import AppKit
import RolltopCore
import SwiftUI

/// Settings › General: open at login, the section for new items, Rolltop's menu bar icon
/// (shown or hidden, and how it looks), and what stays visible when Rolltop hides everything.
struct GeneralPane: View {
    let context: AppContext
    let launchAtLogin: LaunchAtLogin

    var body: some View {
        Form {
            SwiftUI.Section {
                launchAtLoginRow
            }
            SwiftUI.Section {
                Picker(selection: defaultSection) {
                    ForEach(RolltopCore.Section.allCases, id: \.self) { section in
                        Text(verbatim: OwnerNames.sectionTitle(section)).tag(section)
                    }
                } label: {
                    Text("Section for new items", tableName: "SettingsShell")
                    Text("Where apps go the first time they show up in the menu bar. Items already there keep their section.",
                         tableName: "SettingsShell")
                }
                .accessibilityIdentifier("general.default-section")
            }
            statusIconSection
            pinnedSection
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
    }

    // MARK: Open at login

    @ViewBuilder
    private var launchAtLoginRow: some View {
        Toggle(isOn: Binding(get: { launchAtLogin.isOn }, set: { launchAtLogin.setEnabled($0) })) {
            Text("Open at login", tableName: "SettingsShell")
            switch launchAtLogin.state {
            case .enabled, .disabled:
                Text("Rolltop starts when you log in, so hidden items stay hidden.", tableName: "SettingsShell")
            case .requiresApproval:
                Text("Waiting for your approval in System Settings › General › Login Items & Extensions.", tableName: "SettingsShell")
            }
        }
        .accessibilityIdentifier("general.open-at-login")
        if launchAtLogin.state == .requiresApproval {
            LabeledContent {
                Button {
                    launchAtLogin.openLoginItemsSettings()
                } label: {
                    Text("Open Login Items", tableName: "SettingsShell")
                }
            } label: {
                EmptyView()
            }
        }
        if let error = launchAtLogin.lastError {
            LimitationNote(Text("Couldn’t change this setting: \(error)", tableName: "SettingsShell"), tone: .warning)
        }
    }

    // MARK: Default section

    private var defaultSection: Binding<RolltopCore.Section> {
        Binding {
            context.layout.layout.defaultSection
        } set: { section in
            guard section != context.layout.layout.defaultSection else { return }
            // Items already in the bar keep their section; only new owners follow the default.
            context.layout.setDefaultSection(section, freezing: context.catalog.presentOwners)
        }
    }

    // MARK: Menu bar icon

    private var statusIcon: Binding<StatusItemIcon> {
        Binding {
            StatusItemIcon(settingValue: context.settings[StatusItemIcon.setting])
        } set: { icon in
            // The default is the absence of a value, so choosing it leaves no key behind.
            if icon == .default {
                context.settings.reset(StatusItemIcon.setting)
            } else {
                context.settings[StatusItemIcon.setting] = icon.rawValue
            }
        }
    }

    private func title(for icon: StatusItemIcon) -> Text {
        switch icon {
        case .slats: Text("Rolltop", tableName: "SettingsShell", comment: "Menu bar icon choice: Rolltop's own glyph, drawn like its app icon (not the Shelf feature)")
        case .stack: Text("Stack", tableName: "SettingsShell", comment: "Menu bar icon choice")
        case .box: Text("Box", tableName: "SettingsShell", comment: "Menu bar icon choice")
        case .dots: Text("Dots", tableName: "SettingsShell", comment: "Menu bar icon choice")
        case .chevron: Text("Arrow", tableName: "SettingsShell", comment: "Menu bar icon choice")
        case .eye: Text("Eye", tableName: "SettingsShell", comment: "Menu bar icon choice")
        }
    }

    private var showsStatusItem: Binding<Bool> {
        Binding {
            context.settings[StatusItemVisibility.setting]
        } set: { shown in
            StatusItemVisibility.set(shown, in: context.settings)
        }
    }

    /// Whether a gesture or a shortcut still shows hidden items while the icon is hidden.
    private var hasWayToShowHiddenItems: Bool {
        let bindings = context.services[.hotkeyBindings]
        _ = bindings.revision
        let shortcuts = StatusItemVisibility.showHiddenCommands.filter { bindings.shortcut(for: $0, arguments: [:]) != nil }
        return StatusItemVisibility.hasWayToShowHiddenItems(gestures: StatusItemVisibility.revealGestures(in: context.settings),
                                                            shortcutCount: shortcuts.count)
    }

    private var statusIconSection: some View {
        SwiftUI.Section {
            Toggle(isOn: showsStatusItem) {
                Text("Show Rolltop in the menu bar", tableName: "SettingsShell")
                Text("If you hide it, open Rolltop again from Finder or Spotlight to get back here. A shortcut you set in Shortcuts or the link rolltop://settings also works.",
                     tableName: "SettingsShell")
            }
            .accessibilityIdentifier("general.show-status-item")
            if !context.settings[StatusItemVisibility.setting], !hasWayToShowHiddenItems {
                LimitationNote(Text("With Rolltop’s icon hidden, nothing shows hidden items: clicking the empty menu bar, hovering, scrolling and shortcuts are all off. Turn one on in Reveal or Shortcuts.",
                                    tableName: "SettingsShell"), tone: .warning)
            }
            Picker(selection: statusIcon) {
                ForEach(StatusItemIcon.allCases, id: \.self) { icon in
                    Label {
                        title(for: icon)
                    } icon: {
                        if let image = icon.resolvedImage(revealed: false) {
                            Image(nsImage: image)
                        }
                    }
                    .labelStyle(.titleAndIcon)
                    .tag(icon)
                }
            } label: {
                Text("Menu bar icon", tableName: "SettingsShell")
                Text("How Rolltop’s icon looks in the menu bar. It changes while hidden items are shown.", tableName: "SettingsShell")
            }
            .accessibilityIdentifier("general.status-icon")
        }
    }

    // MARK: Pinned

    private var pinned: [OwnerID] { context.settings[CoreSettings.pinned] }

    private var pinCandidates: [(owner: OwnerID, name: String)] {
        let pinned = Set(pinned)
        return context.catalog.entries
            .compactMap { entry -> (OwnerID, String)? in
                guard let owner = entry.owner, !entry.isOwn, !pinned.contains(owner) else { return nil }
                return (owner, OwnerNames.name(for: owner, catalog: context.catalog))
            }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }

    private var pinnedSection: some View {
        SwiftUI.Section {
            ForEach(pinned, id: \.self) { owner in
                LabeledContent {
                    Button {
                        context.settings[CoreSettings.pinned] = pinned.filter { $0 != owner }
                    } label: {
                        Text("Remove", tableName: "SettingsShell")
                    }
                    .controlSize(.small)
                } label: {
                    OwnerLabel(owner: owner, name: OwnerNames.name(for: owner, catalog: context.catalog),
                               services: context.services)
                }
            }
            if pinned.isEmpty {
                Text("None", tableName: "SettingsShell")
                    .foregroundStyle(.secondary)
            }
            LabeledContent {
                Menu {
                    ForEach(pinCandidates, id: \.owner) { candidate in
                        Button {
                            context.settings[CoreSettings.pinned] = pinned + [candidate.owner]
                        } label: {
                            Text(verbatim: candidate.name)
                        }
                    }
                } label: {
                    Text("Add Item", tableName: "SettingsShell")
                }
                .fixedSize()
                .disabled(pinCandidates.isEmpty)
            } label: {
                EmptyView()
            }
        } header: {
            Text("Keep visible when hiding everything", tableName: "SettingsShell")
        } footer: {
            Text("When Rolltop also hides the items you normally see, these stay in the menu bar.", tableName: "SettingsShell")
        }
    }
}
