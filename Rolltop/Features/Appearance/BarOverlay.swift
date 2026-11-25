import AppKit
import SwiftUI

/// The click-through panel behind one display's menu bar.
///
/// Measured on 27.2.1 (2026-11-24): at level 23 (`kCGMainMenuWindowLevel - 1`) the panel
/// is drawn below the Window Server "Menubar" window (layer 24), so titles and icons stay
/// on top; at 24 it also stays below the Menubar window, but only by the window server's
/// order within the layer; at 25 (`statusWindow`) it covers the titles. AppKit constrains
/// windows below the menu bar level to start under the bar, hence the
/// `constrainFrameRect` override.
final class BarOverlayPanel: NSPanel {
    static var overlayLevel: NSWindow.Level { NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1) }

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = Self.overlayLevel
        // No .fullScreenAuxiliary: the window server keeps the panel out of full-screen Spaces.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        canHide = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        isMovable = false
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One display's overlay: panel, hosting view and render model.
final class BarOverlay {
    let displayID: CGDirectDisplayID
    let panel = BarOverlayPanel()
    let model = BarRenderModel()
    private(set) var isShown = false

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        let host = NSHostingView(rootView: BarStyleView(model: model))
        host.sizingOptions = []
        panel.contentView = host
    }

    /// Places the panel over `barFrame` (AppKit coordinates) plus `margin` below it and draws
    /// `segments` (bar-local).
    func update(barFrame: CGRect, margin: CGFloat, segments: [BarSegment], style: AppearanceStyle,
                appearance: BarAppearance, animate: Bool) {
        let frame = CGRect(x: barFrame.minX, y: barFrame.minY - margin, width: barFrame.width, height: barFrame.height + margin)
        let moved = panel.frame != frame
        if moved { panel.setFrame(frame, display: false) }
        let named: NSAppearance.Name = appearance == .dark ? .darkAqua : .aqua
        if panel.appearance?.name != named { panel.appearance = NSAppearance(named: named) }
        // A moved panel (new display geometry) jumps; content changes on a steady panel animate.
        model.animates = animate && isShown && !moved
        if model.style != style { model.style = style }
        if model.appearance != appearance { model.appearance = appearance }
        if model.segments != segments { model.segments = segments }
        if !isShown {
            panel.orderFrontRegardless()
            isShown = true
        }
    }

    func hide() {
        guard isShown else { return }
        panel.orderOut(nil)
        isShown = false
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
        isShown = false
    }

    var windowNumber: Int { panel.windowNumber }
}
