import CoreGraphics
import Foundation

/// What a captured item image looks like.
nonisolated struct ImageTraits: Codable, Sendable, Equatable {
    /// Monochrome (no meaningful colour): drawn as a template, tinted to the surface.
    var isTemplateLike: Bool
    /// The foreground is light (captured from a dark menu bar).
    var lightForeground: Bool
    /// Sum of alpha over all pixels (in fully opaque pixel units).
    var coverage: Double
    /// Highest alpha (0…1). Below 1 on a dimmed bar (inactive display).
    var maxAlpha: Double
}

nonisolated enum ImageAnalysis {
    /// Chroma (max − min of unpremultiplied RGB) above which a pixel counts as coloured.
    static let colouredChroma = 0.14
    /// Share of coloured pixels above which an image is not template-like.
    static let colouredShare = 0.04

    static func traits(of buffer: PixelBuffer) -> ImageTraits {
        var coverage = 0.0, maxAlpha = 0.0
        var counted = 0, coloured = 0, light = 0
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                guard let c = buffer.color(x, y) else { continue }
                coverage += c.a
                maxAlpha = max(maxAlpha, c.a)
                // Faint edge pixels carry unreliable colour.
                guard c.a > 0.25 else { continue }
                counted += 1
                if max(c.r, c.g, c.b) - min(c.r, c.g, c.b) > colouredChroma { coloured += 1 }
                if luminance(c.r, c.g, c.b) > 0.5 { light += 1 }
            }
        }
        guard counted > 0 else {
            return ImageTraits(isTemplateLike: true, lightForeground: true, coverage: coverage, maxAlpha: maxAlpha)
        }
        let colouredFraction = Double(coloured) / Double(counted)
        let lightFraction = Double(light) / Double(counted)
        // Monochrome and one polarity (white on a dark bar or black on a light one).
        let polarityConsistent = lightFraction > 0.85 || lightFraction < 0.15
        return ImageTraits(isTemplateLike: colouredFraction <= colouredShare && polarityConsistent,
                           lightForeground: lightFraction >= 0.5, coverage: coverage, maxAlpha: maxAlpha)
    }

    static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    /// Trims transparent padding, keeping `padding` pixels around the visible content.
    /// Nil when nothing is visible.
    static func trimmed(_ buffer: PixelBuffer, padding: Int = 1) -> PixelBuffer? {
        guard let bounds = buffer.alphaBounds() else { return nil }
        return buffer.cropped(to: bounds.insetBy(dx: CGFloat(-padding), dy: CGFloat(-padding)))
    }

    /// A template mask: black with alpha = how strongly each pixel shows the foreground,
    /// normalised so the strongest pixel is opaque (a dimmed capture comes out at full strength).
    static func templateMask(_ buffer: PixelBuffer, lightForeground: Bool) -> PixelBuffer {
        var strengths = [Double](repeating: 0, count: buffer.width * buffer.height)
        var strongest = 0.0
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                guard let c = buffer.color(x, y) else { continue }
                let lum = luminance(c.r, c.g, c.b)
                let s = c.a * (lightForeground ? lum : 1 - lum)
                strengths[y * buffer.width + x] = s
                strongest = max(strongest, s)
            }
        }
        var out = [UInt8](repeating: 0, count: buffer.width * buffer.height * 4)
        if strongest > 0 {
            for (i, s) in strengths.enumerated() {
                out[i * 4 + 3] = UInt8(min(255, (s / strongest * 255).rounded()))
            }
        }
        return PixelBuffer(width: buffer.width, height: buffer.height, bytes: out)
    }
}
