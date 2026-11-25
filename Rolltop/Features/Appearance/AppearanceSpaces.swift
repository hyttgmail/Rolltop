import AppKit
import Foundation
import RolltopCore

/// Settings for per-Space styles and screen corners (under `rolltop.appearance.`, so profiles
/// and backups carry them).
enum AppearanceSpaceSettings {
    /// Display key → Space id → style. Overrides of Spaces that no longer exist are kept
    /// and ignored.
    static let spaceStyles = SettingsKey<[String: [String: AppearanceStyle]]>("rolltop.appearance.space-styles", default: [:])
    static let corners = SettingsKey<AppearanceCorners>("rolltop.appearance.screen-corners", default: AppearanceCorners())
}

/// The stored configuration plus each display's current Space: decides what to draw.
nonisolated struct AppearanceSpaceResolver: Equatable, Sendable {
    var configuration: AppearanceConfiguration
    var spaceStyles: [String: [String: AppearanceStyle]]
    /// Display key → current Space id; a missing entry (Spaces unavailable) uses the display's style.
    var currentSpaces: [String: String]

    /// The style to draw: the current Space's own style when it has one, else the display's.
    static func resolve(displayStyle: AppearanceStyle, overrides: [String: AppearanceStyle],
                        currentSpace: String?) -> AppearanceStyle {
        guard let currentSpace, let override = overrides[currentSpace] else { return displayStyle }
        return override
    }

    /// The style to draw on the display with `displayKey`, or nil when nothing is drawn.
    func style(forDisplay displayKey: String) -> AppearanceStyle? {
        guard configuration.isEnabled else { return nil }
        let config = configuration
        let displayStyle = config.perDisplay ? (config.displayStyles[displayKey]?.style ?? config.style) : config.style
        let chosen = Self.resolve(displayStyle: displayStyle, overrides: spaceStyles[displayKey] ?? [:],
                                  currentSpace: currentSpaces[displayKey])
        return chosen.drawsOverlay ? chosen : nil
    }

    /// Whether the overlays must run for `displayKeys`: some display draws now, or some
    /// Space of a connected display has a drawn style (so a Space switch is noticed).
    func drawsAnything(on displayKeys: [String]) -> Bool {
        if displayKeys.contains(where: { style(forDisplay: $0) != nil }) { return true }
        guard configuration.isEnabled else { return false }
        return displayKeys.contains { key in spaceStyles[key]?.values.contains(where: \.drawsOverlay) == true }
    }
}

// MARK: - Screen corners

/// Black concave corners at the top of each display (2b) and/or right under the menu bar
/// (2c). One shared radius; the same on every display.
nonisolated struct AppearanceCorners: Codable, Equatable, Sendable {
    var screenCorners = false
    var belowMenuBar = false
    /// Points.
    var radius = 10.0

    var drawsAny: Bool { screenCorners || belowMenuBar }

    static let radiusRange: ClosedRange<Double> = 4...24
}

nonisolated enum AppearanceCornerGeometry {
    enum Corner: String, Sendable { case topLeft = "top-left", topRight = "top-right" }

    struct Placement: Equatable, Sendable {
        /// AppKit (bottom-left origin) global coordinates.
        var frame: CGRect
        var corner: Corner
    }

    /// Corner squares for a screen. `stripHeight` is the menu bar strip
    /// (`frame.maxY - visibleFrame.maxY`); 0 in full screen or while the bar hides, where
    /// the corners below the bar fall back to the top of the screen.
    static func placements(screenFrame: CGRect, stripHeight: CGFloat, corners: AppearanceCorners) -> [Placement] {
        let radius = CGFloat(min(max(corners.radius, AppearanceCorners.radiusRange.lowerBound), AppearanceCorners.radiusRange.upperBound))
        var tops: [CGFloat] = []
        if corners.screenCorners { tops.append(screenFrame.maxY) }
        if corners.belowMenuBar {
            let top = screenFrame.maxY - max(0, stripHeight)
            if !tops.contains(top) { tops.append(top) }
        }
        return tops.flatMap { top in
            [Placement(frame: CGRect(x: screenFrame.minX, y: top - radius, width: radius, height: radius), corner: .topLeft),
             Placement(frame: CGRect(x: screenFrame.maxX - radius, y: top - radius, width: radius, height: radius), corner: .topRight)]
        }
    }
}

/// A click-through square that paints one concave black corner. Level 25 (one above the
/// menu bar's own window, PLATFORM §8) so it masks the ends of the bar; joins every Space
/// except full-screen ones (no `.fullScreenAuxiliary`).
final class AppearanceCornerPanel: NSPanel {
    let corner: AppearanceCornerGeometry.Corner

    init(corner: AppearanceCornerGeometry.Corner) {
        self.corner = corner
        super.init(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        canHide = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        isMovable = false
        contentView = AppearanceCornerView(corner: corner)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class AppearanceCornerView: NSView {
    let corner: AppearanceCornerGeometry.Corner

    init(corner: AppearanceCornerGeometry.Corner) {
        self.corner = corner
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        // The square minus a quarter circle centred on its inner bottom corner (even-odd;
        // the parts of the circle outside the square are clipped by the view).
        let side = bounds.width
        let center = corner == .topLeft ? CGPoint(x: side, y: 0) : CGPoint(x: 0, y: 0)
        let path = NSBezierPath(rect: bounds)
        path.appendOval(in: CGRect(x: center.x - side, y: center.y - side, width: side * 2, height: side * 2))
        path.windingRule = .evenOdd
        NSColor.black.setFill()
        path.fill()
    }
}

/// The corner panels on every display, reused by position.
final class AppearanceCornerOverlays {
    private var panels: [AppearanceCornerPanel] = []

    /// Shows one panel per placement (all displays together), closing the rest.
    func update(_ placements: [AppearanceCornerGeometry.Placement]) {
        while panels.count > placements.count { panels.removeLast().close() }
        for (index, placement) in placements.enumerated() {
            if index < panels.count, panels[index].corner != placement.corner {
                panels[index].close()
                panels[index] = AppearanceCornerPanel(corner: placement.corner)
            } else if index >= panels.count {
                panels.append(AppearanceCornerPanel(corner: placement.corner))
            }
            let panel = panels[index]
            if panel.frame != placement.frame {
                panel.setFrame(placement.frame, display: true)
                panel.contentView?.needsDisplay = true
            }
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    func closeAll() { update([]) }

    var shownPanels: [AppearanceCornerPanel] { panels.filter(\.isVisible) }
}
