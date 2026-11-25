import AppKit
import RolltopCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Integrations: who may send `rolltop://` links, the link catalogue with Copy,
/// what Shortcuts offers (actions and the Focus filter), and AppleScript examples.
struct InteropIntegrationsPane: View {
    let context: AppContext
    let gate: InteropLinkGate
    @State private var copied: String?

    var body: some View {
        Form {
            linksSection
            appsSection
            catalogueSection
            shortcutsSection
            appleScriptSection
            if !gate.recent.isEmpty { recentSection }
        }
        .formStyle(.grouped)
    }

    // MARK: Links

    private func binding(_ key: SettingsKey<Bool>) -> Binding<Bool> {
        Binding(get: { context.settings[key] }, set: { context.settings[key] = $0 })
    }

    private var linksSection: some View {
        SwiftUI.Section {
            Toggle(isOn: binding(InteropSettings.linksEnabled)) {
                Text("Allow links", tableName: "Automation")
                Text("Other apps, scripts and web pages can show and hide items, open them, apply profiles and quit Rolltop with rolltop:// links.",
                     tableName: "Automation")
            }
            .accessibilityIdentifier("integrations.links-enabled")
            Toggle(isOn: binding(InteropSettings.allowUnknownSenders)) {
                Text("Allow links from unknown senders", tableName: "Automation")
                Text("Scripts and the open command send links without naming an app, so Rolltop cannot ask about them. While this is on, any program on this Mac can send such links.",
                     tableName: "Automation")
            }
            .disabled(!context.settings[InteropSettings.linksEnabled])
            Toggle(isOn: binding(InteropSettings.allowSettingsCommands)) {
                Text("Allow links that change settings", tableName: "Automation")
                Text("Also lets links move items between sections, change the menu bar’s look and pause automations. Links can never reset, delete, import or turn on scripts.",
                     tableName: "Automation")
            }
            .disabled(!context.settings[InteropSettings.linksEnabled])
        } header: {
            Text("Links", tableName: "Automation")
        }
    }

    private var appsSection: some View {
        SwiftUI.Section {
            let records = context.settings[InteropSettings.linkApps].sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if records.isEmpty {
                Text("No app has sent a link yet. The first link from an app asks you once.", tableName: "Automation")
                    .foregroundStyle(.secondary)
            }
            ForEach(records) { record in
                InteropLinkAppRow(record: record, gate: gate)
            }
            Button { addApp() } label: { Text("Add App…", tableName: "Automation") }
        } header: {
            Text("Apps", tableName: "Automation")
        } footer: {
            Text("Allowed apps run links without asking. Links from blocked apps are ignored.", tableName: "Automation")
        }
    }

    private var catalogueSection: some View {
        SwiftUI.Section {
            ForEach(InteropLinkCatalogue.examples(context: context)) { example in
                LabeledContent {
                    Button {
                        copy(example.example)
                    } label: {
                        Text(copied == example.example ? LocalizedStringResource("Copied", table: "Automation")
                                                       : LocalizedStringResource("Copy", table: "Automation"))
                    }
                    .accessibilityLabel(Text("Copy \(example.template)", tableName: "Automation"))
                } label: {
                    Text(verbatim: example.template)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    Text(example.parameters.map {
                        String(localized: "\(example.summary) \($0)", table: "Automation",
                               comment: "Two sentences shown as one paragraph (Chinese joins them without a space)")
                    } ?? example.summary)
                }
            }
        } header: {
            Text("Available links", tableName: "Automation")
        } footer: {
            Text("Any command that allows links also works as rolltop://command/<id>?name=value. Open a link from a browser, an app, or a script: open \"rolltop://toggle\".",
                 tableName: "Automation")
        }
    }

    private var recentSection: some View {
        SwiftUI.Section {
            ForEach(gate.recent.prefix(5)) { entry in
                LabeledContent {
                    Text(InteropLinkCatalogue.outcomeTitle(entry))
                        .foregroundStyle(entry.outcome == .refused || entry.outcome == .failed ? .orange : .secondary)
                } label: {
                    Text(verbatim: entry.command)
                    Text("From \(entry.sender), \(entry.date.formatted(date: .omitted, time: .shortened))", tableName: "Automation")
                }
            }
        } header: {
            Text("Recent links", tableName: "Automation")
        }
    }

    // MARK: Shortcuts and AppleScript

    private var shortcutsSection: some View {
        SwiftUI.Section {
            LabeledContent {
                EmptyView()
            } label: {
                Text("Actions", tableName: "Automation")
                Text("Show, Hide and Toggle Hidden Items, Show All Items, Apply Profile, Get Current Profile, Open Menu Bar Item, Set Section of Menu Bar Item, Get Menu Bar Items, and Run Rolltop Command.",
                     tableName: "Automation")
            }
            LabeledContent {
                EmptyView()
            } label: {
                Text("Focus filter", tableName: "Automation")
                Text("In System Settings › Focus, add Rolltop’s filter to a Focus to apply a profile while that Focus is on. The previous profile comes back when it ends.",
                     tableName: "Automation")
            }
        } header: {
            Text("Shortcuts", tableName: "Automation")
        } footer: {
            Text("Actions that open or move items need Device Control and Data Access, like the rest of Rolltop.", tableName: "Automation")
        }
    }

