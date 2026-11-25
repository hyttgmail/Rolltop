import AppKit
import Foundation
import RolltopCore
import Testing
@testable import Rolltop

/// The two screens of this machine (PLATFORM §11), global AppKit coordinates.
private let lgScreen = RolltopBarPlacement.Screen(frame: CGRect(x: 0, y: 0, width: 2304, height: 1296),
                                               visibleFrame: CGRect(x: 0, y: 75, width: 2304, height: 1191))
private let builtInScreen = RolltopBarPlacement.Screen(frame: CGRect(x: 2304, y: 216, width: 1728, height: 1117),
                                                    visibleFrame: CGRect(x: 2304, y: 216, width: 1728, height: 1085),
                                                    safeAreaTop: 32, notch: 3075.5...3260.5)

@Suite struct RolltopBarLayoutTests {
    private let metrics = RolltopBarMetrics()

    @Test func oneRowIsACapsule() {
        let layout = RolltopBarLayout.compute(cellWidths: [30, 30, 22], maxWidth: 1000, metrics: metrics)
        #expect(layout.rowCount == 1)
        #expect(layout.size == CGSize(width: 96, height: 34))
        #expect(layout.cellFrames[1] == CGRect(x: 37, y: 5, width: 30, height: 24))
        #expect(metrics.cornerRadius(rows: 1, height: 34) == 17)
    }

    @Test func manyItemsWrapIntoRows() {
        let maxWidth: CGFloat = 136   // inset 5 + 4 cells of 30 + 3 gaps of 2 + inset 5
        let layout = RolltopBarLayout.compute(cellWidths: Array(repeating: 30, count: 10), maxWidth: maxWidth, metrics: metrics)
        #expect(layout.rowCount == 3)
        #expect(layout.cellFrames[4].minY == 31)
        #expect(layout.cellFrames[4].minX == 5)
        #expect(layout.size.height == 86)
        // Several rows: concentric with the item capsules (radius 12, inset 5).
        #expect(metrics.cornerRadius(rows: 3, height: layout.size.height) == 17)
    }

    @Test func itemSizePresets() {
        #expect(RolltopBarMetrics(size: .regular).imageHeight == 18)
        #expect(RolltopBarMetrics(size: .regular).rowHeight == 24)
        #expect(RolltopBarMetrics(size: .large).rowHeight > RolltopBarMetrics(size: .regular).rowHeight)
        #expect(metrics.cellWidth(imageWidth: 18) == 30)
        #expect(metrics.cellWidth(imageWidth: 8) == 28)
    }
}

@Suite struct RolltopBarPlacementTests {
    private let metrics = RolltopBarMetrics()

    @Test func underTheStatusItemGrowingLeftwards() {
        let item = CGRect(x: 1500, y: 1266, width: 30, height: 30)
        let frame = RolltopBarPlacement.frame(size: CGSize(width: 200, height: 34), trailing: .item(item), screen: lgScreen, metrics: metrics)
        #expect(frame.maxX == CGFloat(1535))
        #expect(frame.maxY == CGFloat(1261))
    }

    @Test func underThePointerAndClampedToTheScreen() {
        let centred = RolltopBarPlacement.frame(size: CGSize(width: 30, height: 34), trailing: .pointer(1000), screen: lgScreen, metrics: metrics)
        #expect(centred.midX == CGFloat(1000))
        let nearEdge = RolltopBarPlacement.frame(size: CGSize(width: 400, height: 34), trailing: .pointer(2290), screen: lgScreen, metrics: metrics)
        #expect(nearEdge.maxX == CGFloat(2296))
        let nearLeft = RolltopBarPlacement.frame(size: CGSize(width: 400, height: 34), trailing: .pointer(20), screen: lgScreen, metrics: metrics)
        #expect(nearLeft.minX == CGFloat(8))
    }

    @Test func notOverflowedItemFallsBackToTheTrailingEdge() {
        let frame = RolltopBarPlacement.frame(size: CGSize(width: 120, height: 34), trailing: .screenEdge, screen: lgScreen, metrics: metrics)
        #expect(frame.maxX == CGFloat(2296))
    }

