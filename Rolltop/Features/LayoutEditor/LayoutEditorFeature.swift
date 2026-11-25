import Foundation
import RolltopCore

/// Settings › Menu Bar Items: the visual layout editor. Three shelves that look like the
/// menu bar (Shown, Hidden, Always Hidden) with drag and drop, a "New items" marker for
/// the default section, item details, and a list view as an alternative.
final class LayoutEditorFeature: FeatureModule {
    static let id: FeatureID = "layout-editor"
    static let paneID = "menu-bar-items"

    private unowned let context: AppContext
    private let state = LayoutEditorUIState()
    let order: LayoutEditorOrderModel

    init(context: AppContext) {
        self.context = context
        context.settings.markTransient(LayoutEditorSettings.viewMode)
        order = LayoutEditorOrderModel(orderAccess: LayoutEditorFileAccess(file: .layout, settings: context.settings),
                                       allowListAccess: LayoutEditorFileAccess(file: .allowList, settings: context.settings))
        order.drawnOrder = { [unowned context] in LayoutEditorDrawnOrder.owners(await context.catalog.refreshDrawn()) }
        order.nudge = { [unowned context] in context.services[.ownStatusItems].nudgeLayout() }
        registerConsents()
    }

    /// Two rows in Settings › Permissions. Status never touches the files; `request` and
    /// "Choose File…" run only from the rows' buttons. Allowing one may make the other
    /// work without a second dialog: its own button then returns at once.
    private func registerConsents() {
        let consents = context.services[.consents]
        for access in [order.orderAccess, order.allowListAccess] {
            let isOrder = access.file == .layout
            consents.register(ConsentItem(
                id: isOrder ? "layout-editor.order" : "layout-editor.turned-off-apps",
                title: isOrder ? LocalizedStringResource("Menu Bar Order", table: "LayoutEditor")
                    : LocalizedStringResource("Apps Turned Off in the Menu Bar", table: "LayoutEditor"),
                purpose: isOrder
                    ? LocalizedStringResource("Lets you reorder menu bar items in Settings › Menu Bar Items.", table: "LayoutEditor")
                    : LocalizedStringResource("Lists the apps you turned off in System Settings › Menu Bar. Rolltop only reads this list.",
                                              table: "LayoutEditor"),
                sortOrder: isOrder ? 200 : 210,
                status: { access.consentStatus },
                request: { [order] in
                    await access.request()
                    await order.reload()
                },
                settingsURL: nil,
                secondaryAction: ConsentSecondaryAction(title: LocalizedStringResource("Choose File…", table: "LayoutEditor")) { [order] in
                    await access.chooseFile()
                    await order.reload()
                }))
        }
    }

    var settingsPanes: [SettingsPane] {
        let context = context
        let state = state
        let order = order
        return [
            SettingsPane(id: Self.paneID, title: LocalizedStringResource("Menu Bar Items", table: "LayoutEditor"),
                         symbol: "menubar.rectangle", sortOrder: 110,
                         keywords: [LocalizedStringResource("items, icons, sections, shown, hidden, always hidden, apps, layout, arrange, drag, new items",
                                                            table: "LayoutEditor", comment: "Settings search keywords, comma separated")]) {
                LayoutEditorPane(context: context, state: state, order: order)
            },
        ]
    }

    var commands: [Command] {
        #if DEBUG
        LayoutEditorDebug.commands(context: context, state: state) + LayoutEditorOrderDebug.commands(context: context, order: order)
        #else
        []
        #endif
    }
}

#if DEBUG
/// Live tests cannot type or rely on pointer positions: these select, filter and dump the
/// editor, and put the layout back exactly as it was before a test changed the default
/// section (which freezes every present owner).
enum LayoutEditorDebug {
    struct Dump: Encodable {
        struct Item: Encodable {
            let id: String
            let name: String
            let section: String
            let explicit: Bool
            let itemCount: Int
            let drawState: String
            let notes: [String]
        }

        struct Shelf: Encodable {
            let section: String
            let items: [Item]
            let hasMarker: Bool
        }