    private var appleScriptSection: some View {
        SwiftUI.Section {
            ForEach(InteropLinkCatalogue.appleScriptExamples, id: \.self) { script in
                LabeledContent {
                    Button { copy(script) } label: {
                        Text(copied == script ? LocalizedStringResource("Copied", table: "Automation")
                                              : LocalizedStringResource("Copy", table: "Automation"))
                    }
                } label: {
                    Text(verbatim: script)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("AppleScript", tableName: "Automation")
        } footer: {
            Text("Script Editor shows every command in Rolltop’s dictionary (File › Open Dictionary). macOS asks you once before an app may control Rolltop.",
                 tableName: "Automation")
        }
    }

    // MARK: Actions

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = text
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url, let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            gate.setDecision(.allowed, bundleID: bundleID, name: name)
        }
    }
}

private struct InteropLinkAppRow: View {
    let record: InteropLinkAppRecord
    let gate: InteropLinkGate

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: record.bundleID) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: record.name)
                Text(verbatim: record.bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Picker(selection: Binding(get: { record.decision },
                                      set: { gate.setDecision($0, bundleID: record.bundleID, name: record.name) })) {
                Text("Allowed", tableName: "Automation").tag(InteropLinkAppRecord.Decision.allowed)
                Text("Blocked", tableName: "Automation").tag(InteropLinkAppRecord.Decision.blocked)
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .fixedSize()
            Button {
                gate.forget(bundleID: record.bundleID)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Forget \(record.name)", tableName: "Automation"))
            .help(Text("Forget this app; its next link asks again", tableName: "Automation"))
        }
    }
}

/// The links the pane lists, with a real example where one exists.
enum InteropLinkCatalogue {
    static func examples(context: AppContext) -> [InteropLinkExample] {
        let profile = context.services[.profiles].profiles.first?.id
        let owner = context.catalog.entries.first { $0.owner != nil && !$0.isOwn }?.owner?.stringValue ?? "com.example.App"
        var list: [InteropLinkExample] = [
            .init(template: "rolltop://toggle", example: "rolltop://toggle",
                  summary: String(localized: "Shows or hides the hidden items.", table: "Automation"), parameters: nil),
            .init(template: "rolltop://show", example: "rolltop://show",
                  summary: String(localized: "Shows the hidden items.", table: "Automation"), parameters: nil),
            .init(template: "rolltop://show-all", example: "rolltop://show-all",
                  summary: String(localized: "Shows every item, including the always-hidden ones.", table: "Automation"), parameters: nil),
            .init(template: "rolltop://hide", example: "rolltop://hide",
                  summary: String(localized: "Hides the items again.", table: "Automation"), parameters: nil),
            .init(template: "rolltop://profile/<id>", example: "rolltop://profile/\(profile ?? "work")",
                  summary: String(localized: "Applies a profile.", table: "Automation"),
                  parameters: String(localized: "<id> is the profile’s id.", table: "Automation")),
            .init(template: "rolltop://item/<owner>?button=right", example: "rolltop://item/\(owner)",
                  summary: String(localized: "Opens a menu bar item.", table: "Automation"),
                  parameters: String(localized: "<owner> is a bundle id or system:wifi, system:battery…; button is left (default) or right.", table: "Automation")),
            .init(template: "rolltop://settings/<pane>", example: "rolltop://settings/integrations",
                  summary: String(localized: "Opens Rolltop’s settings.", table: "Automation"),
                  parameters: String(localized: "<pane> is optional: general, profiles, automations, integrations, backup…", table: "Automation")),
        ]
        if InteropLinkRoutes.paletteCommand(in: context.commands.commands.map(\.id)) != nil {
            list.insert(.init(template: "rolltop://search", example: "rolltop://search",
                              summary: String(localized: "Opens the search for menu bar items and commands.", table: "Automation"),
                              parameters: nil), at: 4)
        }
        return list
    }

    static let appleScriptExamples = [
        "tell application \"Rolltop\" to toggle hidden items",
        "tell application \"Rolltop\" to apply profile \"Work\"",
    ]

    static func outcomeTitle(_ entry: InteropLinkLogEntry) -> String {
        switch entry.outcome {
        case .ran, .allowedAfterAsking: String(localized: "Ran", table: "Automation")
        case .failed: String(localized: "Failed", table: "Automation")
        case .asked: String(localized: "Waiting for your answer", table: "Automation")
        case .refused, .dropped: String(localized: "Ignored", table: "Automation")
        }
    }
}
