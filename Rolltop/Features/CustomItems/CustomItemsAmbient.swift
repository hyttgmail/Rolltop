import AppKit
import Foundation

// Widgets fed by other features' services (docs/CONTRACTS.md, Services): what is playing
// (`.nowPlaying`), the next calendar event (`.upNext`), Focus (`.focusState`) and the
// weather (`.weather`), plus the GPU reading. Widgets only read these services: none of
// their members prompts, and nothing here touches a protected API.

/// A value copy of the service members the widgets show, taken on the main thread.
nonisolated struct CustomItemsAmbient: Equatable, Sendable {
    var nowPlaying: NowPlayingState?
    var canControl = false
    var calendarAuthorized = false
    var nextEvent: UpNextEvent?
    /// nil: Rolltop cannot tell (never shown as "off").
    var isFocused: Bool?
    var focusLabel: String?
    var weatherEnabled = false
    var weather: WeatherReport?
    /// When the calendar was last read (the lookahead counts from here).
    var checkedAt = Date()

    /// Copies the members `source` shows from `snapshot`.
    mutating func take(_ source: CustomItemWidgetSource, from snapshot: CustomItemsAmbient) {
        switch source {
        case .music:
            nowPlaying = snapshot.nowPlaying
            canControl = snapshot.canControl
        case .calendar:
            calendarAuthorized = snapshot.calendarAuthorized
            nextEvent = snapshot.nextEvent
            checkedAt = snapshot.checkedAt
        case .focus:
            isFocused = snapshot.isFocused
            focusLabel = snapshot.focusLabel
        case .weather:
            weatherEnabled = snapshot.weatherEnabled
            weather = snapshot.weather
        default:
            break
        }
    }
}

/// Reads the four services now (main thread; every member is a cheap, non-prompting read).
enum CustomItemsAmbientReader {
    static func read(_ services: ServiceLocator) -> CustomItemsAmbient {
        let nowPlaying = services[.nowPlaying]
        let upNext = services[.upNext]
        let focus = services[.focusState]
        let weather = services[.weather]
        return CustomItemsAmbient(nowPlaying: nowPlaying.state, canControl: nowPlaying.canControl,
                                  calendarAuthorized: upNext.isAuthorized, nextEvent: upNext.nextEvent,
                                  isFocused: focus.isFocused, focusLabel: focus.label,
                                  weatherEnabled: weather.isEnabled, weather: weather.report, checkedAt: Date())
    }
}

/// Texts of the service-fed widgets (pure).
nonisolated enum CustomItemsAmbientText {
    /// Music titles are capped: automatic widths only grow while the item runs.
    static let musicLimit = 32
    /// Only events that start within this many seconds are shown.
    static let calendarLookahead: TimeInterval = 24 * 3600

    /// "Title – Artist", or the title alone, capped at `limit` characters with an ellipsis.
    static func music(_ state: NowPlayingState, limit: Int = musicLimit) -> String {
        let artist = state.artist?.trimmingCharacters(in: .whitespaces) ?? ""
        let full = artist.isEmpty ? state.title : "\(state.title) – \(artist)"
        guard full.count > limit, limit > 1 else { return full }
        return full.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The event to show: authorized, timed, not ended, starting within the lookahead.
    static func event(_ event: UpNextEvent?, authorized: Bool, now: Date,
                      lookahead: TimeInterval = calendarLookahead) -> UpNextEvent? {
        guard authorized, let event, !event.isAllDay, event.end > now,
              event.start <= now.addingTimeInterval(lookahead) else { return nil }
        return event
    }

    /// The locale's short time pattern ("HH:mm", "h:mm a").
    static var timeFormat: String {
        DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: .autoupdatingCurrent) ?? "HH:mm"
    }

    /// "10:30 Standup".
    static func calendar(_ event: UpNextEvent, timeFormat: String = timeFormat, timeZone: TimeZone? = nil) -> String {
        "\(CustomItemsClock.text(for: event.start, format: timeFormat, timeZone: timeZone)) \(event.title)"
    }

    /// The Focus's name while one is known to be on; nil (the quiet state) otherwise,
    /// including when Rolltop cannot tell.
    static func focus(isFocused: Bool?, label: String?) -> String? {
        guard isFocused == true else { return nil }
        let trimmed = label?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? String(localized: "Focus", table: "CustomItems") : trimmed
    }

    /// "18°" in the user's unit.
    static func temperature(_ value: Measurement<UnitTemperature>, locale: Locale = .autoupdatingCurrent) -> String {
        value.formatted(.measurement(width: .narrow, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0)))
            .locale(locale))
    }
}

/// What a left click on a widget whose click is set to its default ("Show details") does.
nonisolated enum CustomItemsAmbientClick: Equatable {
    case details
    case playPause
    case openPane(String)

    static func action(for source: CustomItemWidgetSource, canControl: Bool) -> Self {
        switch source {
        case .music: canControl ? .playPause : .openPane("permissions")
        case .weather: .openPane("weather")
        default: .details
        }
    }
}

/// GPU usage from `IOAccelerator` services' `PerformanceStatistics` (pure part).
nonisolated enum CustomItemsGPUMath {
    static let utilizationKey = "Device Utilization %"

    /// The busiest accelerator's utilization, 0…1; nil when none reports the key.
    static func utilization(from statistics: [[String: Any]]) -> Double? {
        let values = statistics.compactMap { ($0[utilizationKey] as? NSNumber)?.doubleValue }.filter(\.isFinite)
        return values.max().map { min(max($0 / 100, 0), 1) }
    }
}

#if DEBUG
// Sample providers for `custom-items.debug-inject` (live tests without the real services).

final class CustomItemsSampleNowPlaying: NowPlayingProviding {
    var state: NowPlayingState?
    var artwork: NSImage? { nil }
    var canControl: Bool { state != nil }
    init(state: NowPlayingState) { self.state = state }
    func perform(_ command: NowPlayingCommand) async -> Bool {
        guard command == .playPause, state != nil else { return false }
        state?.isPlaying.toggle()
        return true
    }
}

final class CustomItemsSampleUpNext: UpNextProviding {
    let nextEvent: UpNextEvent?
    var isAuthorized: Bool { true }
    init(event: UpNextEvent) { nextEvent = event }
}

final class CustomItemsSampleFocus: FocusStateProviding {
    var isFocused: Bool? { true }
    let label: String?
    var sourceNote: String { "Sample Focus (Debug)" }
    init(label: String?) { self.label = label }
}

final class CustomItemsSampleWeather: WeatherProviding {
    var isEnabled: Bool { true }
    let report: WeatherReport?
    var lastError: String? { nil }
    init(report: WeatherReport) { self.report = report }
    func refresh() async {}
}
#endif
