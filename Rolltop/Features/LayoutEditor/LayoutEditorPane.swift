import RolltopCore
import SwiftUI

/// Settings › Menu Bar Items: three shelves that look like the menu bar (or a list), item
/// details, the groups Rolltop cannot assign, and the limits macOS 27 imposes.
struct LayoutEditorPane: View {
    let context: AppContext
    @Bindable var state: LayoutEditorUIState
    let order: LayoutEditorOrderModel

    @FocusState private var focusedShelf: RolltopCore.Section?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var limitsExpanded = false

    var body: some View {
        let board = LayoutEditorBoard.make(entries: context.catalog.entries, layout: context.layout.layout,
                                           drawn: context.catalog.drawn, name: { context.catalog.displayName(for: $0) })
        let visible = board.filtered(by: state.query)
        let mode = viewMode.wrappedValue
        Form {
            if !context.permissions.accessibility {
                SwiftUI.Section {
                    LimitationNote(text: Text("Rolltop needs Device Control and Data Access to see the items in your menu bar.", tableName: "LayoutEditor"),
                                   tone: .warning) {
                        Button {
                            context.services[.settingsWindow].showSettings(paneID: "permissions")
                        } label: {
                            Text("Open Permissions", tableName: "LayoutEditor")
                        }
                    }
                }
            }
            controls
            LayoutEditorOrderNotes(context: context, order: order, showsAccess: mode == .shelves)
            switch mode {
            case .shelves:
                ForEach(RolltopCore.Section.allCases, id: \.self) { section in
                    shelfSection(section, board: visible)
                }
                if !visible.noted.isEmpty {
                    notesSection(visible.noted)
                }
            case .list:
                LayoutEditorListSections(context: context, board: visible, isFiltering: !state.query.isEmpty, actions: actions)
            }
            LayoutEditorTurnedOffSection(context: context, order: order)
            LayoutEditorGroups(context: context, board: visible, actions: actions)
            ContributedSettingsSections(paneID: LayoutEditorFeature.paneID, registry: context.settingsPanes)
            limitsSection
        }
        .formStyle(.grouped)
        // The files have no change notification: read when the editor appears (only the
        // ones the user allowed; nothing is touched before that).
        .task { await order.reload() }
        .onChange(of: board) { _, newBoard in
            let surviving = LayoutEditorSelection.surviving(state.selection, in: newBoard)
            if surviving != state.selection { state.selection = surviving }
        }
    }

    // MARK: Controls

    private var viewMode: Binding<LayoutEditorViewMode> {
        Binding {
            LayoutEditorViewMode(rawValue: context.settings[LayoutEditorSettings.viewMode]) ?? .shelves
        } set: { mode in
            context.settings[LayoutEditorSettings.viewMode] = mode.rawValue
        }
    }

    /// The preview follows the live presentation level, so a rehide elsewhere turns it off.
    /// `visibility.show-all` always reveals in the menu bar (never in the Rolltop Bar).
    private var preview: Binding<Bool> {
        Binding {
            context.visibility.level == .allRevealed
        } set: { on in
            let command: CommandID = on ? .showAll : .collapse
            context.commands.runDetached(command, source: .internal)
        }
    }

