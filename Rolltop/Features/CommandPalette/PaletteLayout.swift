import CoreGraphics
import Foundation

/// Sizes of the panel, close to Spotlight on macOS 27. Pure.
nonisolated struct PaletteMetrics: Sendable, Equatable {
    var width: CGFloat = 680
    var headerHeight: CGFloat = 56
    var rowHeight: CGFloat = 40
    /// Space above the first and below the last row.
    var listInset: CGFloat = 6
    /// Row highlights are inset this far from the panel's sides.
    var horizontalInset: CGFloat = 8
    var footerHeight: CGFloat = 30
    var maxVisibleRows = 8
    var cornerRadius: CGFloat = 24

    /// Concentric with the panel: the outer radius minus the inset.
    var rowCornerRadius: CGFloat { cornerRadius - horizontalInset }

    /// Rows that fit without scrolling (at least one line for "No results").
    func visibleRows(for count: Int) -> Int { max(1, min(count, maxVisibleRows)) }

    func listHeight(rowCount: Int) -> CGFloat { listInset * 2 + CGFloat(visibleRows(for: rowCount)) * rowHeight }

    func panelHeight(rowCount: Int) -> CGFloat { headerHeight + 1 + listHeight(rowCount: rowCount) + footerHeight }

    var maxPanelHeight: CGFloat { panelHeight(rowCount: maxVisibleRows) }
}

/// Where the panel goes: horizontally centred on the screen, its top edge in the upper
/// third; it grows downwards. Pure; AppKit coordinates (bottom-left origin).
nonisolated enum PalettePlacement {
    /// The top edge sits this fraction of the visible height below the top.
    static let topFraction: CGFloat = 0.2
    static let margin: CGFloat = 16

    static func frame(height: CGFloat, width: CGFloat, maxHeight: CGFloat, visibleFrame: CGRect) -> CGRect {
        let usableWidth = min(width, visibleFrame.width - 2 * margin)
        let x = (visibleFrame.midX - usableWidth / 2).rounded()
        var top = visibleFrame.maxY - (visibleFrame.height * topFraction).rounded()
        // Keep the tallest panel on screen so the top edge never moves while results change.
        top = max(top, visibleFrame.minY + margin + maxHeight)
        top = min(top, visibleFrame.maxY - margin)
        return CGRect(x: x, y: top - height, width: usableWidth, height: height)
    }
}

/// Scroll position of the result list. Pure; offsets in points from the first row.
nonisolated struct PaletteScroll: Sendable, Equatable {
    var offset: CGFloat = 0

    static func maxOffset(rowCount: Int, metrics: PaletteMetrics) -> CGFloat {
        max(0, CGFloat(rowCount - metrics.visibleRows(for: rowCount)) * metrics.rowHeight)
    }

    mutating func clamp(rowCount: Int, metrics: PaletteMetrics) {
        offset = min(max(0, offset), Self.maxOffset(rowCount: rowCount, metrics: metrics))
    }

    /// Scrolls the least amount that shows the row entirely.
    mutating func reveal(row: Int, rowCount: Int, metrics: PaletteMetrics) {
        let top = CGFloat(row) * metrics.rowHeight
        let bottom = top + metrics.rowHeight
        let height = CGFloat(metrics.visibleRows(for: rowCount)) * metrics.rowHeight
        if top < offset { offset = top } else if bottom > offset + height { offset = bottom - height }
        clamp(rowCount: rowCount, metrics: metrics)
    }

    /// The row under a point `y` measured from the top of the list area (including the inset).
    func row(atListY y: CGFloat, rowCount: Int, metrics: PaletteMetrics) -> Int? {
        let inRows = y - metrics.listInset
        guard inRows >= 0, inRows < CGFloat(metrics.visibleRows(for: rowCount)) * metrics.rowHeight else { return nil }
        let index = Int(((inRows + offset) / metrics.rowHeight).rounded(.down))
        return index < rowCount ? index : nil
    }
}
