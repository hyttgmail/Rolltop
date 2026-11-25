import AppKit
import Observation
import SwiftUI

/// What one overlay (or the preview) draws.
@Observable
final class BarRenderModel {
    var segments: [BarSegment] = []
    var style = AppearanceStyle.system
    var appearance = BarAppearance.light
    /// Animate segment changes (off for the first layout and under Reduce Motion).
    var animates = false
}

/// Draws the styled segments. Used by the overlay windows and by the settings preview,
/// so the preview shows exactly what the bar gets.
struct BarStyleView: View {
    let model: BarRenderModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.segments) { segment in
                BarSegmentView(segment: segment, style: model.style, appearance: model.appearance)
                    .frame(width: segment.frame.width, height: segment.frame.height)
                    .position(x: segment.frame.midX, y: segment.frame.midY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(model.animates ? .smooth(duration: 0.22) : nil, value: model.segments)
        .allowsHitTesting(false)
    }
}

struct BarSegmentView: View {
    let segment: BarSegment
    let style: AppearanceStyle
    let appearance: BarAppearance

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(topLeading: segment.corners.topLeading,
                                                                 bottomLeading: segment.corners.bottomLeading,
                                                                 bottomTrailing: segment.corners.bottomTrailing,
                                                                 topTrailing: segment.corners.topTrailing),
                               style: .continuous)
    }

    var body: some View {
        ZStack {
            if style.shadow.isEnabled { OutsideShadow(shape: shape, shadow: style.shadow) }
            fill
            let border = style.effectiveBorder
            if border.isEnabled {
                shape.strokeBorder(color(border.color, role: .border), lineWidth: border.width)
            }
        }
    }

    @ViewBuilder private var fill: some View {
        switch style.kind {
        case .system, .outline:
            Color.clear
        case .tint:
            shape.fill(color(style.tint, role: .fill).opacity(clamp(style.tintOpacity)))
        case .gradient:
            let points = ColorResolver.gradientPoints(degrees: style.gradientAngle)
            shape.fill(LinearGradient(colors: [color(style.gradientStart, role: .fill), color(style.gradientEnd, role: .fill)],
                                      startPoint: UnitPoint(x: points.start.x, y: points.start.y),
                                      endPoint: UnitPoint(x: points.end.x, y: points.end.y)))
                .opacity(clamp(style.gradientOpacity))
        case .material:
            shape.fill(Self.material(style.material))
        case .glass:
            GlassSegment(variant: style.glass,
                         tint: style.glassIsTinted ? nsColor(ColorResolver.resolve(style.tint, role: .glassTint, appearance: appearance)) : nil,
                         cornerRadius: segment.corners.maximum)
        }
    }

    static func material(_ thickness: MaterialThickness) -> Material {
        switch thickness {
        case .ultraThin: .ultraThinMaterial
        case .thin: .thinMaterial
        case .regular: .regularMaterial
        case .thick: .thickMaterial
        case .ultraThick: .ultraThickMaterial
        }
    }

    private func color(_ adaptive: AdaptiveColor, role: ColorRole) -> Color {
        Color(nsColor: nsColor(ColorResolver.resolve(adaptive, role: role, appearance: appearance)))
    }

    private func nsColor(_ rgba: RGBA) -> NSColor {
        NSColor(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }

    private func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
}

/// A shadow that only falls outside the shape, so translucent fills do not darken.
private struct OutsideShadow: View {
    let shape: UnevenRoundedRectangle
    let shadow: ShadowOptions

    var body: some View {
        let strength = min(1, max(0, shadow.strength))
        shape.fill(Color.black)
            .shadow(color: .black.opacity(0.18 + 0.32 * strength), radius: 1.5 + 5 * strength, x: 0, y: 1 + 2 * strength)
            .mask {
                ZStack {
                    Rectangle().padding(-40)
                    shape.blendMode(.destinationOut)
                }
                .compositingGroup()
            }
    }
}

/// `NSGlassEffectView` (macOS 26+), regular or clear, optionally tinted.
private struct GlassSegment: NSViewRepresentable {
    let variant: GlassVariant
    let tint: NSColor?
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        update(view)
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        update(view)
    }

    private func update(_ view: NSGlassEffectView) {
        view.style = variant == .clear ? .clear : .regular
        view.tintColor = tint
        view.cornerRadius = cornerRadius
    }
}
