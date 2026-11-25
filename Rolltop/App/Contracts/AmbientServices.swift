import AppKit
import Foundation
import Observation
import SwiftUI

// Ambient services added in round 2: what is playing, the weather, the next calendar
// event and Focus. Each has a protocol, value types, a default that knows nothing, and a
// `ServiceKey`. Providers register in `init(context:)`; consumers resolve at use time
// (`context.services[.weather].report`). Implementations are `@Observable`, so SwiftUI and
// `ChangeObserver` follow every member. No member of these protocols may raise a system
// prompt, launch an app or touch a protected resource the user has not allowed
// (docs/CONTRACTS.md, "Consent rows"). Type names taken here: `NowPlaying…`, `Weather…`
// (`WeatherCondition`, `WeatherReport`, `WeatherAttribution`, `WeatherProviding`,
// `WeatherUnavailable`), `UpNext…`, `FocusState…`.

// MARK: - Now playing (provided by Media; used by Shelf and CustomItems)

/// A player Rolltop can read and control through Apple Events.
nonisolated enum NowPlayingPlayer: String, Sendable, CaseIterable, Codable {
    case music = "com.apple.Music"
    case spotify = "com.spotify.client"

    var bundleID: String { rawValue }

    /// The app's name ("Music" is Apple's name for the app).
    var displayName: String {
        switch self {
        case .music: String(localized: "Music", table: "UI", comment: "Apple's Music app")
        case .spotify: String(localized: "Spotify", table: "UI", comment: "The Spotify app")
        }
    }
}

/// The track a player reports. The artwork is a separate member of the provider
/// (`NowPlayingProviding.artwork`), so this stays `Sendable` and compares by value.
nonisolated struct NowPlayingState: Equatable, Sendable {
    var player: NowPlayingPlayer
    var title: String
    var artist: String?
    var album: String?
    /// Playing (true) or paused (false).
    var isPlaying: Bool

    init(player: NowPlayingPlayer, title: String, artist: String? = nil, album: String? = nil, isPlaying: Bool) {
        self.player = player
        self.title = title
        self.artist = artist
        self.album = album
        self.isPlaying = isPlaying
    }

    #if DEBUG
    static let sample = NowPlayingState(player: .music, title: "Clair de lune", artist: "Claude Debussy",
                                        album: "Suite bergamasque", isPlaying: true)
    #endif
}

/// What `perform` asks the player to do.
nonisolated enum NowPlayingCommand: String, Sendable, CaseIterable {
    case playPause = "play-pause"
    case next
    case previous
}

/// What is playing in Music or Spotify, and transport controls.
///
/// Rules for the provider: it never launches a player (a player that is not running has
/// nothing playing), and none of these members raises a prompt. Reading a player needs its
/// Apple Events consent, which is asked only from the player's consent row; without it
/// `state` is nil and `canControl` false.
protocol NowPlayingProviding: AnyObject {
    /// The track of the player that played most recently, nil when nothing is known.
    var state: NowPlayingState? { get }
    /// Artwork of `state`'s track, nil when the player gives none (or not yet loaded).
    var artwork: NSImage? { get }
    /// `state`'s player can be controlled (its Apple Events consent is there and it runs).
    /// False when `state` is nil.
    var canControl: Bool { get }
    /// Sends the command to `state`'s player. False when nothing is playing, control is not
    /// allowed, the player is not running (it is never launched) or the call failed.
    func perform(_ command: NowPlayingCommand) async -> Bool
}

/// Default before Media registers: nothing is playing.
final class NowPlayingNone: NowPlayingProviding {
    var state: NowPlayingState? { nil }
    var artwork: NSImage? { nil }
    var canControl: Bool { false }
    func perform(_ command: NowPlayingCommand) async -> Bool { false }
}

extension ServiceKey where Service == any NowPlayingProviding {
    static var nowPlaying: Self { .init("media.now-playing") { _ in NowPlayingNone() } }
}

// MARK: - Weather (provided by Weather; used by Shelf and CustomItems)

