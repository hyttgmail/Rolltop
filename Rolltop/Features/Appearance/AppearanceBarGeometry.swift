import CoreGraphics
import Foundation

/// Corner radii of one segment, clockwise from top-left.
nonisolated struct SegmentCorners: Equatable, Hashable, Sendable {
    var topLeading: CGFloat
    var bottomLeading: CGFloat
    var bottomTrailing: CGFloat
    var topTrailing: CGFloat

    static func all(_ radius: CGFloat) -> SegmentCorners { SegmentCorners(topLeading: radius, bottomLeading: radius, bottomTrailing: radius, topTrailing: radius) }
    static func bottom(_ radius: CGFloat) -> SegmentCorners { SegmentCorners(topLeading: 0, bottomLeading: radius, bottomTrailing: radius, topTrailing: 0) }
    static let none = SegmentCorners.all(0)

    var maximum: CGFloat { max(topLeading, bottomLeading, bottomTrailing, topTrailing) }
}

/// One styled area of a bar, in bar-local coordinates: origin at the top-left of the
/// menu bar strip, y down.
nonisolated struct BarSegment: Equatable, Hashable, Sendable, Identifiable {
    enum Role: String, Sendable {
        /// The whole bar, or the bar beside a camera housing when it is the only part.
        case bar
        /// Left of the camera housing / around the app menus.
        case leading
        /// Right of the camera housing / around the status items.
        case trailing
    }

    var role: Role
    var frame: CGRect
    var corners: SegmentCorners

    var id: String { role.rawValue }
}

/// What the layout needs to know about one display's bar. All x values are bar-local.
nonisolated struct BarLayoutInput: Equatable, Sendable {
    /// Size of the menu bar strip.
    var barSize: CGSize
    /// The camera housing's x range, nil on displays without one.
    var notch: ClosedRange<CGFloat>?
    /// Right edge of the app menus shown on this bar, nil when unknown.
    var appMenusMaxX: CGFloat?
    /// Left edge of the leftmost visible status item (or the overflow chevron), nil when unknown.
    var statusItemsMinX: CGFloat?
    var shape: BarShape
    var splitAroundNotch: Bool
    var cornerRadius: CGFloat
}

