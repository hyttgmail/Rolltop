import Observation
import SwiftUI

/// A page of the settings window, contributed by a feature. The SettingsShell feature
/// renders `SettingsPaneRegistry.panes` as the sidebar, sorted by `sortOrder` then title.
struct SettingsPane: Identifiable {
    let id: String
    let title: LocalizedStringResource
    /// SF Symbol name for the sidebar.
    let symbol: String
    /// Lower first. Ranges: 0–99 general, 100–199 menu bar items, 200–299 behaviour,
    /// 300–399 appearance, 400–499 automation, 900+ about/advanced.
    let sortOrder: Int
    /// Extra words the settings search matches besides the title: what the pane controls,
    /// in the user's words ("login", "hover", "shortcut"). Localized in the feature's table.
    let keywords: [LocalizedStringResource]
    let makeView: () -> AnyView

    init<Content: View>(id: String, title: LocalizedStringResource, symbol: String, sortOrder: Int,
                        keywords: [LocalizedStringResource] = [], @ViewBuilder content: @escaping () -> Content) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.sortOrder = sortOrder
        self.keywords = keywords
        self.makeView = { AnyView(content()) }
    }
}

/// A section one feature adds to another feature's pane (Capture's "Item images" in the
/// Rolltop Bar pane). The host pane places `ContributedSettingsSections(paneID:registry:)`
/// inside its `Form` where contributed sections belong.
struct SettingsPaneSection: Identifiable {
    /// `<feature-id>.<name>`.
    let id: String
    /// The host pane.
    let paneID: String
    /// Lower first among the sections contributed to the same pane.
    let sortOrder: Int
    /// Added to the host pane's search keywords.
    let keywords: [LocalizedStringResource]
    let makeView: () -> AnyView

    init<Content: View>(id: String, paneID: String, sortOrder: Int, keywords: [LocalizedStringResource] = [],
                        @ViewBuilder content: @escaping () -> Content) {
        self.id = id
        self.paneID = paneID
        self.sortOrder = sortOrder
        self.keywords = keywords
        self.makeView = { AnyView(content()) }
    }
}

@Observable
final class SettingsPaneRegistry {
    private(set) var panes: [SettingsPane] = []
    private(set) var sections: [SettingsPaneSection] = []

    /// Registers or replaces a pane with the same id; keeps the list sorted.
    func register(_ pane: SettingsPane) {
        panes.removeAll { $0.id == pane.id }
        panes.append(pane)
        panes.sort { ($0.sortOrder, String(localized: $0.title)) < ($1.sortOrder, String(localized: $1.title)) }
    }

    /// Registers or replaces a contributed section with the same id.
    func register(section: SettingsPaneSection) {
        sections.removeAll { $0.id == section.id }
        sections.append(section)
        sections.sort { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
    }

    func pane(_ id: String) -> SettingsPane? { panes.first { $0.id == id } }

    func sections(for paneID: String) -> [SettingsPaneSection] { sections.filter { $0.paneID == paneID } }

    /// The pane's own keywords plus those of the sections contributed to it.
    func keywords(for paneID: String) -> [LocalizedStringResource] {
        (pane(paneID)?.keywords ?? []) + sections(for: paneID).flatMap(\.keywords)
    }
}

/// The sections other features contributed to a pane, in order. Place it inside the
/// host pane's `Form`.
struct ContributedSettingsSections: View {
    let paneID: String
    let registry: SettingsPaneRegistry

    var body: some View {
        ForEach(registry.sections(for: paneID)) { section in
            section.makeView()
        }
    }
}
