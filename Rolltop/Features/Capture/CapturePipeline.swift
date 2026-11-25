import CoreGraphics
import Foundation

/// One item image cut out of a bar capture: trimmed, pixels as captured.
nonisolated struct CapturedItem: Sendable {
    let key: ItemImageKey
    let pixels: PixelBuffer
    /// Pixels per point.
    let scale: CGFloat
    let traits: ImageTraits
    let displayID: UInt32
}

nonisolated enum CapturePipeline {
    /// Below this much alpha (in opaque-pixel units) a crop counts as empty and never
    /// replaces a cached image.
    static let minimumCoverage = 12.0

    /// Crops every slot from the capture of its display, trims it and keeps, per item, the
    /// crop with the most visible pixels (an inactive display draws some items dimmed or
    /// not at all).
    static func extract(slots: [CaptureSlot], bars: [BarCapture]) -> [CapturedItem] {
        var buffers: [UInt32: (bar: BarCapture, pixels: PixelBuffer)] = [:]
        for bar in bars {
            if let pixels = PixelBuffer(image: bar.image) { buffers[bar.displayID] = (bar, pixels) }
        }
        var best: [ItemImageKey: CapturedItem] = [:]
        for slot in slots {
            guard let (bar, pixels) = buffers[slot.displayID],
                  let rect = CaptureGeometry.cropRect(slot: slot.frame, captureFrame: bar.frame,
                                                      imageSize: CGSize(width: pixels.width, height: pixels.height))
            else { continue }
            let scale = CGFloat(pixels.width) / max(1, bar.frame.width)
            let crop = pixels.cropped(to: rect)
            let item: CapturedItem
            if bar.isTransparent {
                guard let trimmed = ImageAnalysis.trimmed(crop) else { continue }
                item = CapturedItem(key: slot.key, pixels: trimmed, scale: scale,
                                    traits: ImageAnalysis.traits(of: trimmed), displayID: slot.displayID)
            } else {
                // Screen strip: the wallpaper is behind the icon, nothing to trim by alpha.
                let traits = ImageTraits(isTemplateLike: false, lightForeground: false,
                                         coverage: Double(crop.width * crop.height), maxAlpha: 1)
                item = CapturedItem(key: slot.key, pixels: crop, scale: scale, traits: traits, displayID: slot.displayID)
            }
            guard item.traits.coverage >= minimumCoverage else { continue }
            if let current = best[slot.key], current.traits.coverage >= item.traits.coverage { continue }
            best[slot.key] = item
        }
        return best.values.sorted { $0.key.description < $1.key.description }
    }
}

/// Size of a served item image. Captures keep their size relative to the menu bar: an
/// 18 pt request draws them at their natural size, other heights scale them, and anything
/// taller than the request is shrunk to fit. The canvas is `height` tall, content centred.
nonisolated enum ItemImageSizing {
    static let nominalHeight: CGFloat = 18

    static func layout(contentPoints: CGSize, requestedHeight: CGFloat) -> (canvas: CGSize, content: CGRect) {
        guard contentPoints.width > 0, contentPoints.height > 0, requestedHeight > 0 else {
            return (CGSize(width: requestedHeight, height: requestedHeight), .zero)
        }
        var k = requestedHeight / nominalHeight
        if contentPoints.height * k > requestedHeight { k = requestedHeight / contentPoints.height }
        let size = CGSize(width: contentPoints.width * k, height: contentPoints.height * k)
        let canvas = CGSize(width: size.width, height: requestedHeight)
        return (canvas, CGRect(x: 0, y: (requestedHeight - size.height) / 2, width: size.width, height: size.height))
    }
}
