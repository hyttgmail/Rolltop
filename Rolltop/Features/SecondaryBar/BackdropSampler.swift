import AppKit
import ScreenCaptureKit

/// Picks the Rolltop Bar's appearance from what is behind it, the way the menu bar flips its
/// foreground with the wallpaper. Measured on 27.2.1: regular glass in the dark appearance
/// over a white window turns light grey under white glyphs, and `tintColor` does not fix it
/// (a black tint even lightens the glass); light glass over bright content and dark glass
/// over dark content both read well. Needs Screen Recording; without it (or on any failure)
/// the panel follows the system appearance.
nonisolated enum BackdropSampler {
    private struct NoImage: Error {}

    /// Mean luminance (0…1) of the screen in `rect` (global top-left points), or nil.
    static func luminance(of rect: CGRect, timeout: Double = 0.15) async -> Double? {
        guard CGPreflightScreenCaptureAccess(), rect.width >= 1, rect.height >= 1 else { return nil }
        let box: UncheckedBox<CGImage>
        do {
            box = try await Watchdog.run(seconds: timeout, step: "backdrop") { (done: @escaping @Sendable (Result<UncheckedBox<CGImage>, Error>) -> Void) in
                SCScreenshotManager.captureImage(in: rect) { image, error in
                    if let image { done(.success(UncheckedBox(image))) } else { done(.failure(error ?? NoImage())) }
                }
            }
        } catch {
            return nil
        }
        guard let pixels = PixelBuffer(image: box.value) else { return nil }
        return meanLuminance(pixels)
    }

    static func meanLuminance(_ pixels: PixelBuffer) -> Double {
        var sum = 0.0, count = 0
        // Every other pixel is plenty for a mean.
        for y in stride(from: 0, to: pixels.height, by: 2) {
            for x in stride(from: 0, to: pixels.width, by: 2) {
                guard let c = pixels.color(x, y) else { continue }
                // Rec. 709 relative luminance.
                sum += 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : 0.5
    }

    /// Bright backdrop → light glass, dark backdrop → dark glass, in between → system.
    static func appearanceName(forLuminance luminance: Double?) -> NSAppearance.Name? {
        guard let luminance else { return nil }
        if luminance >= 0.6 { return .aqua }
        if luminance <= 0.35 { return .darkAqua }
        return nil
    }
}
