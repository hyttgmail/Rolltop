import AppKit
import ApplicationServices
import Foundation

/// One public Accessibility hit test at a point (`AXUIElementCopyElementAtPosition`). Blocks
/// on IPC: run it through `AXInventory.onQueue`. Needs Accessibility.
nonisolated enum RevealHitProbe {
    static let messagingTimeout: Float = 0.15

    /// `point` is in global top-left coordinates.
    static func probe(at point: CGPoint, menuBarOwnerPID: Int32?) -> HitProbe? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &found) == .success,
              let element = found else { return nil }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        let role = AX.role(element)
        let frame = AX.frame(element)
        var titles: [CGRect]?
        if BarHitClassifier.needsTitleFrames(role: role, frame: frame, point: point) {
            titles = AX.children(element).compactMap(AX.frame)
        }
        return HitProbe(role: role,
                        subrole: AX.string(element, kAXSubroleAttribute),
                        pid: AX.pid(element),
                        frame: frame,
                        menuBarOwnerPID: menuBarOwnerPID,
                        titleFrames: titles)
    }
}