/// Weather condition from an Open-Meteo `weather_code` (WMO code table 4677 subset that
/// Open-Meteo documents). Intensities are folded into one case per kind.
nonisolated enum WeatherCondition: String, Sendable, CaseIterable, Codable {
    case clear                  // 0
    case mainlyClear            // 1
    case partlyCloudy           // 2
    case overcast               // 3
    case fog                    // 45, 48 (depositing rime fog)
    case drizzle                // 51, 53, 55
    case freezingDrizzle        // 56, 57
    case rain                   // 61, 63, 65
    case freezingRain           // 66, 67
    case snow                   // 71, 73, 75, 77 (snow grains)
    case rainShowers            // 80, 81, 82
    case snowShowers            // 85, 86
    case thunderstorm           // 95
    case thunderstormWithHail   // 96, 99
    /// Any other code (Open-Meteo documents none).
    case unknown

    init(wmoCode: Int) {
        self = switch wmoCode {
        case 0: .clear
        case 1: .mainlyClear
        case 2: .partlyCloudy
        case 3: .overcast
        case 45, 48: .fog
        case 51, 53, 55: .drizzle
        case 56, 57: .freezingDrizzle
        case 61, 63, 65: .rain
        case 66, 67: .freezingRain
        case 71, 73, 75, 77: .snow
        case 80, 81, 82: .rainShowers
        case 85, 86: .snowShowers
        case 95: .thunderstorm
        case 96, 99: .thunderstormWithHail
        default: .unknown
        }
    }

    /// An SF Symbol (multicolour-capable `.fill` variants) for day or night. Every name is
    /// checked by a unit test.
    func symbolName(isDaylight: Bool) -> String {
        switch self {
        case .clear: isDaylight ? "sun.max.fill" : "moon.stars.fill"
        case .mainlyClear, .partlyCloudy: isDaylight ? "cloud.sun.fill" : "cloud.moon.fill"
        case .overcast: "cloud.fill"
        case .fog: "cloud.fog.fill"
        case .drizzle: "cloud.drizzle.fill"
        case .freezingDrizzle, .freezingRain: "cloud.sleet.fill"
        case .rain: "cloud.rain.fill"
        case .snow: "cloud.snow.fill"
        case .rainShowers: isDaylight ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case .snowShowers: "cloud.snow.fill"
        case .thunderstorm: isDaylight ? "cloud.bolt.rain.fill" : "cloud.moon.bolt.fill"
        case .thunderstormWithHail: "cloud.hail.fill"
        case .unknown: "thermometer.medium"
        }
    }

    /// Localized name ("Partly cloudy"), sentence case.
    var localizedName: String {
        switch self {
        case .clear: String(localized: "Clear", table: "UI", comment: "Weather condition")
        case .mainlyClear: String(localized: "Mainly clear", table: "UI", comment: "Weather condition")
        case .partlyCloudy: String(localized: "Partly cloudy", table: "UI", comment: "Weather condition")
        case .overcast: String(localized: "Overcast", table: "UI", comment: "Weather condition")
        case .fog: String(localized: "Fog", table: "UI", comment: "Weather condition")
        case .drizzle: String(localized: "Drizzle", table: "UI", comment: "Weather condition")
        case .freezingDrizzle: String(localized: "Freezing drizzle", table: "UI", comment: "Weather condition")
        case .rain: String(localized: "Rain", table: "UI", comment: "Weather condition")
        case .freezingRain: String(localized: "Freezing rain", table: "UI", comment: "Weather condition")
        case .snow: String(localized: "Snow", table: "UI", comment: "Weather condition")
        case .rainShowers: String(localized: "Rain showers", table: "UI", comment: "Weather condition")
        case .snowShowers: String(localized: "Snow showers", table: "UI", comment: "Weather condition")
        case .thunderstorm: String(localized: "Thunderstorm", table: "UI", comment: "Weather condition")
        case .thunderstormWithHail: String(localized: "Thunderstorm with hail", table: "UI", comment: "Weather condition")
        case .unknown: String(localized: "Unknown conditions", table: "UI", comment: "Weather condition")
        }
    }
}

/// Current weather at one place.
nonisolated struct WeatherReport: Equatable, Sendable {
    /// The place the user chose, or a coarse name for the current location.
    var placeName: String
    var temperature: Measurement<UnitTemperature>
    /// "Feels like".
    var apparentTemperature: Measurement<UnitTemperature>
    var condition: WeatherCondition
    var isDaylight: Bool
    var todayHigh: Measurement<UnitTemperature>
    var todayLow: Measurement<UnitTemperature>
    var windSpeed: Measurement<UnitSpeed>
    /// Where the wind comes from, degrees clockwise from north; nil when calm or unknown.
    var windDirectionDegrees: Double?
    var fetchedAt: Date

    /// `condition.symbolName(isDaylight:)`.
    var symbolName: String { condition.symbolName(isDaylight: isDaylight) }

    #if DEBUG
    /// Greenwich, a fixed public place (tests never use the user's location).
    static let sample = WeatherReport(
        placeName: "Greenwich", temperature: Measurement(value: 12.4, unit: .celsius),
        apparentTemperature: Measurement(value: 10.1, unit: .celsius), condition: .partlyCloudy, isDaylight: true,
        todayHigh: Measurement(value: 14.0, unit: .celsius), todayLow: Measurement(value: 7.5, unit: .celsius),
        windSpeed: Measurement(value: 18, unit: .kilometersPerHour), windDirectionDegrees: 240,
        fetchedAt: Date(timeIntervalSince1970: 1_795_000_000))
    #endif
}

