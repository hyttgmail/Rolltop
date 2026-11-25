import Foundation
import Observation

/// What the panel shows. The controller fills it; the views and the input view read it.
@Observable
final class PaletteModel {
    private(set) var results: [PaletteRow] = []
    /// How each result matched (nil before anything is typed); for the debug dump.
    @ObservationIgnored private(set) var tiers: [PaletteMatchTier?] = []
    /// Index into `results`; nil when there are none.
    private(set) var selected: Int?
    var hovered: Int?
    var pressed: Int?
    var scroll = PaletteScroll()
    var metrics = PaletteMetrics()
    var query = ""
    /// A short note in the footer when a run failed while the panel stayed open.
    var message: String?
    /// "⌃⌥Space" when the user assigned a shortcut to the palette, nil otherwise.
    var shortcut: String?

    func setResults(_ rows: [PaletteRow], tiers: [PaletteMatchTier?], keepingSelection: Bool) {
        let previousID = keepingSelection ? selected.flatMap { results.indices.contains($0) ? results[$0].id : nil } : nil
        results = rows
        self.tiers = tiers
        hovered = nil
        pressed = nil
        if let previousID, let index = rows.firstIndex(where: { $0.id == previousID }) {
            selected = index
        } else {
            selected = rows.isEmpty ? nil : 0
            scroll.offset = 0
        }
        scroll.clamp(rowCount: rows.count, metrics: metrics)
        if let selected { scroll.reveal(row: selected, rowCount: rows.count, metrics: metrics) }
    }

    /// Moves the selection, stopping at either end, and scrolls it into view.
    func move(by delta: Int) {
        guard !results.isEmpty else { return }
        let current = selected ?? (delta > 0 ? -1 : results.count)
        let next = min(max(0, current + delta), results.count - 1)
        selected = next
        scroll.reveal(row: next, rowCount: results.count, metrics: metrics)
    }

    func select(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selected = index
        scroll.reveal(row: index, rowCount: results.count, metrics: metrics)
    }

    func scroll(by delta: CGFloat) {
        scroll.offset += delta
        scroll.clamp(rowCount: results.count, metrics: metrics)
    }

    var selectedRow: PaletteRow? { selected.flatMap { results.indices.contains($0) ? results[$0] : nil } }

    /// The footer's "⌘↩ <title>" hint: the selected row's second action, nil when it has none.
    var secondActionTitle: String? { selectedRow?.secondAction?.title }

    var panelHeight: CGFloat { metrics.panelHeight(rowCount: results.count) }
}
