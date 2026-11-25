import AppKit
import CoreGraphics

/// Conversions between the two global coordinate spaces:
/// - top-left (CoreGraphics, Accessibility, CGEvent, `DrawnSlotRecord.frame`): origin at
///   the top-left of the primary display, y grows downward;
/// - bottom-left (AppKit, `NSScreen.frame`, `NSWindow.frame`, `NSEvent.mouseLocation`).
nonisolated enum ScreenGeometry {
    /// Height of the primary display (the one at the global origin).
    static var primaryHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }

    static func appKitRect(fromTopLeft rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func topLeftRect(fromAppKit rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func appKitPoint(fromTopLeft point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    static func topLeftPoint(fromAppKit point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// The menu bar strip of a screen in AppKit coordinates (zero height in full screen).
    @MainActor
    static func menuBarFrame(of screen: NSScreen) -> CGRect {
        let height = screen.frame.maxY - screen.visibleFrame.maxY
        return CGRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
    }
}
