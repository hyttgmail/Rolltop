import Observation
import SwiftUI

/// What the settings window shows: the selected pane and the sidebar search text.
@Observable
final class SettingsNavigation {
    var selection: String?
    var query = ""
}

/// Sidebar of contributed panes plus the selected pane, like System Settings: fixed
/// sidebar without a collapse toggle, a search field on top, unobtrusive group spacing.
struct SettingsRootView: View {
    let registry: SettingsPaneRegistry
    @Bindable var navigation: SettingsNavigation

    static let sidebarWidth: CGFloat = 210

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
                .navigationSplitViewColumnWidth(min: Self.sidebarWidth, ideal: Self.sidebarWidth, max: Self.sidebarWidth)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var items: [SidebarItem] {
        registry.panes.map { pane in
            SidebarItem(id: pane.id, title: String(localized: pane.title), sortOrder: pane.sortOrder,
                        keywords: registry.keywords(for: pane.id).map { String(localized: $0) })
        }
    }

    private var sidebar: some View {
        let groups = SettingsSidebar.groups(SettingsSidebar.filter(items, query: navigation.query))
        return List(selection: $navigation.selection) {
            ForEach(groups, id: \.first?.id) { group in
                Section {
                    ForEach(group, id: \.id) { item in
                        if let pane = registry.pane(item.id) {
                            Label {
                                Text(pane.title)
                            } icon: {
                                Image(systemName: pane.symbol)
                            }
                            .tag(pane.id)
                            .accessibilityIdentifier("sidebar.\(pane.id)")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $navigation.query, placement: .sidebar, prompt: Text("Search", tableName: "SettingsShell"))
        .overlay {
            if groups.isEmpty {
                Text("No results", tableName: "SettingsShell")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = navigation.selection, let pane = registry.pane(id) {
            pane.makeView()
                .id(pane.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            Text("Select a category", tableName: "SettingsShell")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
