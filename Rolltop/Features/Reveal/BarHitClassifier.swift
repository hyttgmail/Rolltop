import CoreGraphics
import Foundation

// Decides what a point in the menu bar is: empty space, a status item, an app menu title,
// the overflow chevron or the notch. Pure: geometry snapshot plus one Accessibility probe
// result in, a classification out. Every coordinate is global top-left (CGEvent, AX,
// `DrawnSlotRecord.frame`).

/// The menu bar strips of every display, with what MenuBarAgent draws in them.
nonisolated struct RevealBarGeometry: Sendable, Equatable {
    nonisolated struct Display: Sendable, Equatable {
        var displayID: UInt32
        /// The menu bar strip (zero height in full screen).
        var strip: CGRect
        /// Horizontal extent of the camera housing, on displays with a notch.
        var notch: ClosedRange<CGFloat>?
        /// Visible (not overflowed) slots, left to right.
        var slots: [CGRect]
        /// Owner pids of `slots`, for recognising another app's answer on this display.
        var slotOwnerPIDs: Set<Int32>
        var chevron: CGRect?

        init(displayID: UInt32, strip: CGRect, notch: ClosedRange<CGFloat>? = nil, slots: [CGRect] = [],
             slotOwnerPIDs: Set<Int32> = [], chevron: CGRect? = nil) {
            self.displayID = displayID
            self.strip = strip
            self.notch = notch
            self.slots = slots.sorted { $0.minX < $1.minX }
            self.slotOwnerPIDs = slotOwnerPIDs
            self.chevron = chevron
        }

        var hasNotch: Bool { notch != nil }

        func stripContains(_ point: CGPoint, belowTolerance: CGFloat = 0) -> Bool {
            guard strip.height >= 1 else { return false }
            return point.x >= strip.minX && point.x < strip.maxX
                && point.y >= strip.minY && point.y < strip.maxY + belowTolerance
        }
    }

    var displays: [Display]

    static let empty = RevealBarGeometry(displays: [])

    func display(containing point: CGPoint, belowTolerance: CGFloat = 0) -> Display? {
        displays.first { $0.stripContains(point, belowTolerance: belowTolerance) }
    }

    /// The point is in any menu bar strip (optionally a few points below it).
    func isInStrip(_ point: CGPoint, belowTolerance: CGFloat = 0) -> Bool {
        display(containing: point, belowTolerance: belowTolerance) != nil
    }
}

/// What sits under a point in the menu bar.
nonisolated enum BarHit: String, Sendable, Equatable {
    /// Not in any menu bar strip.
    case outside
    /// The camera housing of a notched display.
    case notch
    /// The native overflow chevron.
    case chevron
    /// A status item, including the spacing between neighbouring items.
    case statusItem
    /// A title of the app menus (Apple menu, File, Edit…).
    case menuTitle
    /// Bare menu bar.
    case empty
    /// Accessibility gave no usable answer. Never counts as empty.
    case unknown
}

/// What one Accessibility hit test at the point returned (`AXUIElementCopyElementAtPosition`).
nonisolated struct HitProbe: Sendable, Equatable {
    var role: String?
    var subrole: String?
    var pid: Int32?
    /// Frame of the element that was hit.
    var frame: CGRect?
    /// The app whose menus the active menu bar shows.
    var menuBarOwnerPID: Int32?
    /// Frames of the hit menu bar's title items; read only when the hit `AXMenuBar` lies on
    /// another display (the bar under the point is inactive).
    var titleFrames: [CGRect]?

    init(role: String?, subrole: String? = nil, pid: Int32? = nil, frame: CGRect? = nil,
         menuBarOwnerPID: Int32? = nil, titleFrames: [CGRect]? = nil) {
        self.role = role
        self.subrole = subrole
        self.pid = pid
        self.frame = frame
        self.menuBarOwnerPID = menuBarOwnerPID
        self.titleFrames = titleFrames
    }
}