        let writtenAt: Date
        let viewMode: String
        let selection: String?
        let query: String
        let defaultSection: String
        let drawnIsReadable: Bool
        let shelves: [Shelf]
        let notRunning: [String]
        let managed: [String]
        let unidentified: [String]
    }

    static let snapshotName = "layout-editor-layout-snapshot.json"

    static func commands(context: AppContext, state: LayoutEditorUIState) -> [Command] {
        [
            Command(id: "layout-editor.debug-dump", title: LocalizedStringResource("Dump Layout Editor State", table: "LayoutEditor"),
                    symbol: "ladybug", allowedFromURL: true) { _ in
                await context.catalog.refresh()
                try DebugFiles.writeJSON(dump(context: context, state: state), name: "layout-editor.json")
            },
            Command(id: "layout-editor.debug-select", title: LocalizedStringResource("Select Layout Editor Item", table: "LayoutEditor"),
                    symbol: "cursorarrow.rays",
                    arguments: [CommandArgument(name: "owner", title: LocalizedStringResource("Item", table: "LayoutEditor"), isRequired: false)],
                    allowedFromURL: true) { invocation in
                switch invocation.string("owner") {
                case nil, "": state.selection = nil
                case "marker": state.selection = .marker
                case let raw?:
                    guard let owner = OwnerID(stringValue: raw) else { throw CommandError.invalidArgument("owner", raw) }
                    state.selection = .owner(owner)
                }
            },
            Command(id: "layout-editor.debug-filter", title: LocalizedStringResource("Filter Layout Editor", table: "LayoutEditor"),
                    symbol: "line.3.horizontal.decrease",
                    arguments: [CommandArgument(name: "query", title: LocalizedStringResource("Text", table: "LayoutEditor"), isRequired: false)],
                    allowedFromURL: true) { invocation in
                state.query = invocation.string("query") ?? ""
            },
            Command(id: "layout-editor.debug-snapshot-layout", title: LocalizedStringResource("Save Layout Snapshot", table: "LayoutEditor"),
                    symbol: "square.and.arrow.down", allowedFromURL: true) { _ in
                try DebugFiles.writeJSON(context.layout.layout, name: snapshotName)
            },
            Command(id: "layout-editor.debug-restore-layout", title: LocalizedStringResource("Restore Layout Snapshot", table: "LayoutEditor"),
                    symbol: "arrow.uturn.backward", allowedFromURL: true) { _ in
                let data = try Data(contentsOf: DebugFiles.directory.appending(path: snapshotName))
                context.layout.replace(with: try JSONDecoder().decode(Layout.self, from: data))
            },
        ]
    }

    private static func dump(context: AppContext, state: LayoutEditorUIState) -> Dump {
        let board = LayoutEditorBoard.make(entries: context.catalog.entries, layout: context.layout.layout,
                                           drawn: context.catalog.drawn, name: { context.catalog.displayName(for: $0) })
        let visible = board.filtered(by: state.query)
        let selection: String? = switch state.selection {
        case nil: nil
        case .marker: "marker"
        case .owner(let owner): owner.stringValue
        }
        return Dump(
            writtenAt: Date(), viewMode: context.settings[LayoutEditorSettings.viewMode], selection: selection, query: state.query,
            defaultSection: board.defaultSection.rawValue, drawnIsReadable: board.drawnIsReadable,
            shelves: RolltopCore.Section.allCases.map { section in
                Dump.Shelf(section: section.rawValue, items: visible.clusters(in: section).map { cluster in
                    Dump.Item(id: cluster.id, name: cluster.name, section: cluster.section.rawValue, explicit: cluster.hasExplicitSection,
                              itemCount: cluster.itemCount, drawState: cluster.drawState.rawValue,
                              notes: cluster.notes.map { String(describing: $0) })
                }, hasMarker: board.defaultSection == section)
            },
            notRunning: visible.notRunning.map { "\($0.id)=\($0.section.rawValue)" },
            managed: visible.managed.map(\.id), unidentified: visible.unidentified.map(\.id))
    }
}
#endif
