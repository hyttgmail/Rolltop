import CoreGraphics
import Foundation
import ScreenCaptureKit

/// One display's menu bar as captured.
nonisolated struct BarCapture: @unchecked Sendable {
    let displayID: UInt32
    /// What the image shows, global top-left points.
    let frame: CGRect
    let image: CGImage
    /// True for MenuBarAgent's window (icons on transparent pixels); false for the
    /// screen-strip fallback (wallpaper behind the icons).
    let isTransparent: Bool
}

nonisolated enum CaptureError: LocalizedError {
    case noPermission
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noPermission: "Screen Recording is not granted"
        case .failed(let reason): reason
        }
    }
}

/// Captures menu bars. Behind a protocol so unit tests never reach ScreenCaptureKit.
nonisolated protocol MenuBarCapturing: Sendable {
    /// - Parameter bars: display id → that display's bar frame (global top-left points),
    ///   used for the screen-strip fallback.
    func captureBars(_ bars: [UInt32: CGRect]) async throws -> [BarCapture]
}

/// ScreenCaptureKit capture of MenuBarAgent's per-display window (docs/PLATFORM.md §6),
/// falling back to the display's top strip. Every call has a watchdog.
///
/// Measured on this machine (27.2.1, 2026-11-24, shell launch): the window is owned by
/// `com.apple.MenuBarAgent`, layer 24, reported off-screen with an empty title, frame in
/// points (2304×30 main, 1728×33 built-in); captures come out at 2× on transparent pixels
/// in 22–72 ms; the shareable-content listing takes ~60 ms.
nonisolated struct ScreenCaptureKitCapturer: MenuBarCapturing {
    static let agentBundleID = "com.apple.MenuBarAgent"
    var timeout: Double = 2

    func captureBars(_ bars: [UInt32: CGRect]) async throws -> [BarCapture] {
        // Never reach ScreenCaptureKit without the grant: listing content would prompt.
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.noPermission }
        let content = try await Watchdog.run(seconds: timeout, step: "shareable content") { done in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
                if let content { done(.success(UncheckedBox(content))) } else { done(.failure(error ?? CaptureError.failed("no content"))) }
            }
        }.value
        var result: [BarCapture] = []
        for (displayID, barFrame) in bars.sorted(by: { $0.key < $1.key }) {
            let display = content.displays.first { $0.displayID == displayID }
            let displayFrame = display?.frame ?? barFrame
            let window = content.windows.first { window in
                window.owningApplication?.bundleIdentifier == Self.agentBundleID
                    && window.frame.height <= 60
                    && abs(window.frame.width - displayFrame.width) < 2
                    && abs(window.frame.minX - displayFrame.minX) < 2
            }
            if let window {
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                let scale = max(1, CGFloat(filter.pointPixelScale))
                config.width = Int((filter.contentRect.width * scale).rounded())
                config.height = Int((filter.contentRect.height * scale).rounded())
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                config.captureResolution = .best
                let image = try await Self.captureImage(filter: filter, configuration: config, timeout: timeout)
                result.append(BarCapture(displayID: displayID, frame: window.frame, image: image, isTransparent: true))
            } else {
                let image = try await Self.captureRect(barFrame, timeout: timeout)
                result.append(BarCapture(displayID: displayID, frame: barFrame, image: image, isTransparent: false))
            }
        }
        return result
    }

    private static func captureImage(filter: SCContentFilter, configuration: SCStreamConfiguration,
                                     timeout: Double) async throws -> CGImage {
        try await Watchdog.run(seconds: timeout, step: "window capture") { done in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let image { done(.success(UncheckedBox(image))) } else { done(.failure(error ?? CaptureError.failed("no image"))) }
            }
        }.value
    }

    private static func captureRect(_ rect: CGRect, timeout: Double) async throws -> CGImage {
        try await Watchdog.run(seconds: timeout, step: "strip capture") { done in
            SCScreenshotManager.captureImage(in: rect) { image, error in
                if let image { done(.success(UncheckedBox(image))) } else { done(.failure(error ?? CaptureError.failed("no image"))) }
            }
        }.value
    }
}