nonisolated enum BarHitClassifier {
    /// Slots are widened by this much on each side: clicks just beside an icon belong to it
    /// (Hidden Bar measured 6 pt toward the neighbour for the clock on 27.2.1).
    static let slotPadding: CGFloat = 6
    /// Gaps between neighbouring slots narrower than this are item spacing, not empty bar.
    static let mergeGap: CGFloat = 20
    /// The last item owns the bar up to the screen edge when it is this close to it
    /// (the clock takes clicks up to 24 pt toward the edge).
    static let edgeReach: CGFloat = 30
    static let chevronPadding: CGFloat = 4
    /// Horizontal slack around mapped menu titles on an inactive display.
    static let titlePadding: CGFloat = 4

    /// First step: geometry alone. `nil` means the point is in a strip, outside every item
    /// region, so only an Accessibility probe can tell a menu title from empty bar.
    static func geometryHit(_ point: CGPoint, in geometry: RevealBarGeometry) -> BarHit? {
        guard let display = geometry.display(containing: point) else { return .outside }
        if let notch = display.notch, notch.contains(point.x) { return .notch }
        if let chevron = display.chevron,
           point.x >= chevron.minX - chevronPadding, point.x <= chevron.maxX + chevronPadding { return .chevron }
        if itemRuns(of: display).contains(where: { $0.contains(point.x) }) { return .statusItem }
        return nil
    }

    /// Horizontal runs covered by status items: padded slots, small gaps merged, the last
    /// run extended to the screen edge when it nearly reaches it.
    static func itemRuns(of display: RevealBarGeometry.Display) -> [ClosedRange<CGFloat>] {
        var runs: [ClosedRange<CGFloat>] = []
        for slot in display.slots where slot.width > 0 {
            let lower = slot.minX - slotPadding
            let upper = slot.maxX + slotPadding
            if let last = runs.last, lower - last.upperBound < mergeGap {
                runs[runs.count - 1] = last.lowerBound...max(last.upperBound, upper)
            } else {
                runs.append(lower...upper)
            }
        }
        if let last = runs.last, display.strip.maxX - last.upperBound <= edgeReach {
            runs[runs.count - 1] = last.lowerBound...display.strip.maxX
        }
        return runs
    }

    /// Second step: the probe decides between menu title, item and empty bar.
    static func classify(_ point: CGPoint, in geometry: RevealBarGeometry, probe: HitProbe?) -> BarHit {
        if let hit = geometryHit(point, in: geometry) { return hit }
        guard let display = geometry.display(containing: point) else { return .outside }
        guard let probe, let role = probe.role else { return .unknown }
        switch role {
        case "AXMenuBarItem", "AXMenuExtra":
            if probe.subrole == "AXMenuExtra" { return .statusItem }
            guard let pid = probe.pid, pid == probe.menuBarOwnerPID else {
                // A menu bar item of another app is one of its status items, unless the bar
                // under the point is inactive and shows that app's menus (titles mapped below).
                return probe.frame.map(display.strip.intersects) == false ? .menuTitle : .statusItem
            }
            return .menuTitle
        case "AXMenuBar":
            guard let frame = probe.frame else { return .unknown }
            if frame.contains(point) {
                // The active bar answered for itself: nothing else is under the point.
                return .empty
            }
            // The bar under the point is inactive: macOS answers with an app's menu bar laid
            // out on another display (measured 27.2.1). It shows that app's titles at the same
            // offsets from its own left edge.
            if let pid = probe.pid, display.slotOwnerPIDs.contains(pid) { return .statusItem }
            guard let titles = probe.titleFrames else { return .unknown }
            let offset = display.strip.minX - frame.minX
            let onTitle = titles.contains { title in
                point.x >= title.minX + offset - titlePadding && point.x <= title.maxX + offset + titlePadding
            }
            return onTitle ? .menuTitle : .empty
        default:
            return .unknown
        }
    }

    /// Whether the probe needs the hit menu bar's title frames (an inactive display).
    static func needsTitleFrames(role: String?, frame: CGRect?, point: CGPoint) -> Bool {
        role == "AXMenuBar" && !(frame?.contains(point) ?? true)
    }
}

/// A window that hangs from the menu bar: an open menu or an item's panel.
nonisolated enum MenuWindowFilter {
    /// Pop-up menus and Control Center panels sit at 101; screen savers, cursors and
    /// overlays live at 1000 and above.
    static let layers = 101..<1000
    static let minimumSide: CGFloat = 20
    /// A menu's window starts above the screen top (transparent margin) and reaches below
    /// the strip; anything whose top is lower than this below the strip does not hang from it.
    static let stripSlack: CGFloat = 8

    static func hangsFromBar(layer: Int, bounds: CGRect, strips: [CGRect]) -> Bool {
        guard layers.contains(layer), bounds.width >= minimumSide, bounds.height >= minimumSide else { return false }
        return strips.contains { strip in
            strip.height >= 1
                && bounds.maxX > strip.minX && bounds.minX < strip.maxX
                && bounds.minY <= strip.maxY + stripSlack && bounds.maxY > strip.maxY
        }
    }
}