/// Pure layout of the styled segments for one bar.
nonisolated enum AppearanceBarGeometry {
    /// Horizontal inset of rounded bars and pills from the screen edges.
    static let edgeInset: CGFloat = 4
    /// Vertical inset of rounded bars and pills.
    static let verticalInset: CGFloat = 2
    /// Room left between a segment and the camera housing.
    static let notchGap: CGFloat = 6
    /// Room around the content a pill hugs.
    static let pillPadding: CGFloat = 6
    /// Pills closer than this merge into one rounded bar.
    static let minimumPillGap: CGFloat = 12
    /// Narrower segments are dropped.
    static let minimumWidth: CGFloat = 8

    static func segments(_ input: BarLayoutInput) -> [BarSegment] {
        let width = input.barSize.width
        let height = input.barSize.height
        guard width > 0, height > 0 else { return [] }
        let notch = input.notch.flatMap { range -> ClosedRange<CGFloat>? in
            let clamped = max(0, range.lowerBound)...min(width, range.upperBound)
            return clamped.upperBound - clamped.lowerBound > 0 ? clamped : nil
        }
        let radius = max(0, input.cornerRadius)

        switch input.shape {
        case .fullWidth:
            let corners = SegmentCorners.bottom(min(radius, height / 2))
            if let notch, input.splitAroundNotch {
                return clean([
                    BarSegment(role: .leading, frame: CGRect(x: 0, y: 0, width: notch.lowerBound, height: height), corners: corners),
                    BarSegment(role: .trailing, frame: CGRect(x: notch.upperBound, y: 0, width: width - notch.upperBound, height: height), corners: corners),
                ])
            }
            return [BarSegment(role: .bar, frame: CGRect(x: 0, y: 0, width: width, height: height), corners: corners)]

        case .inset:
            return insetBar(width: width, height: height, notch: input.splitAroundNotch ? notch : nil, radius: radius)

        case .split:
            let pillHeight = height - 2 * verticalInset
            let corners = SegmentCorners.all(min(radius, pillHeight / 2))
            let y = verticalInset
            // Left pill: from the screen edge to the end of the app menus, never past the notch.
            var leading: BarSegment?
            if let menusMaxX = input.appMenusMaxX {
                var maxX = min(menusMaxX + pillPadding, width - edgeInset)
                if let notch { maxX = min(maxX, notch.lowerBound - notchGap) }
                leading = BarSegment(role: .leading, frame: CGRect(x: edgeInset, y: y, width: maxX - edgeInset, height: pillHeight), corners: corners)
            }
            // Right pill: from the first status item to the screen edge, never under the notch.
            var trailing: BarSegment?
            if let statusMinX = input.statusItemsMinX {
                var minX = max(statusMinX - pillPadding, edgeInset)
                if let notch { minX = max(minX, notch.upperBound + notchGap) }
                trailing = BarSegment(role: .trailing, frame: CGRect(x: minX, y: y, width: width - edgeInset - minX, height: pillHeight), corners: corners)
            }
            switch (leading, trailing) {
            case (nil, nil):
                // Nothing known to hug: fall back to a rounded bar.
                return insetBar(width: width, height: height, notch: notch, radius: radius)
            case let (lead?, trail?) where notch == nil && trail.frame.minX - lead.frame.maxX < minimumPillGap:
                // The two would touch: one rounded bar reads better than two overlapping pills.
                return [BarSegment(role: .bar, frame: CGRect(x: edgeInset, y: y, width: width - 2 * edgeInset, height: pillHeight), corners: corners)]
            default:
                return clean([leading, trailing].compactMap { $0 })
            }
        }
    }

    private static func insetBar(width: CGFloat, height: CGFloat, notch: ClosedRange<CGFloat>?, radius: CGFloat) -> [BarSegment] {
        let barHeight = height - 2 * verticalInset
        let corners = SegmentCorners.all(min(radius, barHeight / 2))
        let y = verticalInset
        if let notch {
            return clean([
                BarSegment(role: .leading, frame: CGRect(x: edgeInset, y: y, width: notch.lowerBound - notchGap - edgeInset, height: barHeight), corners: corners),
                BarSegment(role: .trailing, frame: CGRect(x: notch.upperBound + notchGap, y: y, width: width - edgeInset - notch.upperBound - notchGap, height: barHeight), corners: corners),
            ])
        }
        return [BarSegment(role: .bar, frame: CGRect(x: edgeInset, y: y, width: width - 2 * edgeInset, height: barHeight), corners: corners)]
    }

    /// Drops segments too narrow to draw and caps radii at half the segment's size.
    private static func clean(_ segments: [BarSegment]) -> [BarSegment] {
        segments.compactMap { segment in
            guard segment.frame.width >= minimumWidth, segment.frame.height > 0 else { return nil }
            var result = segment
            let cap = min(segment.frame.width, segment.frame.height) / 2
            result.corners = SegmentCorners(topLeading: min(segment.corners.topLeading, cap),
                                            bottomLeading: min(segment.corners.bottomLeading, cap),
                                            bottomTrailing: min(segment.corners.bottomTrailing, cap),
                                            topTrailing: min(segment.corners.topTrailing, cap))
            return result
        }
    }

    /// Room below the bar the overlay window needs for the shadow.
    static func shadowMargin(_ shadow: ShadowOptions) -> CGFloat {
        guard shadow.isEnabled else { return 0 }
        return (4 + 10 * min(1, max(0, shadow.strength))).rounded(.up)
    }

    /// The camera housing's bar-local x range from the screen's auxiliary areas (AppKit
    /// coordinates), nil when the screen has none.
    static func notchRange(screenMinX: CGFloat, auxiliaryTopLeft: CGRect?, auxiliaryTopRight: CGRect?) -> ClosedRange<CGFloat>? {
        guard let left = auxiliaryTopLeft, let right = auxiliaryTopRight, !left.isEmpty, !right.isEmpty,
              right.minX > left.maxX else { return nil }
        return (left.maxX - screenMinX)...(right.minX - screenMinX)
    }
}

/// Where the status items start on one bar, from MenuBarAgent's drawn slots (global
/// top-left coordinates). Overflowed slots are stacked under the chevron and do not count;
/// the chevron itself does.
///
/// MenuBarAgent keeps the slot of an app that quit for ~0.9 s after the item left the bar
/// (measured on 27.2.1), while NSWorkspace drops the process within milliseconds. Slots of
/// exited processes (`isLive == false`) are discounted: everything left of a removed item
/// moves right by its width, so the edge moves by the summed width of the dead slots.
nonisolated enum StatusExtent {
    struct Slot: Equatable, Sendable {
        var frame: CGRect
        var isOverflowed = false
        var isLive = true
    }

    static func minX(slots: [Slot], chevron: CGRect?, displayMinX: CGFloat) -> CGFloat? {
        let visible = slots.filter { !$0.isOverflowed && $0.frame.width > 0 }
        let live = visible.filter(\.isLive)
        let deadWidth = visible.filter { !$0.isLive }.reduce(CGFloat(0)) { $0 + $1.frame.width }
        var candidates = live.isEmpty ? [] : [(visible.map(\.frame.minX).min() ?? 0) + deadWidth]
        if let chevron { candidates.append(chevron.minX) }
        guard let minX = candidates.min() else { return nil }
        return minX - displayMinX
    }
}
