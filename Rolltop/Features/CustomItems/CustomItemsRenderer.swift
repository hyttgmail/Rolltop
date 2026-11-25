import AppKit

/// Draws custom items for the menu bar and for the settings previews from the same code.
/// Everything except emoji is a template image, so the bar tints it with its real text
/// colour (which follows the wallpaper, docs/PLATFORM.md §8) and the quiet style is alpha,
/// never a colour.
enum CustomItemsRenderer {
    struct Rendering {
        var image: NSImage?
        /// The status item's `length`.
        var length: CGFloat
        /// Width the text part needs (automatic widths ratchet on it).
        var textWidth: CGFloat = 0
    }

    /// Alpha of a spacer's content: quiet, secondary.
    static let quietAlpha: CGFloat = 0.5
    /// Room either side of a widget's or group's content, like the bar's own items.
    static let padding: CGFloat = 4
    static let symbolTextGap: CGFloat = 4
    static let historyWidth: CGFloat = 22
    static let historyHeight: CGFloat = 13

    static var height: CGFloat { max(NSStatusBar.system.thickness, 22) }
    static var fontSize: CGFloat { NSFont.menuBarFont(ofSize: 0).pointSize }
    /// Monospaced digits: changing values never change the width.
    static var valueFont: NSFont { NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular) }
    static var textFont: NSFont { NSFont.menuBarFont(ofSize: 0) }

    static func symbol(_ name: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: (fontSize * 0.95).rounded(), weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }

    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
    }

    // MARK: Glyphs

    /// A glyph's natural size; nil when blank or unknown (a missing symbol name).
    static func glyphSize(_ glyph: CustomItemGlyph) -> CGSize? {
        guard !glyph.isBlank else { return nil }
        switch glyph.kind {
        case .none: return nil
        case .symbol: return symbol(glyph.value)?.size
        case .text: return NSAttributedString(string: glyph.value, attributes: [.font: textFont]).size()
        case .emoji: return NSAttributedString(string: glyph.value, attributes: [.font: NSFont.systemFont(ofSize: fontSize)]).size()
        }
    }

    /// Draws `glyph` centred in `rect` of the current context.
    private static func drawGlyph(_ glyph: CustomItemGlyph, in rect: CGRect, alpha: CGFloat) {
        guard let size = glyphSize(glyph) else { return }
        let origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        switch glyph.kind {
        case .none: break
        case .symbol:
            symbol(glyph.value)?.draw(in: CGRect(origin: origin, size: size), from: .zero, operation: .sourceOver, fraction: alpha)
        case .text, .emoji:
            let font = glyph.kind == .text ? textFont : NSFont.systemFont(ofSize: fontSize)
            let colour = glyph.kind == .text ? NSColor.black.withAlphaComponent(alpha) : NSColor.black
            let string = NSAttributedString(string: glyph.value, attributes: [.font: font, .foregroundColor: colour])
            if glyph.kind == .emoji, alpha < 1 {
                NSGraphicsContext.current?.cgContext.setAlpha(alpha)
            }
            string.draw(at: origin)
        }
    }

    // MARK: Items

    static func spacer(_ spacer: CustomItemSpacer) -> Rendering {
        let width = CGFloat(spacer.clampedWidth)
        let glyph = spacer.glyph
        guard !glyph.isBlank else { return Rendering(image: nil, length: width) }
        let height = height
        let image = NSImage(size: CGSize(width: width, height: height), flipped: false) { rect in
            drawGlyph(glyph, in: rect, alpha: quietAlpha)
            return true
        }
        image.isTemplate = glyph.kind != .emoji
        return Rendering(image: image, length: width)
    }

    static func group(_ group: CustomItemGroup) -> Rendering {
        let glyph = group.icon.isBlank ? CustomItemGroup.defaultIcon : group.icon
        let size = glyphSize(glyph) ?? glyphSize(CustomItemGroup.defaultIcon) ?? CGSize(width: 16, height: 16)
        let width = ceil(size.width) + 2 * padding
        let height = height
        let image = NSImage(size: CGSize(width: width, height: height), flipped: false) { rect in
            drawGlyph(glyph, in: rect, alpha: 1)
            return true
        }
        image.isTemplate = glyph.kind != .emoji
        return Rendering(image: image, length: width)
    }

    /// - Parameter minimumTextWidth: the widest text seen so far (automatic widths never
    ///   shrink while the item runs, so the bar does not jitter).
    static func widget(_ content: CustomItemsWidgetContent, fixedWidth: Double?, minimumTextWidth: CGFloat = 0) -> Rendering {
        let font = valueFont
        let symbolImage = content.symbol.flatMap(symbol)
        let symbolSize = symbolImage?.size ?? .zero
        let measured = content.text == nil ? 0 : max(content.widthSamples.map { textWidth($0, font: font) }.max() ?? 0, minimumTextWidth)
        var natural = 2 * padding
        if symbolImage != nil { natural += ceil(symbolSize.width) }
        if content.text != nil { natural += measured + (symbolImage != nil ? symbolTextGap : 0) }
        if content.history != nil { natural += historyWidth + (natural > 2 * padding ? symbolTextGap : 0) }
        let length = fixedWidth.map { CGFloat($0) } ?? max(natural, 2 * padding + 8)
        let height = height
        let text = content.text
        let history = content.history
        let image = NSImage(size: CGSize(width: length, height: height), flipped: false) { rect in
            // Content starts at the leading padding; a fixed width wider than the content
            // centres it, a narrower one clips the text's end.
            var x = max(padding, (rect.width - natural) / 2 + padding)
            if let symbolImage {
                symbolImage.draw(in: CGRect(x: x, y: (rect.height - symbolSize.height) / 2, width: symbolSize.width, height: symbolSize.height))
                x += ceil(symbolSize.width) + symbolTextGap
            }
            if let history {
                drawHistory(history, in: CGRect(x: x, y: (rect.height - historyHeight) / 2, width: historyWidth, height: historyHeight))
                x += historyWidth + symbolTextGap
            }
            if let text {
                let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
                let size = string.size()
                NSGraphicsContext.current?.cgContext.clip(to: CGRect(x: 0, y: 0, width: rect.width - padding / 2, height: rect.height))
                string.draw(at: CGPoint(x: x, y: (rect.height - size.height) / 2))
            }
            return true
        }
        image.isTemplate = true
        return Rendering(image: image, length: length, textWidth: measured)
    }

    /// Bars for 0…1 values, newest at the trailing edge, over a faint baseline.
    private static func drawHistory(_ values: [Double], in rect: CGRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1).fill()
        let capacity = 12
        let step = rect.width / CGFloat(capacity)
        NSColor.black.withAlphaComponent(0.9).setFill()
        for (index, value) in values.suffix(capacity).reversed().enumerated() {
            let barHeight = max(1, CGFloat(value) * rect.height)
            let x = rect.maxX - CGFloat(index + 1) * step
            CGRect(x: x + 0.5, y: rect.minY, width: max(step - 1, 1), height: barHeight).fill()
        }
    }
}
