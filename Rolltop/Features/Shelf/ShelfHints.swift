import Foundation

// Hints: a small expansion of the shelf that says what just changed (volume, brightness,
// battery) and collapses after `ShelfHintSchedule.duration`. Pure parts here, tested in
// RolltopTests/Shelf/ShelfRound2Tests.swift.

/// What a hint is about. `notice` carries a message of the shelf itself (a clip that was
/// copied but not pasted); notices ignore the hint switches.
nonisolated enum ShelfHintSource: String, Sendable, CaseIterable {
    case volume
    case brightness
    case battery
    case notice
}

nonisolated struct ShelfHint: Equatable, Sendable {
    var source: ShelfHintSource
    var symbol: String
    var title: String
    /// 0…1 draws a level bar; nil draws none.
    var level: Double?

    static func volume(_ reading: ShelfVolumeReading) -> ShelfHint {
        if reading.isMuted {
            return ShelfHint(source: .volume, symbol: "speaker.slash.fill",
                             title: String(localized: "Muted", table: "Shelf"), level: 0)
        }
        let symbol = reading.level <= 0.001 ? "speaker.fill"
            : reading.level < 0.34 ? "speaker.wave.1.fill" : reading.level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        return ShelfHint(source: .volume, symbol: symbol,
                         title: String(localized: "Volume \(ShelfHintFormat.percent(reading.level))", table: "Shelf"),
                         level: Double(reading.level))
    }

    static func brightness(_ level: Float) -> ShelfHint {
        ShelfHint(source: .brightness, symbol: level < 0.5 ? "sun.min.fill" : "sun.max.fill",
                  title: String(localized: "Brightness \(ShelfHintFormat.percent(level))", table: "Shelf"),
                  level: Double(level))
    }

    static func battery(_ event: ShelfBatteryEvent) -> ShelfHint {
        switch event {
        case .pluggedIn(let percent):
            ShelfHint(source: .battery, symbol: "battery.100percent.bolt",
                      title: String(localized: "Charging · \(percent)%", table: "Shelf"), level: Double(percent) / 100)
        case .unplugged(let percent):
            ShelfHint(source: .battery, symbol: "battery.75percent",
                      title: String(localized: "On battery · \(percent)%", table: "Shelf"), level: Double(percent) / 100)
        case .charged:
            ShelfHint(source: .battery, symbol: "battery.100percent",
                      title: String(localized: "Fully charged", table: "Shelf"), level: 1)
        case .low(let percent):
            ShelfHint(source: .battery, symbol: "battery.25percent",
                      title: String(localized: "Battery low · \(percent)%", table: "Shelf"), level: Double(percent) / 100)
        }
    }

    static func notice(_ text: String, symbol: String = "doc.on.clipboard") -> ShelfHint {
        ShelfHint(source: .notice, symbol: symbol, title: text, level: nil)
    }
}

nonisolated enum ShelfHintFormat {
    /// "40 %" in the user's locale; levels are rounded to whole percent.
    static func percent(_ level: Float, locale: Locale = .current) -> String {
        let clamped = Double(min(max(level, 0), 1))
        return clamped.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }
}

/// The hint switches (Settings › Shelf › Hints).
nonisolated struct ShelfHintConfig: Sendable, Equatable {
    var enabled = true
    var volume = true
    var brightness = true
    var battery = true

    func allows(_ source: ShelfHintSource) -> Bool {
        switch source {
        case .notice: true
        case .volume: enabled && volume
        case .brightness: enabled && brightness
        case .battery: enabled && battery
        }
    }
}

/// Coalescing and timing: the first hint of a burst presents the window, later ones update
/// it in place and push the deadline out; it hides `duration` after the last one.
nonisolated struct ShelfHintSchedule: Sendable, Equatable {
    static let duration: TimeInterval = 1.5

    enum Action: Equatable, Sendable {
        case present
        case update
    }

    private(set) var current: ShelfHint?
    private(set) var hideAt: Date?

    mutating func post(_ hint: ShelfHint, now: Date) -> Action {
        let action: Action = current == nil ? .present : .update
        current = hint
        hideAt = now.addingTimeInterval(Self.duration)
        return action
    }

    /// True when the hint is due to hide (and clears it).
    mutating func expire(now: Date) -> Bool {
        guard let hideAt, now >= hideAt else { return false }
        current = nil
        self.hideAt = nil
        return true
    }

    mutating func reset() {
        current = nil
        hideAt = nil
    }
}

// MARK: - Readings

nonisolated struct ShelfVolumeReading: Equatable, Sendable, Codable {
    /// 0…1.
    var level: Float
    var isMuted: Bool
}

nonisolated struct ShelfBatteryReading: Equatable, Sendable, Codable {
    var onPower: Bool
    var percent: Int
    var isCharged: Bool
}

nonisolated enum ShelfBatteryEvent: Equatable, Sendable {
    case pluggedIn(Int)
    case unplugged(Int)
    case charged
    case low(Int)

    static let lowThresholds = [10, 20]

    /// Which transitions produce a hint. Nil before the first reading (launch) and on a Mac
    /// without a battery (no readings at all).
    static func classify(from old: ShelfBatteryReading?, to new: ShelfBatteryReading) -> ShelfBatteryEvent? {
        guard let old else { return nil }
        if !old.onPower, new.onPower { return .pluggedIn(new.percent) }
        if old.onPower, !new.onPower { return .unplugged(new.percent) }
        if new.onPower, !old.isCharged, new.isCharged { return .charged }
        if !new.onPower {
            for threshold in lowThresholds where old.percent > threshold && new.percent <= threshold {
                return .low(threshold)
            }
        }
        return nil
    }
}
