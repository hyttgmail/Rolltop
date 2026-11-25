import AppKit
import CoreGraphics
import Foundation

/// On-screen windows as the window server reports them. Owner, layer and bounds need
/// no Screen Recording permission (names do).
nonisolated struct WindowInfo: Sendable, Equatable {
    var windowID: CGWindowID
    var ownerPID: pid_t
    var layer: Int
    /// Global top-left coordinates.
    var bounds: CGRect
}

nonisolated enum WindowList {
    /// `NSPopUpMenuWindowLevel`: menus and popovers sit here or above.
    static let popUpMenuLayer = 101

    static func onScreen() -> [WindowInfo] {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return infos.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            return WindowInfo(windowID: id, ownerPID: pid, layer: layer, bounds: bounds)
        }
    }

    /// Windows of `pids` at menu level or above.
    static func menuWindows(of pids: Set<pid_t>) -> [WindowInfo] {
        onScreen().filter { pids.contains($0.ownerPID) && $0.layer >= popUpMenuLayer }
    }
}

/// Notification Center's panel state (docs/PLATFORM.md §3).
nonisolated enum NotificationCenterPanel {
    static let bundleID = "com.apple.notificationcenterui"
    /// Only the panel shows Edit Widgets; a notification banner never does.
    static let panelControlIdentifier = "widget-editor-button"

    /// A notificationcenterui window at layer ≥ 0 at least half as tall as the smallest
    /// screen that contains the Edit Widgets control. When Accessibility cannot read the
    /// window, the window alone counts.
    static func isOpen(minimumHeight: CGFloat) -> Bool {
        let owners = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        guard !owners.isEmpty else { return false }
        let windowUp = WindowList.onScreen().contains {
            owners.contains($0.ownerPID) && $0.layer >= 0 && $0.bounds.height >= minimumHeight
        }
        guard windowUp else { return false }
        guard let identifiers = identifiers(in: owners) else { return true }
        return identifiers.contains(panelControlIdentifier)
    }

    static func minimumPanelHeight(displays: [DisplayGeometry]) -> CGFloat {
        (displays.map(\.bounds.height).min() ?? 0) / 2
    }

    private static func identifiers(in owners: Set<pid_t>) -> [String]? {
        var found: [String] = []
        for pid in owners {
            let app = AX.application(pid, timeout: 0.5)
            guard let windows = AX.value(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
            for window in windows { collect(window, depth: 0, into: &found) }
        }
        return found
    }

    private static func collect(_ element: AXUIElement, depth: Int, into found: inout [String]) {
        if let identifier = AX.identifier(element) { found.append(identifier) }
        guard depth < 5 else { return }
        for child in AX.children(element) { collect(child, depth: depth + 1, into: &found) }
    }
}
