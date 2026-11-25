import CoreGraphics
import Foundation

/// Sizes of the Rolltop Bar's parts.
nonisolated struct RolltopBarMetrics: Sendable, Equatable {
    var rowHeight: CGFloat = 24
    var imageHeight: CGFloat = 18
    /// Horizontal padding on each side of an item image.
    var itemPadding: CGFloat = 6
    var minItemWidth: CGFloat = 28
    var spacing: CGFloat = 2
    var rowSpacing: CGFloat = 2
    /// Between the glass edge and the items.
    var inset: CGFloat = 5
    var disclosureWidth: CGFloat = 22
    /// Between the menu bar and the panel.
    var gap: CGFloat = 5
    /// Between the panel and the screen edges / notch.
    var screenMargin: CGFloat = 8

    init(size: RolltopBarItemSize = .regular) {
        rowHeight = size.rowHeight
        imageHeight = size.imageHeight
    }

    func cellWidth(imageWidth: CGFloat) -> CGFloat { max(minItemWidth, (imageWidth + itemPadding * 2).rounded()) }

    /// Corner radius of the glass: a capsule for one row, concentric with the item
    /// highlights (radius `rowHeight / 2`, inset by `inset`) for several.
    func cornerRadius(rows: Int, height: CGFloat) -> CGFloat {
        rows <= 1 ? height / 2 : rowHeight / 2 + inset
    }
}

/// Cells laid out in rows (left to right, wrapping to the next row) inside the panel.
nonisolated struct RolltopBarLayout: Sendable, Equatable {
    /// Cell frames in panel content coordinates, top-left origin, in input order.
    var cellFrames: [CGRect]
    var rowCount: Int
    var size: CGSize

    static func compute(cellWidths: [CGFloat], maxWidth: CGFloat, metrics: RolltopBarMetrics) -> RolltopBarLayout {
        let available = max(metrics.minItemWidth, maxWidth - metrics.inset * 2)
        var frames: [CGRect] = []
        var x: CGFloat = 0, row = 0, widest: CGFloat = 0
        for width in cellWidths {
            if x > 0, x + metrics.spacing + width > available {
                row += 1
                x = 0
            }
            if x > 0 { x += metrics.spacing }
            let y = CGFloat(row) * (metrics.rowHeight + metrics.rowSpacing)
            frames.append(CGRect(x: metrics.inset + x, y: metrics.inset + y, width: width, height: metrics.rowHeight))
            x += width
            widest = max(widest, x)
        }
        let rows = cellWidths.isEmpty ? 1 : row + 1
        let height = CGFloat(rows) * metrics.rowHeight + CGFloat(rows - 1) * metrics.rowSpacing + metrics.inset * 2
        let width = max(widest, metrics.minItemWidth) + metrics.inset * 2
        return RolltopBarLayout(cellFrames: frames, rowCount: rows, size: CGSize(width: width, height: height))
    }
}

/// Where the panel goes. Pure: inputs are plain geometry in global AppKit coordinates.
nonisolated enum RolltopBarPlacement {
    struct Screen: Sendable, Equatable {
        var frame: CGRect
        var visibleFrame: CGRect
        /// `safeAreaInsets.top` (the notch height), 0 without a notch.
        var safeAreaTop: CGFloat = 0
        /// The camera housing between `auxiliaryTopLeftArea` and `auxiliaryTopRightArea`.
        var notch: ClosedRange<CGFloat>?

        /// Height of the menu bar strip; when the bar is hidden (full screen, auto-hide)
        /// the panel still clears the area it appears in.
        var menuBarHeight: CGFloat {
            let strip = frame.maxY - visibleFrame.maxY
            return strip > 0 ? strip : max(safeAreaTop, 24)
        }
    }

    /// Where the panel's trailing edge should be.
    enum Trailing: Sendable, Equatable {
        /// Under Rolltop's status item (its frame).
        case item(CGRect)
        /// Under the pointer.
        case pointer(CGFloat)
        /// Rolltop's item is not drawn or overflowed: the trailing end of the bar.
        case screenEdge
    }

    /// The horizontal range the panel may use on `screen` for an anchor at `anchorX`:
    /// inside the margins and never under the notch (the side of the notch the anchor is on).
    static func allowedRange(screen: Screen, anchorX: CGFloat, margin: CGFloat) -> ClosedRange<CGFloat> {
        // Whole points, rounded inward, so a rounded frame never crosses a bound.
        let lower = (screen.frame.minX + margin).rounded(.up), upper = (screen.frame.maxX - margin).rounded(.down)
        guard let notch = screen.notch else { return lower...upper }
        if anchorX >= (notch.lowerBound + notch.upperBound) / 2 {
            return min((notch.upperBound + margin).rounded(.up), upper)...upper
        }
        return lower...max((notch.lowerBound - margin).rounded(.down), lower)
    }

    static func anchorX(_ trailing: Trailing, screen: Screen) -> CGFloat {
        switch trailing {
        case .item(let frame): frame.midX
        case .pointer(let x): x
        case .screenEdge: screen.frame.maxX
        }
    }

    /// The panel frame for a content of `size` (already wrapped to fit `allowedRange`).
    static func frame(size: CGSize, trailing: Trailing, screen: Screen, metrics: RolltopBarMetrics) -> CGRect {
        let range = allowedRange(screen: screen, anchorX: anchorX(trailing, screen: screen), margin: metrics.screenMargin)
        let target: CGFloat = switch trailing {
        case .item(let frame): frame.maxX + metrics.inset
        case .pointer(let x): x + min(size.width / 2, 22)
        case .screenEdge: range.upperBound
        }
        var x = target - size.width
        x = min(x, range.upperBound - size.width)
        x = max(x, range.lowerBound)
        let top = screen.frame.maxY - screen.menuBarHeight - metrics.gap
        return CGRect(x: x.rounded(), y: (top - size.height).rounded(), width: size.width, height: size.height)
    }
}