    private var controls: some View {
        SwiftUI.Section {
            Picker(selection: viewMode) {
                Text("Columns", tableName: "LayoutEditor").tag(LayoutEditorViewMode.shelves)
                Text("List", tableName: "LayoutEditor").tag(LayoutEditorViewMode.list)
            } label: {
                Text("View", tableName: "LayoutEditor")
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityIdentifier("layout-editor.view-mode")
            Toggle(isOn: preview) {
                Text("Show hidden items in the menu bar", tableName: "LayoutEditor")
                Text("Reveals hidden and always-hidden items while you arrange, until you turn this off or Rolltop hides them again.",
                     tableName: "LayoutEditor")
            }
            .accessibilityIdentifier("layout-editor.preview")
            LayoutEditorFilterField(query: $state.query)
        } footer: {
            Group {
                if order.canReorder {
                    Text("Items appear in menu bar order, left to right. Drop an item on another one in the same row to put it there, or hold ⌘ and drag icons in the menu bar itself.",
                         tableName: "LayoutEditor")
                } else {
                    Text("Items appear in menu bar order, left to right. Rolltop can’t change the order: hold ⌘ and drag icons in the menu bar itself.",
                         tableName: "LayoutEditor")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Shelves

    private func shelfSection(_ section: RolltopCore.Section, board: LayoutEditorBoard) -> some View {
        let clusters = board.clusters(in: section)
        let count = clusters.count { $0.isMovable }
        let inPanel = context.services[.revealRouting].presentsHiddenInPanel
        return SwiftUI.Section {
            LayoutEditorShelf(section: section, clusters: clusters, showsMarker: board.defaultSection == section,
                              isFiltering: !state.query.isEmpty, selection: state.selection, services: context.services,
                              actions: actions)
                .focusable()
                .focused($focusedShelf, equals: section)
                .onMoveCommand { direction in
                    moveSelection(direction, board: board, shelf: section)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(verbatim: OwnerNames.sectionTitle(section)))
                .accessibilityIdentifier("layout-editor.shelf.\(section.rawValue)")
            // Details sit right under the shelf of the selection, next to the click.
            if LayoutEditorSelection.shelf(of: state.selection, in: board) == section {
                LayoutEditorDetails(context: context, state: state, board: board, actions: actions)
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: OwnerNames.sectionTitle(section))
                Text(verbatim: count.formatted())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(verbatim: LayoutEditorText.shelfCount(count)))
            }
        } footer: {
            Text(verbatim: LayoutEditorText.shelfDescription(section, inPanel: inPanel))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection, board: LayoutEditorBoard, shelf: RolltopCore.Section) {
        let mapped: LayoutEditorSelection.Direction
        switch direction {
        case .left: mapped = .left
        case .right: mapped = .right
        case .up: mapped = .up
        case .down: mapped = .down
        @unknown default: return
        }
        let next = LayoutEditorSelection.moved(state.selection, mapped, in: board, focusedShelf: shelf)
        guard next != state.selection else { return }
        select(next)
        if let shelf = LayoutEditorSelection.shelf(of: next, in: board) { focusedShelf = shelf }
    }

    private func notesSection(_ clusters: [LayoutEditorCluster]) -> some View {
        SwiftUI.Section {
            ForEach(clusters) { cluster in
                OwnerLabel(owner: cluster.owner, name: cluster.name,
                           notes: cluster.warnings.map(LayoutEditorText.note(for:)), services: context.services)
                    .contentShape(Rectangle())
                    .onTapGesture { select(.owner(cluster.owner)) }
            }
        } header: {
            Text("Notes", tableName: "LayoutEditor")
        }
    }

    // MARK: Limits

    private var limitsSection: some View {
        SwiftUI.Section {
            DisclosureGroup(isExpanded: $limitsExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(LayoutEditorText.limits, id: \.self) { limit in
                        Label {
                            Text(verbatim: limit)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                // The whole title toggles, like System Settings' disclosure rows.
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { limitsExpanded.toggle() }
                } label: {
                    Text("What macOS 27 doesn’t allow", tableName: "LayoutEditor")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("layout-editor.limits-title")
            }
            .accessibilityIdentifier("layout-editor.limits")
        }
    }

    // MARK: Actions

    private var actions: LayoutEditorShelfActions {
        LayoutEditorShelfActions(
            select: { select($0) },
            place: { payload, section in place(payload, on: section) },
            reorder: { owner, target in reorder(owner, before: target) },
            showNow: { owner in showNow(owner) },
            canShowNow: { cluster in canShowNow(cluster) },
            openShortcuts: { openShortcuts() })
    }

    private func select(_ selection: LayoutEditorSelection?) {
        state.selection = selection
        state.activationError = nil
        // A click on a chip gives its shelf the keyboard, so the arrows continue from there.
        switch selection {
        case .marker:
            focusedShelf = context.layout.layout.defaultSection
        case .owner(let owner) where context.catalog.entry(for: owner) != nil:
            let isOwn = owner.bundleID.map(context.ownBundleIDs.contains) ?? false
            focusedShelf = isOwn ? .shown : context.layout.section(for: owner)
        default:
            break
        }
    }

    private func place(_ payload: LayoutEditorPayload, on section: RolltopCore.Section) {
        let edit = LayoutEditorDrop.edit(dropping: payload, on: section, layout: context.layout.layout,
                                         presentOwners: context.catalog.presentOwners,
                                         ownOwners: Set(context.ownBundleIDs.map(OwnerID.app)))
        if edit != .none {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                switch edit {
                case .none:
                    break
                case .setSection(let owner, let section):
                    context.layout.setSection(section, for: owner)
                case .setDefaultSection(let section, let owners):
                    context.layout.setDefaultSection(section, freezing: owners)
                }
            }
        }
        // The moved thing stays selected (and its new shelf focused).
        switch payload {
        case .owner(let owner): select(.owner(owner))
        case .marker: select(.marker)
        }
    }

    /// A chip dropped on another chip of the same shelf: changes the menu bar order once
    /// order access works and both are in the bar now. Returns false otherwise (the drop
    /// then means "change section", as on the shelf).
    private func reorder(_ owner: OwnerID, before target: OwnerID) -> Bool {
        guard order.canReorder, !order.isWriting, owner != target,
              context.layout.section(for: owner) == context.layout.section(for: target),
              !MenuBarOrderKeys.isFixed(owner), context.catalog.isDrawn(owner), context.catalog.isDrawn(target) else { return false }
        select(.owner(owner))
        Task { await order.move(owner, before: target) }
        return true
    }

    private func canShowNow(_ cluster: LayoutEditorCluster) -> Bool {
        !cluster.isOwn && context.permissions.accessibility && !context.activator.isBusy
    }

    private func showNow(_ owner: OwnerID) {
        state.activationError = nil
        Task {
            do {
                _ = try await context.activator.activate(owner, button: .left)
            } catch {
                state.activationError = LayoutEditorText.activationError(error)
            }
        }
    }

    private func openShortcuts() {
        context.commands.runDetached(.openSettings, arguments: ["pane": "hotkeys"], source: .internal)
    }
}

// MARK: - Filter field

/// A search-style field that narrows every group to matching items.
struct LayoutEditorFilterField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(text: $query, prompt: Text("Filter items", tableName: "LayoutEditor")) {
                Text("Filter items", tableName: "LayoutEditor")
            }
            .textFieldStyle(.plain)
            .labelsHidden()
            .accessibilityIdentifier("layout-editor.filter")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear filter", tableName: "LayoutEditor"))
            }
        }
    }
}
