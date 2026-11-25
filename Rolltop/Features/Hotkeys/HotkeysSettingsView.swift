import AppKit
import RolltopCore
import SwiftUI

/// Settings pane "Shortcuts" (id `hotkeys`): a recorder for every command, and shortcuts
/// that show a menu bar item and click it.
struct HotkeysSettingsView: View {
    let context: AppContext
    let controller: HotkeyController

    @State private var filter = ""
    @State private var newOwner = ""
    @State private var newButton: ItemActivator.Button = .left

    var body: some View {
        let _ = controller.revision
        Form {
            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(text: $filter, prompt: Text("Filter shortcuts", tableName: "Hotkeys")) {
                        Text("Filter shortcuts", tableName: "Hotkeys")
                    }
                    .labelsHidden()
                    .textFieldStyle(.plain)
                }
            } footer: {
                Text("Shortcuts work in every app. One that macOS also uses is marked and stays off; Rolltop cannot see shortcuts other apps use.",
                     tableName: "Hotkeys")
            }
            commandSections
            itemsSection
        }
        .formStyle(.grouped)
    }

    // MARK: Commands

    /// Bindable commands, grouped by the feature that owns them (headed by its settings
    /// pane's title), in sidebar order; Rolltop's own commands first.
    private var commandGroups: [HotkeysCommandGroup] {
        let commands = context.commands.commands
            .filter { Self.isBindable($0) && (($0.isAvailable?() ?? true) || controller.bindings[HotkeyAction($0.id)] != nil) }
            .filter { matches(title: $0.localizedTitle, action: HotkeyAction($0.id)) }
        return HotkeysCommandGroup.groups(commands.map { ($0.id, $0.featurePrefix.description, $0.localizedTitle) },
                                          panes: context.settingsPanes.panes.map { ($0.id, $0.sortOrder) })
    }

    @ViewBuilder
    private var commandSections: some View {
        let groups = commandGroups
        if groups.isEmpty {
            Section {
                Text("No matching commands", tableName: "Hotkeys").foregroundStyle(.secondary)
            } header: {
                Text("Commands", tableName: "Hotkeys")
            }
        }
        ForEach(groups, id: \.key) { group in
            Section {
                ForEach(group.commandIDs, id: \.self) { id in
                    if let command = context.commands.command(id) {
                        LabeledContent {
                            HotkeyRecorderField(context: context, action: HotkeyAction(command.id))
                        } label: {
                            Label { Text(command.title) } icon: { Image(systemName: command.symbol).frame(width: 22) }
                        }
                    }
                }
            } header: {
                header(for: group.key)
            }
        }
    }

    private func header(for key: String) -> Text {
        switch key {
        case HotkeysCommandGroup.general: Text("General", tableName: "Hotkeys")
        case HotkeysCommandGroup.other: Text("Other", tableName: "Hotkeys")
        default: context.settingsPanes.pane(key).map { Text($0.title) } ?? Text(verbatim: key)
        }
    }

    /// Commands that need no further arguments; Debug hooks stay out of the list.
    static func isBindable(_ command: Command) -> Bool {
        guard !command.id.isDebugOnly else { return false }
        return command.arguments.allSatisfy { !$0.isRequired }
    }

    // MARK: Items

    private var itemRows: [HotkeyAction] {
        controller.itemActions.filter { matches(title: controller.title(for: $0), action: $0) }
    }

    private var itemChoices: [CatalogEntry] {
        context.catalog.entries
            .filter { $0.owner != nil && !$0.isOwn }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var itemsSection: some View {
        Section {
            ForEach(itemRows, id: \.self) { action in
                LabeledContent {
                    HStack(alignment: .top) {
                        HotkeyRecorderField(context: context, action: action)
                        Button { controller.removeRow(action) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(Text("Remove this shortcut", tableName: "Hotkeys"))
                    }
                } label: {
                    Label { Text(controller.title(for: action)) } icon: { icon(for: action.arguments["owner"]) }
                }
            }
            HStack {
                Picker(selection: $newOwner) {
                    Text("Choose an item", tableName: "Hotkeys").tag("")
                    ForEach(itemChoices, id: \.id) { entry in
                        if let owner = entry.owner {
                            Label { Text(entry.displayName) } icon: { icon(for: owner.stringValue) }
                                .labelStyle(.titleAndIcon)
                                .tag(owner.stringValue)
                        }
                    }
                } label: {
                    Text("Item", tableName: "Hotkeys")
                }
                Picker(selection: $newButton) {
                    Text("Show and click", tableName: "Hotkeys").tag(ItemActivator.Button.left)
                    Text("Show and right-click", tableName: "Hotkeys").tag(ItemActivator.Button.right)
                } label: {
                    Text("Action", tableName: "Hotkeys")
                }
                .labelsHidden()
                .fixedSize()
                Button {
                    guard let owner = OwnerID(stringValue: newOwner) else { return }
                    controller.addItemRow(HotkeyController.itemAction(owner: owner, button: newButton))
                    newOwner = ""
                } label: {
                    Text("Add", tableName: "Hotkeys")
                }
                .disabled(OwnerID(stringValue: newOwner) == nil)
            }
        } header: {
            Text("Menu bar items", tableName: "Hotkeys")
        } footer: {
            Text("Shows the item for a moment if it is hidden, then clicks it. Needs Device Control and Data Access.", tableName: "Hotkeys")
        }
    }

    // MARK: Helpers

    private func matches(title: String, action: HotkeyAction) -> Bool {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        if title.localizedCaseInsensitiveContains(needle) || action.command.rawValue.localizedCaseInsensitiveContains(needle) { return true }
        if let combo = controller.bindings[action]?.combo { return KeyComboFormatter.string(for: combo).localizedCaseInsensitiveContains(needle) }
        return false
    }

    @ViewBuilder
    private func icon(for ownerString: String?) -> some View {
        if let raw = ownerString, let owner = OwnerID(stringValue: raw),
           let image = context.services[.itemImages].image(for: owner, itemIndex: 0, height: 16) {
            Image(nsImage: image).renderingMode(image.isTemplate ? .template : .original)
        } else {
            Image(systemName: "menubar.rectangle")
        }
    }
}

/// One section of the Shortcuts pane: the commands of one feature. Pure, testable.
nonisolated struct HotkeysCommandGroup: Equatable, Sendable {
    /// Rolltop's core commands (showing items, settings, quit).
    static let general = "general"
    /// Commands of a feature without a settings pane of its own.
    static let other = "other"
    static let coreAreas: Set<String> = ["visibility", "layout", "item", "app"]

    /// `general`, `other`, or the id of the pane that heads the group.
    let key: String
    let commandIDs: [CommandID]

    /// `commands`: id, feature prefix, title. A feature's group is headed by the pane whose id
    /// is the feature id; groups follow the panes' sort order, General first, Other last;
    /// commands inside a group by title.
    static func groups(_ commands: [(id: CommandID, feature: String, title: String)],
                       panes: [(id: String, sortOrder: Int)]) -> [HotkeysCommandGroup] {
        let paneOrder = Dictionary(panes.map { ($0.id, $0.sortOrder) }, uniquingKeysWith: { first, _ in first })
        func key(_ feature: String) -> String {
            if coreAreas.contains(feature) { return general }
            return paneOrder[feature] == nil ? other : feature
        }
        func rank(_ key: String) -> Int {
            switch key {
            case general: Int.min
            case other: Int.max
            default: paneOrder[key] ?? Int.max - 1
            }
        }
        let grouped = Dictionary(grouping: commands, by: { key($0.feature) })
        return grouped.keys.sorted { (rank($0), $0) < (rank($1), $1) }.map { key in
            let sorted = (grouped[key] ?? []).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return HotkeysCommandGroup(key: key, commandIDs: sorted.map(\.id))
        }
    }
}
