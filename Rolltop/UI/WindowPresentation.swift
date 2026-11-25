import AppKit

/// Brings one of Rolltop's own windows (Settings, onboarding) to the front and makes it key.
///
/// Rolltop is an agent app (LSUIElement) and macOS 27 activation is cooperative
/// (docs/PLATFORM.md §7). Measured on 27.2.1 (2026-11-24): with a URL delivered by
/// `open -g` while Finder was active, `NSApp.activate()` was declined (window ordered
/// front but not key), while `NSApp.activate(ignoringOtherApps: true)` was honoured
/// (app active, window key). So: ask cooperatively first, and when that is declined fall
/// back to the explicit request; the user asked to see this window.
enum WindowPresentation {
    static func present(_ window: NSWindow, log: RolltopLogger) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        Task { @MainActor [weak window] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let window, window.isVisible else { return }
            var fallback = false
            if !NSApp.isActive || !window.isKeyWindow {
                fallback = true
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .milliseconds(250))
            }
            log.info("window \(window.identifier?.rawValue ?? "?") presented\(fallback ? " after fallback activation" : ""): app active \(NSApp.isActive), key \(window.isKeyWindow)")
        }
    }
}
