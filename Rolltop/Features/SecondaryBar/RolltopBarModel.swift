import AppKit
import Observation
import RolltopCore

/// What the Rolltop Bar shows and its interaction state.
@Observable
final class RolltopBarModel {
    enum CellKind: Equatable {
        case item(Item)
        case separator
        case disclosure
        case empty
    }

    struct Item: Identifiable, Equatable {
        /// `owner#index`.
        let id: String
        let owner: OwnerID
        let index: Int
        let name: String
        let isAlwaysHidden: Bool
        var image: NSImage?

        static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.id == rhs.id && lhs.name == rhs.name && lhs.isAlwaysHidden == rhs.isAlwaysHidden && lhs.image === rhs.image
        }
    }

    struct Cell: Identifiable, Equatable {
        let id: String
        let kind: CellKind
        let frame: CGRect
    }

    var cells: [Cell] = []
    var size: CGSize = .zero
    var cornerRadius: CGFloat = 17
    var metrics = RolltopBarMetrics()
    var isExpanded = false
    var hasDisclosure = false
    /// Cell id under the pointer.
    var hovered: String?
    /// Cell id pressed (mouse down inside, not yet released).
    var pressed: String?
    /// Keyboard selection (keyboard mode only).
    var selected: String?
    var isKeyboardMode = false
    /// Item whose activation is in flight.
    var busy: String?
    /// Item whose activation just failed (briefly).
    var failed: String?

    var items: [Item] {
        cells.compactMap { if case .item(let item) = $0.kind { item } else { nil } }
    }

    func cell(at point: CGPoint) -> Cell? {
        cells.first { $0.frame.insetBy(dx: -metrics.spacing / 2, dy: -metrics.rowSpacing / 2).contains(point) && $0.kind != .separator && $0.kind != .empty }
    }

    /// Selectable cells (items and the disclosure) in reading order.
    var selectableIDs: [String] {
        cells.filter { if case .item = $0.kind { true } else { $0.kind == .disclosure } }.map(\.id)
    }

    /// Keyboard navigation: left/right step through cells, up/down jump a row keeping x.
    func moveSelection(_ direction: KeyboardMove) {
        let ids = selectableIDs
        guard !ids.isEmpty else { return }
        guard let current = selected, let index = ids.firstIndex(of: current) else {
            selected = ids.first
            return
        }
        switch direction {
        case .left: selected = ids[max(0, index - 1)]
        case .right: selected = ids[min(ids.count - 1, index + 1)]
        case .up, .down:
            guard let frame = cells.first(where: { $0.id == current })?.frame else { return }
            let rowStep = metrics.rowHeight + metrics.rowSpacing
            let targetY = frame.midY + (direction == .down ? rowStep : -rowStep)
            let candidates = cells.filter { ids.contains($0.id) && abs($0.frame.midY - targetY) < 1 }
            if let nearest = candidates.min(by: { abs($0.frame.midX - frame.midX) < abs($1.frame.midX - frame.midX) }) {
                selected = nearest.id
            }
        }
    }

    enum KeyboardMove {
        case left, right, up, down
    }
}
