import CoreGraphics
import Foundation
import Testing
@testable import Rolltop

/// Geometry measured on this machine (macOS 27.2.1): LG main display 2304×1296 with a
/// 30 pt bar, built-in display with a notch to the right at y −37 (top-left coordinates).
@Suite struct BarHitClassifierTests {
    private let main = RevealBarGeometry.Display(
        displayID: 4,
        strip: CGRect(x: 0, y: 0, width: 2304, height: 30),
        slots: [CGRect(x: 1562, y: 0, width: 38, height: 30),      // third-party item
                CGRect(x: 1600, y: 0, width: 38, height: 30),
                CGRect(x: 1849, y: 0, width: 22, height: 30),      // sound
                CGRect(x: 1887, y: 0, width: 17, height: 30),      // AirDrop, 16 pt gap before it
                CGRect(x: 2148, y: 0, width: 133, height: 30)],    // clock, 23 pt from the edge
        slotOwnerPIDs: [10457, 654])
    private let builtIn = RevealBarGeometry.Display(
        displayID: 1,
        strip: CGRect(x: 2304, y: -37, width: 1728, height: 32),
        notch: 3075.5...3260.5,
        slots: [CGRect(x: 3290, y: -37, width: 38, height: 32)],
        slotOwnerPIDs: [10457],
        chevron: CGRect(x: 3270, y: -37, width: 16, height: 32))

    private var geometry: RevealBarGeometry { RevealBarGeometry(displays: [main, builtIn]) }

    // MARK: Geometry alone

    @Test func outsideTheStripIsOutside() {
        #expect(BarHitClassifier.geometryHit(CGPoint(x: 800, y: 31), in: geometry) == .outside)
        #expect(BarHitClassifier.geometryHit(CGPoint(x: 800, y: 500), in: geometry) == .outside)
        #expect(BarHitClassifier.geometryHit(CGPoint(x: 2500, y: -40), in: geometry) == .outside)
    }

    @Test func slotsAndTheirSpacingAreItems() {
        #expect(BarHitClassifier.geometryHit(CGPoint(x: 1580, y: 15), in: geometry) == .statusItem)
        // 16 pt gap between sound and AirDrop: spacing, not empty bar.
        #expect(BarHitClassifier.geometryHit(CGPoint(x: 1878, y: 15), in: geometry) == .statusItem)
        // Padding just left of the first item.
        #expect(BarHitClassifier.geometryHit(CGPoint(x: 1558, y: 15), in: geometry) == .statusItem)
        // Between the clock and the screen edge.
        #expect(BarHitClassifier.geometryHit(CGPoint(x: 2295, y: 15), in: geometry) == .statusItem)
    }

    @Test func wideGapsNeedAProbe() {
        // 1638…1849 is a 211 pt gap: empty bar or not is up to Accessibility.
        #expect(BarHitClassifier.geometryHit(CGPoint(x: 1740, y: 15), in: geometry) == nil)
        #expect(BarHitClassifier.geometryHit(CGPoint(x: 800, y: 15), in: geometry) == nil)
    }

    @Test func notchAndChevron() {
        #expect(BarHitClassifier.geometryHit(CGPoint(x: 3100, y: -21), in: geometry) == .notch)
        #expect(BarHitClassifier.geometryHit(CGPoint(x: 3275, y: -21), in: geometry) == .chevron)
        #expect(BarHitClassifier.geometryHit(CGPoint(x: 3300, y: -21), in: geometry) == .statusItem)
    }

    @Test func fullScreenHasNoStrip() {
        let flat = RevealBarGeometry(displays: [RevealBarGeometry.Display(displayID: 4, strip: CGRect(x: 0, y: 0, width: 2304, height: 0))])
        #expect(BarHitClassifier.geometryHit(CGPoint(x: 800, y: 0), in: flat) == .outside)
    }

    // MARK: With a probe (results measured with AXUIElementCopyElementAtPosition)

    @Test func activeBarAnswersForItself() {
        let probe = HitProbe(role: "AXMenuBar", pid: 5271, frame: CGRect(x: 0, y: 0, width: 2304, height: 30), menuBarOwnerPID: 5271)
        #expect(BarHitClassifier.classify(CGPoint(x: 800, y: 15), in: geometry, probe: probe) == .empty)
    }

    @Test func menuTitleOfTheMenuBarOwner() {
        let probe = HitProbe(role: "AXMenuBarItem", pid: 5271, frame: CGRect(x: 43, y: 0, width: 52, height: 30), menuBarOwnerPID: 5271)
        #expect(BarHitClassifier.classify(CGPoint(x: 60, y: 15), in: geometry, probe: probe) == .menuTitle)
    }

    @Test func statusItemMissingFromAStaleSnapshot() {
        let probe = HitProbe(role: "AXMenuBarItem", subrole: "AXMenuExtra", pid: 777,
                             frame: CGRect(x: 1700, y: 0, width: 30, height: 30), menuBarOwnerPID: 5271)
        #expect(BarHitClassifier.classify(CGPoint(x: 1710, y: 15), in: geometry, probe: probe) == .statusItem)
    }