/// The attribution Open-Meteo's licence (CC BY 4.0) requires next to every display of its
/// data: the text as a link to `url`.
nonisolated struct WeatherAttribution: Equatable, Sendable {
    var text: String
    var url: URL

    static var openMeteo: WeatherAttribution {
        WeatherAttribution(text: String(localized: "Weather data by Open-Meteo.com", table: "UI"),
                           url: URL(string: "https://open-meteo.com/")!)
    }
}

/// Current weather for the Shelf and widgets. Off by default; the Weather feature's own
/// switch turns it on (that switch says the approximate location goes to Open-Meteo).
///
/// Every consumer shows `attribution` as a link next to the data (`Link(a.text, destination: a.url)`).
protocol WeatherProviding: AnyObject {
    /// The user turned weather on. While false, `report` is nil and `refresh()` does nothing.
    var isEnabled: Bool { get }
    /// The latest report, nil before the first successful fetch or while disabled.
    var report: WeatherReport? { get }
    /// Why the last refresh failed, short and localized; nil after a success.
    var lastError: String? { get }
    var attribution: WeatherAttribution { get }
    /// Fetches now (the provider also refreshes on its own schedule). Never prompts: a
    /// current-location place without Location access sets `lastError` instead.
    func refresh() async
}

extension WeatherProviding {
    var attribution: WeatherAttribution { .openMeteo }
}

/// Default before Weather registers: disabled, no report.
final class WeatherUnavailable: WeatherProviding {
    var isEnabled: Bool { false }
    var report: WeatherReport? { nil }
    var lastError: String? { nil }
    func refresh() async {}
}

extension ServiceKey where Service == any WeatherProviding {
    static var weather: Self { .init("weather.report") { _ in WeatherUnavailable() } }
}

// MARK: - Up next (provided by Shelf from its calendar code; used by CustomItems)

/// One calendar event.
nonisolated struct UpNextEvent: Identifiable, Equatable, Sendable {
    /// Stable for one occurrence (event id + start).
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    /// sRGB red, green, blue (0…1) of the calendar's colour; nil when unknown.
    var calendarColor: [Double]?

    init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false,
         location: String? = nil, calendarColor: [Double]? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.calendarColor = calendarColor
    }

    /// `calendarColor` as a SwiftUI colour.
    var color: Color? {
        guard let c = calendarColor, c.count >= 3 else { return nil }
        return Color(.sRGB, red: c[0], green: c[1], blue: c[2], opacity: c.count > 3 ? c[3] : 1)
    }

    #if DEBUG
    static let sample = UpNextEvent(id: "sample@1795000000", title: "Design review",
                                    start: Date(timeIntervalSince1970: 1_795_000_000),
                                    end: Date(timeIntervalSince1970: 1_795_001_800),
                                    location: "Room 4", calendarColor: [0.2, 0.5, 0.9])
    #endif
}

/// The next calendar event, from the Calendars access the Shelf already has.
protocol UpNextProviding: AnyObject {
    /// Rolltop may read calendars (full access granted). Reading this never prompts.
    var isAuthorized: Bool { get }
    /// The first timed event that has not ended yet (in progress, or the next to start)
    /// within today and tomorrow; all-day events are never returned. Nil when there is none
    /// or `isAuthorized` is false. Kept current by the provider (calendar changes, and when
    /// the event ends).
    var nextEvent: UpNextEvent? { get }
}

/// Default before Shelf registers: not authorized.
final class UpNextNone: UpNextProviding {
    var isAuthorized: Bool { false }
    var nextEvent: UpNextEvent? { nil }
}

extension ServiceKey where Service == any UpNextProviding {
    static var upNext: Self { .init("shelf.up-next") { _ in UpNextNone() } }
}

// MARK: - Focus (provided by interop in Features/Automation; used by CustomItems)

/// Whether a Focus is on, as far as Rolltop can tell.
protocol FocusStateProviding: AnyObject {
    /// True when a Focus is on, false when none is, nil when Rolltop cannot tell.
    var isFocused: Bool? { get }
    /// The Focus's name when known ("Work").
    var label: String? { get }
    /// One localized sentence the consumer shows to say what `isFocused` is based on
    /// ("Based on the Focus filters that include Rolltop.").
    var sourceNote: String { get }
}

/// Default before interop registers: unknown.
final class FocusStateUnknown: FocusStateProviding {
    var isFocused: Bool? { nil }
    var label: String? { nil }
    var sourceNote: String { String(localized: "Rolltop can’t tell whether a Focus is on.", table: "UI") }
}

extension ServiceKey where Service == any FocusStateProviding {
    static var focusState: Self { .init("interop.focus-state") { _ in FocusStateUnknown() } }
}
