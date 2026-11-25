import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Read-only system settings that decide whether styling can show. Never written.
nonisolated enum MenuBarSystemSettings {
    /// System Settings › Menu Bar › "Show menu bar background" (global key
    /// `SLSMenuBarUseBlurredAppearance`). Absent means off on 27.2.1: the bar was transparent
    /// with the key unset. While on, macOS draws its own background over the overlay.
    static let backgroundKey = "SLSMenuBarUseBlurredAppearance"
    /// "Automatically hide and show the menu bar" on the desktop (global key `_HIHideMenuBar`).
    static let autoHideKey = "_HIHideMenuBar"

    struct Snapshot: Equatable, Sendable {
        var showsBackground: Bool
        var hidesAutomatically: Bool
        var reducesTransparency: Bool

        /// Whether the overlay can show through at all.
        var allowsStyling: Bool { !showsBackground && !hidesAutomatically }
    }

    static func read() -> Snapshot {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        return Snapshot(showsBackground: bool(backgroundKey),
                        hidesAutomatically: bool(autoHideKey),
                        reducesTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
    }

    private static func bool(_ key: String) -> Bool {
        guard let value = CFPreferencesCopyAppValue(key as CFString, kCFPreferencesAnyApplication) else { return false }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return (string as NSString).boolValue }
        return false
    }
}

/// The Window Server's "Menubar" windows (one per display, layer 24 =
/// `kCGMainMenuWindowLevel`) mirror where each bar is drawn. A display whose bar window is
/// missing or not at the top of the display has no visible menu bar (full-screen Space
/// with a hidden bar, auto-hidden bar), so its overlay hides.
nonisolated enum MenuBarWindows {
    static var menuBarLayer: Int { Int(CGWindowLevelForKey(.mainMenuWindow)) }

    /// The bar frame (global top-left) of the display with `displayBounds`, nil when that
    /// display shows no bar right now.
    static func barFrame(displayBounds: CGRect, windows: [WindowInfo]) -> CGRect? {
        windows.first { window in
            window.layer == menuBarLayer
                && abs(window.bounds.minY - displayBounds.minY) <= 1
                && abs(window.bounds.minX - displayBounds.minX) <= 1
                && abs(window.bounds.width - displayBounds.width) <= 2
                && window.bounds.height > 0 && window.bounds.height < 80
        }?.bounds
    }
}

/// Where the app menus end on each bar, read through Accessibility.
///
/// macOS 27 shows on every display the menus of the app last active there; only the
/// frontmost app's `AXMenuBar` frame says which display it is on, and every app reports
/// its menu frames laid out on that display. So: the frontmost app's frames give the
/// active display's extent; any other display gets the width of the menus of the app that
/// owns its frontmost window (Finder when it has none), measured from that app's bar.
nonisolated enum AppMenuExtents {
    struct Extent: Equatable, Sendable {
        /// The app's `AXMenuBar` frame, global top-left.
        var barFrame: CGRect
        /// Right edge of its last menu title, global.
        var menusMaxX: CGFloat

        var width: CGFloat { menusMaxX - barFrame.minX }
    }

    /// Blocking AX read (≤ 0.3 s): run off the main thread.
    static func read(pid: pid_t) -> Extent? {
        let app = AX.application(pid, timeout: 0.3)
        guard let bar = AX.element(app, kAXMenuBarAttribute), let barFrame = AX.frame(bar) else { return nil }
        let items = AX.children(bar)
        guard !items.isEmpty else { return nil }
        // The last title is normally the rightmost; fall back to all of them when it has no width.
        if let last = items.last.flatMap(AX.frame), last.width > 0 {
            return Extent(barFrame: barFrame, menusMaxX: last.maxX)
        }
        let maxX = items.compactMap(AX.frame).filter { $0.width > 0 }.map(\.maxX).max()
        return maxX.map { Extent(barFrame: barFrame, menusMaxX: $0) }
    }

    /// Bar-local app-menu right edges per display id.
    static func readAll(frontmostPID: pid_t?, finderPID: pid_t?, ownPID: pid_t, displays: [DisplayGeometry]) -> [CGDirectDisplayID: CGFloat] {
        var result: [CGDirectDisplayID: CGFloat] = [:]
        var cache: [pid_t: Extent] = [:]
        func extent(_ pid: pid_t) -> Extent? {
            if let cached = cache[pid] { return cached }
            let value = read(pid: pid)
            if let value { cache[pid] = value }
            return value
        }
        var activeID: CGDirectDisplayID?
        if let front = frontmostPID, front != ownPID, let frontExtent = extent(front) {
            let probe = CGPoint(x: frontExtent.barFrame.midX, y: frontExtent.barFrame.minY + 1)
            if let display = displays.first(where: { $0.bounds.contains(probe) }) {
                activeID = display.displayID
                result[display.displayID] = frontExtent.menusMaxX - display.bounds.minX
            }
        }
        let others = displays.filter { $0.displayID != activeID }
        guard !others.isEmpty else { return result }
        let windows = WindowList.onScreen()
        for display in others {
            let owner = frontmostWindowOwner(displayBounds: display.bounds, windows: windows, excluding: [ownPID]) ?? finderPID
            guard let owner, owner != ownPID, let width = extent(owner)?.width else { continue }
            result[display.displayID] = width
        }
        return result
    }

    /// The pid owning the frontmost normal window centred on the display. `windows` are
    /// front to back, as the window server lists them.
    static func frontmostWindowOwner(displayBounds: CGRect, windows: [WindowInfo], excluding: Set<pid_t>) -> pid_t? {
        windows.first { window in
            window.layer == 0 && !excluding.contains(window.ownerPID)
                && window.bounds.width >= 100 && window.bounds.height >= 100
                && displayBounds.contains(CGPoint(x: window.bounds.midX, y: window.bounds.midY))
        }?.ownerPID
    }
}