    @Test func inactiveBarMapsTitlesFromTheOtherDisplay() {
        // The built-in bar is inactive: AX answers with Finder's menu bar laid out on the main display.
        let titles = [CGRect(x: 10, y: 0, width: 34, height: 30), CGRect(x: 43, y: 0, width: 47, height: 30),
                      CGRect(x: 318, y: 0, width: 47, height: 30)]
        let probe = HitProbe(role: "AXMenuBar", pid: 656, frame: CGRect(x: 0, y: 0, width: 2304, height: 30),
                             menuBarOwnerPID: 5271, titleFrames: titles)
        #expect(BarHitClassifier.classify(CGPoint(x: 2304 + 60, y: -21), in: geometry, probe: probe) == .menuTitle)
        #expect(BarHitClassifier.classify(CGPoint(x: 2304 + 340, y: -21), in: geometry, probe: probe) == .menuTitle)
        #expect(BarHitClassifier.classify(CGPoint(x: 2304 + 700, y: -21), in: geometry, probe: probe) == .empty)
    }

    @Test func inactiveBarAnswerFromAnItemOwnerIsAnItem() {
        let probe = HitProbe(role: "AXMenuBar", pid: 10457, frame: CGRect(x: 0, y: 0, width: 2304, height: 30),
                             menuBarOwnerPID: 5271, titleFrames: [])
        #expect(BarHitClassifier.classify(CGPoint(x: 2304 + 700, y: -21), in: geometry, probe: probe) == .statusItem)
    }

    @Test func noAnswerIsNeverEmpty() {
        #expect(BarHitClassifier.classify(CGPoint(x: 800, y: 15), in: geometry, probe: nil) == .unknown)
        let window = HitProbe(role: "AXWindow", pid: 1, frame: CGRect(x: 0, y: 0, width: 2304, height: 1296))
        #expect(BarHitClassifier.classify(CGPoint(x: 800, y: 15), in: geometry, probe: window) == .unknown)
        let noTitles = HitProbe(role: "AXMenuBar", pid: 656, frame: CGRect(x: 0, y: 0, width: 2304, height: 30))
        #expect(BarHitClassifier.classify(CGPoint(x: 2304 + 700, y: -21), in: geometry, probe: noTitles) == .unknown)
    }

    @Test func titleFramesOnlyWhenTheBarIsElsewhere() {
        let mainBar = CGRect(x: 0, y: 0, width: 2304, height: 30)
        #expect(!BarHitClassifier.needsTitleFrames(role: "AXMenuBar", frame: mainBar, point: CGPoint(x: 800, y: 15)))
        #expect(BarHitClassifier.needsTitleFrames(role: "AXMenuBar", frame: mainBar, point: CGPoint(x: 3000, y: -21)))
        #expect(!BarHitClassifier.needsTitleFrames(role: "AXMenuBarItem", frame: mainBar, point: CGPoint(x: 3000, y: -21)))
    }
}

@Suite struct MenuWindowFilterTests {
    private let strips = [CGRect(x: 0, y: 0, width: 2304, height: 30), CGRect(x: 2304, y: -37, width: 1728, height: 32)]

    @Test func popUpMenuHangingFromTheBar() {
        // NSMenu windows start 41 pt above the screen top (measured).
        #expect(MenuWindowFilter.hangsFromBar(layer: 101, bounds: CGRect(x: 1700, y: -41, width: 240, height: 180), strips: strips))
        #expect(MenuWindowFilter.hangsFromBar(layer: 101, bounds: CGRect(x: 3500, y: -5, width: 300, height: 400), strips: strips))
        // Control Center's panel (measured: layer 101, top at the screen edge).
        #expect(MenuWindowFilter.hangsFromBar(layer: 101, bounds: CGRect(x: 1824, y: 0, width: 656, height: 964), strips: strips))
    }

    @Test func ignoresOverlaysAndContextMenus() {
        // typeless keeps a 1×1 window at layer 1001; the cursor overlay is far above.
        #expect(!MenuWindowFilter.hangsFromBar(layer: 1001, bounds: CGRect(x: 0, y: 30, width: 1, height: 1), strips: strips))
        #expect(!MenuWindowFilter.hangsFromBar(layer: 2_147_483_630, bounds: CGRect(x: 868, y: 0, width: 112, height: 160), strips: strips))
        // A context menu in the middle of a window.
        #expect(!MenuWindowFilter.hangsFromBar(layer: 101, bounds: CGRect(x: 500, y: 400, width: 200, height: 300), strips: strips))
        // Ordinary windows.
        #expect(!MenuWindowFilter.hangsFromBar(layer: 0, bounds: CGRect(x: 0, y: 25, width: 800, height: 600), strips: strips))
    }
}