    @Test func notchedDisplayKeepsThePanelBesideTheNotch() {
        // Menu bar 32 pt; the panel sits right below it.
        #expect(builtInScreen.menuBarHeight == 32)
        // Pointer right of the notch, panel wider than the space to its left: it stops at
        // the notch instead of hanging under it.
        let right = RolltopBarPlacement.frame(size: CGSize(width: 300, height: 34), trailing: .pointer(3280),
                                           screen: builtInScreen, metrics: metrics)
        #expect(right.minX >= CGFloat(3268.5))
        #expect(right.maxY == CGFloat(1296))
        // Pointer left of the notch: the panel stays left of it.
        let left = RolltopBarPlacement.frame(size: CGSize(width: 300, height: 34), trailing: .pointer(3060),
                                          screen: builtInScreen, metrics: metrics)
        #expect(left.maxX <= CGFloat(3067.5))
        #expect(left.minX >= CGFloat(2312))
    }

    @Test func notchedDisplayWrapsWhenTheSideIsTooNarrow() {
        let range = RolltopBarPlacement.allowedRange(screen: builtInScreen, anchorX: 3500, margin: metrics.screenMargin)
        #expect(range == CGFloat(3269)...CGFloat(4024))
        let layout = RolltopBarLayout.compute(cellWidths: Array(repeating: 30, count: 40), maxWidth: range.upperBound - range.lowerBound,
                                           metrics: metrics)
        #expect(layout.rowCount > 1)
        #expect(layout.size.width <= range.upperBound - range.lowerBound)
        let frame = RolltopBarPlacement.frame(size: layout.size, trailing: .pointer(3500), screen: builtInScreen, metrics: metrics)
        #expect(frame.minX >= range.lowerBound && frame.maxX <= range.upperBound)
    }

    @Test func fullScreenSpaceStillClearsTheBarArea() {
        let fullScreen = RolltopBarPlacement.Screen(frame: builtInScreen.frame, visibleFrame: builtInScreen.frame, safeAreaTop: 32, notch: builtInScreen.notch)
        #expect(fullScreen.menuBarHeight == 32)
    }
}

@Suite struct RolltopBarBehaviourTests {
    private let now = Date(timeIntervalSince1970: 1000)

    @Test func hoverPanelClosesAfterThePointerStaysOutside() {
        typealias D = RolltopBarDismissal
        #expect(D.decide(trigger: .pointerHover, pointerInRegion: true, outsideSince: nil, lastActivity: now, now: now,
                         busy: false, hoverTolerance: 0.5, idleTimeout: 10) == .keep(outsideSince: nil))
        #expect(D.decide(trigger: .pointerHover, pointerInRegion: false, outsideSince: nil, lastActivity: now, now: now,
                         busy: false, hoverTolerance: 0.5, idleTimeout: 10) == .keep(outsideSince: now))
        #expect(D.decide(trigger: .pointerHover, pointerInRegion: false, outsideSince: now - 0.3, lastActivity: now, now: now,
                         busy: false, hoverTolerance: 0.5, idleTimeout: 10) == .keep(outsideSince: now - 0.3))
        #expect(D.decide(trigger: .pointerHover, pointerInRegion: false, outsideSince: now - 0.6, lastActivity: now, now: now,
                         busy: false, hoverTolerance: 0.5, idleTimeout: 10) == .dismiss(.pointerLeft))
        // Never while an activation is in flight.
        #expect(D.decide(trigger: .pointerHover, pointerInRegion: false, outsideSince: now - 5, lastActivity: now, now: now,
                         busy: true, hoverTolerance: 0.5, idleTimeout: 10) == .keep(outsideSince: nil))
    }

    @Test func otherPanelsCloseWhenIdle() {
        typealias D = RolltopBarDismissal
        #expect(D.decide(trigger: .statusItem, pointerInRegion: false, outsideSince: nil, lastActivity: now - 11, now: now,
                         busy: false, hoverTolerance: 0.5, idleTimeout: 10) == .dismiss(.idle))
        #expect(D.decide(trigger: .keyboard, pointerInRegion: false, outsideSince: nil, lastActivity: now - 5, now: now,
                         busy: false, hoverTolerance: 0.5, idleTimeout: 10) == .keep(outsideSince: nil))
        // 0 = never.
        #expect(D.decide(trigger: .pointerClick, pointerInRegion: false, outsideSince: nil, lastActivity: now - 999, now: now,
                         busy: false, hoverTolerance: 0.5, idleTimeout: 0) == .keep(outsideSince: nil))
    }

    @Test func keyboardMapping() {
        #expect(RolltopBarKeys.action(keyCode: 123, modifiers: []) == .move(.left))
        #expect(RolltopBarKeys.action(keyCode: 125, modifiers: []) == .move(.down))
        #expect(RolltopBarKeys.action(keyCode: 36, modifiers: []) == .activate(.left))
        #expect(RolltopBarKeys.action(keyCode: 36, modifiers: .shift) == .activate(.right))
        #expect(RolltopBarKeys.action(keyCode: 36, modifiers: .control) == .activate(.right))
        #expect(RolltopBarKeys.action(keyCode: 53, modifiers: []) == .dismiss)
        #expect(RolltopBarKeys.action(keyCode: 0, modifiers: []) == nil)
    }

    @Test func keyboardSelectionMovesAcrossRows() {
        let model = RolltopBarModel()
        let metrics = RolltopBarMetrics()
        model.metrics = metrics
        let layout = RolltopBarLayout.compute(cellWidths: Array(repeating: 30, count: 6), maxWidth: 104, metrics: metrics)
        model.cells = layout.cellFrames.enumerated().map { index, frame in
            let item = RolltopBarModel.Item(id: "com.a#\(index)", owner: .app("com.a"), index: index, name: "A", isAlwaysHidden: false, image: nil)
            return RolltopBarModel.Cell(id: item.id, kind: .item(item), frame: frame)
        }
        model.moveSelection(.right)
        #expect(model.selected == "com.a#0")
        model.moveSelection(.right)
        model.moveSelection(.down)
        #expect(model.selected == "com.a#4")
        model.moveSelection(.up)
        #expect(model.selected == "com.a#1")
        model.moveSelection(.up)
        #expect(model.selected == "com.a#1")   // no row above
        model.moveSelection(.left)
        model.moveSelection(.left)
        #expect(model.selected == "com.a#0")   // stops at the first item
    }
}