/// Whether each bar shows dark or light content.
///
/// On 27.2.1 the bar's text colour follows the wallpaper under the transparent bar, not
/// the system appearance and not the overlay (a 90 % white overlay left the text white).
/// Rolltop's own status item windows carry the bar's appearance in `effectiveAppearance`.
/// While none is in the menu bar (the user hid Rolltop's icon and shows no custom item), the
/// last reading from one stands in; the system appearance is the last fallback (a cold
/// start with the icon hidden). A hidden item's window is skipped: AppKit keeps it with a
/// stale appearance (still VibrantDark after hiding) or a default one (VibrantLight with a
/// zero-height frame when hidden from launch, under a dark bar). [probe 2026-11-25]
enum MenuBarAppearanceProbe {
    struct Reading: Equatable {
        var appearance: BarAppearance
        /// Where the value came from, for the debug dump.
        var source: String
    }

    /// The appearance of the last status item window read while it was in the menu bar.
    private static var lastItemAppearance: NSAppearance?

    static func statusBarWindows() -> [NSWindow] {
        NSApp.windows.filter { NSStringFromClass(type(of: $0)).contains("StatusBarWindow") }
    }

    /// `excluding`: windows of items that are not in the menu bar
    /// (`OwnStatusItemRegistry.hiddenItemWindows`); only a reading that knows them updates
    /// the remembered appearance.
    static func reading(for screen: NSScreen?, excluding hidden: [NSWindow]? = nil) -> Reading {
        let windows = statusBarWindows().filter { window in !(hidden ?? []).contains { $0 === window } }
        let onScreen = windows.first { $0.screen == screen } ?? windows.first
        if let window = onScreen {
            if hidden != nil { lastItemAppearance = window.effectiveAppearance }
            return Reading(appearance: barAppearance(window.effectiveAppearance),
                           source: "status-item:\(window.effectiveAppearance.name.rawValue)")
        }
        if let last = lastItemAppearance {
            return Reading(appearance: barAppearance(last), source: "last-status-item:\(last.name.rawValue)")
        }
        return Reading(appearance: barAppearance(NSApp.effectiveAppearance), source: "system:\(NSApp.effectiveAppearance.name.rawValue)")
    }

    static func barAppearance(_ appearance: NSAppearance) -> BarAppearance {
        let match = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
        return match == .darkAqua || match == .vibrantDark ? .dark : .light
    }
}
