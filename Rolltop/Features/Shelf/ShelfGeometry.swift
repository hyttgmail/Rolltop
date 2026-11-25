import CoreGraphics
import Foundation

/// A display as the shelf sees it, in global AppKit coordinates (bottom-left origin).
nonisolated struct ShelfScreen: Sendable, Equatable {
    var frame: CGRect
    var visibleFrame: CGRect
    /// `safeAreaInsets.top`: the notch height on a notched display, else 0.
    var safeAreaTop: CGFloat = 0
    /// The notch's x range (between the auxiliary top areas), nil without a notch.
    var notch: ClosedRange<CGFloat>?
}

/// Where the shelf sits and where its hot zones are. Pure, testable.
nonisolated enum ShelfGeometry {
    /// Gap kept to the screen's side edges.
    static let sideMargin: CGFloat = 8
    /// Width of the top-centre hot zone on a display without a notch.
    static let plainHotZoneWidth: CGFloat = 180
    /// The notch hot zone reaches this far past each side of the notch.
    static let notchSlack: CGFloat = 6
    /// Dragging files: the zone is wider and reaches below the menu bar.
    static let dragZoneWidth: CGFloat = 320
    static let dragZoneDepth: CGFloat = 40

    /// Height of the strip the shelf hangs from: the menu bar, or the notch when the menu
    /// bar is hidden (full screen, auto-hide).
    static func topInset(_ screen: ShelfScreen) -> CGFloat {
        let bar = screen.frame.maxY - screen.visibleFrame.maxY
        return max(bar, screen.safeAreaTop)
    }

    /// Centre of the notch, or of the screen's top edge.
    static func anchorX(_ screen: ShelfScreen) -> CGFloat {
        if let notch = screen.notch { return (notch.lowerBound + notch.upperBound) / 2 }
        return screen.frame.midX
    }

    /// The panel hangs from the bottom of the menu bar (under the notch), centred on the
    /// anchor, kept inside the screen.
    static func panelFrame(size: CGSize, screen: ShelfScreen) -> CGRect {
        let width = min(size.width, screen.frame.width - 2 * sideMargin)
        let top = screen.frame.maxY - topInset(screen)
        let height = min(size.height, top - screen.frame.minY - sideMargin)
        var x = anchorX(screen) - width / 2
        x = min(max(x, screen.frame.minX + sideMargin), screen.frame.maxX - sideMargin - width)
        return CGRect(x: x.rounded(), y: (top - height).rounded(), width: width.rounded(), height: height.rounded())
    }

    /// Resting the pointer here opens the shelf: the notch itself (plus a little slack), or a
    /// strip at the top centre of the menu bar.
    static func hoverZone(_ screen: ShelfScreen) -> CGRect {
        let top = screen.frame.maxY
        if let notch = screen.notch {
            let height = max(screen.safeAreaTop, topInset(screen), 1)
            return CGRect(x: notch.lowerBound - notchSlack, y: top - height,
                          width: notch.upperBound - notch.lowerBound + 2 * notchSlack, height: height)
        }
        let height = max(topInset(screen), 4)
        return CGRect(x: anchorX(screen) - plainHotZoneWidth / 2, y: top - height, width: plainHotZoneWidth, height: height)
    }

    /// Dragging files here opens the shelf: wider than the hover zone and reaching below the
    /// menu bar, so a drag aimed at the notch lands in it.
    static func dragZone(_ screen: ShelfScreen) -> CGRect {
        let hover = hoverZone(screen)
        let width = max(dragZoneWidth, hover.width)
        return CGRect(x: anchorX(screen) - width / 2, y: hover.minY - dragZoneDepth,
                      width: width, height: hover.height + dragZoneDepth)
    }

    /// While a hover- or drag-opened panel is up, the pointer may move freely inside these
    /// rects: the zone it came from, the panel (with a margin) and the gap between them.
    static func keepOpenRegion(screen: ShelfScreen, panel: CGRect) -> [CGRect] {
        let zone = dragZone(screen)
        let bridge = CGRect(x: panel.minX, y: panel.maxY - 2, width: panel.width, height: screen.frame.maxY - panel.maxY + 2)
        return [zone, bridge, panel.insetBy(dx: -10, dy: -10)]
    }

    /// The screen whose frame contains `point` (edges included), else nil.
    static func screen(containing point: CGPoint, in screens: [ShelfScreen]) -> ShelfScreen? {
        screens.first { $0.frame.insetBy(dx: 0, dy: -1).contains(point) }
    }
}

/// Panel size presets.
nonisolated enum ShelfPanelSize: String, CaseIterable, Sendable {
    case small
    case medium
    case large

    var size: CGSize {
        switch self {
        case .small: CGSize(width: 460, height: 320)
        case .medium: CGSize(width: 560, height: 400)
        case .large: CGSize(width: 680, height: 500)
        }
    }

    init(setting: String) { self = ShelfPanelSize(rawValue: setting) ?? .medium }
}
