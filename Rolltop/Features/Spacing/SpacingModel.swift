import Foundation

/// `NSStatusItemSpacing` / `NSStatusItemSelectionPadding` as a pair, in points.
nonisolated struct SpacingValues: Codable, Equatable, Hashable, Sendable {
    var spacing: Int
    var padding: Int

    init(spacing: Int, padding: Int) {
        self.spacing = spacing
        self.padding = padding
    }

    /// macOS's values when the keys are absent.
    static let systemDefault = SpacingValues(spacing: 16, padding: 16)
    static let range = 0...40

    var clamped: SpacingValues {
        SpacingValues(spacing: min(Self.range.upperBound, max(Self.range.lowerBound, spacing)),
                      padding: min(Self.range.upperBound, max(Self.range.lowerBound, padding)))
    }
}

/// The named presets. `default` removes both keys.
nonisolated enum SpacingPreset: String, CaseIterable, Sendable, Identifiable {
    case `default`
    case small
    case tiny
    case none

    var id: String { rawValue }

    /// Values written, nil for `default` (keys removed).
    var values: SpacingValues? {
        switch self {
        case .default: nil
        case .small: SpacingValues(spacing: 10, padding: 8)
        case .tiny: SpacingValues(spacing: 6, padding: 4)
        case .none: SpacingValues(spacing: 0, padding: 0)
        }
    }
}

/// What the stored keys amount to.
nonisolated enum SpacingChoice: Equatable, Sendable {
    case preset(SpacingPreset)
    /// Values that match no preset (custom, or written by another tool).
    case custom(SpacingValues)
}

/// The two keys as read from the preferences (nil = absent).
nonisolated struct SpacingReading: Equatable, Sendable {
    var spacing: Int?
    var padding: Int?

    static let absent = SpacingReading(spacing: nil, padding: nil)

    var isAbsent: Bool { spacing == nil && padding == nil }

    /// What apps use: an absent key means the system default.
    var effective: SpacingValues {
        SpacingValues(spacing: spacing ?? SpacingValues.systemDefault.spacing,
                      padding: padding ?? SpacingValues.systemDefault.padding)
    }

    var choice: SpacingChoice {
        if isAbsent { return .preset(.default) }
        if spacing != nil, padding != nil,
           let preset = SpacingPreset.allCases.first(where: { $0.values == effective }) {
            return .preset(preset)
        }
        return .custom(effective)
    }

    /// Whether the keys hold values Rolltop did not write (another app, Terminal, an older
    /// choice made outside Rolltop). `lastApplied` is what Rolltop last wrote, nil if it removed
    /// the keys or never wrote them.
    func isSetElsewhere(lastApplied: SpacingValues?) -> Bool {
        guard !isAbsent else { return false }
        guard let lastApplied else { return true }
        return spacing != lastApplied.spacing || padding != lastApplied.padding
    }
}

nonisolated enum SpacingEstimate {
    /// Width of a typical status item icon, points.
    static let typicalItemWidth = 22.0

    /// Roughly how many more items fit on a bar holding `itemCount` items when the gap
    /// per item shrinks from the default to `values.spacing`. Selection padding only
    /// changes the highlight, so it is not counted.
    static func extraItems(itemCount: Int, values: SpacingValues?) -> Int {
        guard let values, itemCount > 0 else { return 0 }
        let saved = Double(itemCount) * Double(SpacingValues.systemDefault.spacing - values.spacing)
        guard saved > 0 else { return 0 }
        return Int((saved / (typicalItemWidth + Double(max(0, values.spacing)))).rounded(.down))
    }
}
