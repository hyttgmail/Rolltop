import Foundation
import Observation
import RolltopCore

/// The persisted section layout (`rolltop.layout`). Every mutation is saved at once.
@Observable
final class LayoutStore {
    private(set) var layout: Layout
    @ObservationIgnored private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
        self.layout = settings[CoreSettings.layout]
    }

    func section(for owner: OwnerID) -> Section { layout.section(for: owner) }

    /// Sets an explicit section; nil removes the entry so the owner follows the default.
    func setSection(_ section: Section?, for owner: OwnerID) {
        update { $0.setSection(section, for: owner) }
    }

    /// Changes the section for owners seen from now on. `freezing` owners (typically the
    /// catalog's present owners) first get their current section written explicitly, so
    /// items already in the bar stay where they are.
    func setDefaultSection(_ section: Section, freezing owners: Set<OwnerID> = []) {
        update { layout in
            layout = layout.freezingSections(of: owners)
            layout.defaultSection = section
        }
    }

    /// Atomic replacement (profiles, import, reset).
    func replace(with newLayout: Layout) {
        guard newLayout != layout else { return }
        layout = newLayout
        settings[CoreSettings.layout] = newLayout
    }

    func update(_ body: (inout Layout) -> Void) {
        var copy = layout
        body(&copy)
        replace(with: copy)
    }
}