@Suite struct BackdropSamplerTests {
    @Test func appearanceFollowsTheBackdrop() {
        #expect(BackdropSampler.appearanceName(forLuminance: 0.95) == .aqua)
        #expect(BackdropSampler.appearanceName(forLuminance: 0.08) == .darkAqua)
        #expect(BackdropSampler.appearanceName(forLuminance: 0.5) == nil)
        #expect(BackdropSampler.appearanceName(forLuminance: nil) == nil)
    }

    @Test func meanLuminanceOfAFlatImage() {
        let white = PixelBuffer(width: 4, height: 4, bytes: [UInt8](repeating: 255, count: 64))
        #expect(abs(BackdropSampler.meanLuminance(white) - 1) < 0.001)
        var dark = [UInt8](repeating: 0, count: 64)
        for i in stride(from: 3, to: 64, by: 4) { dark[i] = 255 }
        #expect(BackdropSampler.meanLuminance(PixelBuffer(width: 4, height: 4, bytes: dark)) < 0.001)
    }
}

@Suite struct RolltopBarTriggerTests {
    @Test func triggerFollowsHowThePanelWasOpened() {
        typealias P = RolltopBarPresenter
        #expect(P.trigger(source: .hotkey, anchorIsStatusItem: false, secondsSinceClick: 9, pointerInMenuBar: true) == .keyboard)
        #expect(P.trigger(source: .statusMenu, anchorIsStatusItem: true, secondsSinceClick: 0.1, pointerInMenuBar: true) == .statusItem)
        #expect(P.trigger(source: .internal, anchorIsStatusItem: false, secondsSinceClick: 0.2, pointerInMenuBar: true) == .pointerClick)
        #expect(P.trigger(source: .internal, anchorIsStatusItem: false, secondsSinceClick: 5, pointerInMenuBar: true) == .pointerHover)
        // Shortcuts / AppleScript / URLs with the pointer elsewhere: idle timeout, not hover.
        #expect(P.trigger(source: .shortcuts, anchorIsStatusItem: false, secondsSinceClick: 5, pointerInMenuBar: false) == .other)
        #expect(P.trigger(source: .url, anchorIsStatusItem: false, secondsSinceClick: 5, pointerInMenuBar: false) == .other)
    }
}
