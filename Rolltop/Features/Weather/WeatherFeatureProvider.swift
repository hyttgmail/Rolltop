import AppKit
import Foundation
import Observation
import RolltopCore

enum WeatherFeatureSettings {
    /// Off by default: while off nothing is sent anywhere.
    static let enabled = SettingsKey<Bool>("rolltop.weather.enabled", default: false)
    /// The chosen place (name and coordinates rounded to 2 decimals). Exported with the
    /// other settings on purpose: it is the user's choice.
    static let place = SettingsKey<WeatherFeaturePlace?>("rolltop.weather.place", default: nil)
    /// Fixed refresh interval; a failed refresh tries again at the next one.
    static let refreshInterval: TimeInterval = 30 * 60
    /// `refresh()` and wake fetch at most this often.
    static let minimumInterval: TimeInterval = 60
}

/// Loads a URL. The app uses `WeatherFeatureSession`; tests pass a fake.
protocol WeatherFeatureFetching: AnyObject {
    func data(from url: URL) async throws -> Data
}

/// An ephemeral session: 15 s timeout, no cookies, no cache, the app's default User-Agent.
final class WeatherFeatureSession: WeatherFeatureFetching {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func data(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WeatherOpenMeteo.Failure.http(http.statusCode)
        }
        // Shorter than announced: cut on the way (the decoder catches undeclared cuts).
        if response.expectedContentLength > 0, Int64(data.count) < response.expectedContentLength {
            throw WeatherOpenMeteo.Failure.incomplete
        }
        return data
    }
}

/// `services[.weather]`: the current weather for the chosen place from Open-Meteo.
/// Off by default; while off or without a place it sends nothing and runs no timer.
@Observable
final class WeatherFeatureProvider: WeatherProviding {
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let fetcher: any WeatherFeatureFetching
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let log = Log.logger("weather")
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var scheduledPlace: WeatherFeaturePlace?
    @ObservationIgnored private var schedule: Task<Void, Never>?
    @ObservationIgnored private var settingsObserver: ChangeObserver?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    private var fetched: WeatherReport?
    private var fetchError: String?
    private var requestsInFlight = 0
    var isFetching: Bool { requestsInFlight > 0 }
    #if DEBUG
    /// `weather.debug-inject`: a sample shown as if weather were on (memory only).
    var injected: WeatherReport?
    #endif

    init(settings: SettingsStore, fetcher: any WeatherFeatureFetching, now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.fetcher = fetcher
        self.now = now
    }

    // MARK: WeatherProviding

    var isEnabled: Bool { settings[WeatherFeatureSettings.enabled] || isInjected }

    var report: WeatherReport? {
        #if DEBUG
        if let injected { return injected }
        #endif
        return settings[WeatherFeatureSettings.enabled] ? fetched : nil
    }

    var lastError: String? {
        guard !isInjected, settings[WeatherFeatureSettings.enabled] else { return nil }
        guard place != nil else { return Self.choosePlaceMessage }
        return fetchError
    }

    func refresh() async {
        await fetch(minimumInterval: WeatherFeatureSettings.minimumInterval)
    }

    // MARK: Feature side

    var place: WeatherFeaturePlace? { settings[WeatherFeatureSettings.place] }

    static var choosePlaceMessage: String {
        String(localized: "Choose a place in Settings › Weather.", table: "Weather")
    }

    func start() {
        settingsObserver = ChangeObserver(track: { [settings] in
            _ = settings[WeatherFeatureSettings.enabled]
            _ = settings[WeatherFeatureSettings.place]
        }) { [weak self] in self?.update() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh() }
            }
        }
        update()
    }

    func stop() {
        settingsObserver?.cancel()
        settingsObserver = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        schedule?.cancel()
        schedule = nil
    }

    /// Applies the switch and the place: starts or stops the timer, fetches on enable and
    /// on place change, forgets the report when turned off.
    func update() {
        guard settings[WeatherFeatureSettings.enabled] else {
            schedule?.cancel()
            schedule = nil
            scheduledPlace = nil
            lastAttempt = nil
            fetched = nil
            fetchError = nil
            return
        }
        let place = place
        guard place != scheduledPlace || schedule == nil else { return }
        scheduledPlace = place
        fetched = nil
        fetchError = nil
        lastAttempt = nil
        schedule?.cancel()
        schedule = nil
        guard place != nil else { return }
        schedule = Task { [weak self] in
            await self?.fetch(minimumInterval: 0)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(WeatherFeatureSettings.refreshInterval))
                guard !Task.isCancelled else { return }
                await self?.fetch(minimumInterval: WeatherFeatureSettings.minimumInterval)
            }
        }
    }

    /// One request, only while on with a place, at most once per `minimumInterval`.
    /// A failure keeps the last report and sets `lastError`.
    func fetch(minimumInterval: TimeInterval) async {
        guard settings[WeatherFeatureSettings.enabled], let place else { return }
        let start = now()
        if let lastAttempt, start.timeIntervalSince(lastAttempt) < minimumInterval { return }
        lastAttempt = start
        requestsInFlight += 1
        defer { requestsInFlight -= 1 }
        let url = WeatherOpenMeteo.forecastURL(latitude: place.latitude, longitude: place.longitude)
        do {
            let data = try await fetcher.data(from: url)
            let report = try WeatherOpenMeteo.decodeForecast(data, placeName: place.name, fetchedAt: now())
            guard settings[WeatherFeatureSettings.enabled], self.place == place else { return }
            fetched = report
            fetchError = nil
            log.info("weather: report updated")
        } catch {
            guard settings[WeatherFeatureSettings.enabled], self.place == place else { return }
            fetchError = Self.message(for: error)
            log.notice("weather: refresh failed (\(Self.kind(of: error)))")
        }
    }

    /// Searches places by name (what the user typed goes to Open-Meteo's geocoding).
    func searchPlaces(_ query: String) async throws -> [WeatherFeaturePlace] {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        guard let url = WeatherOpenMeteo.searchURL(query: query, language: language) else { return [] }
        return try WeatherOpenMeteo.decodePlaces(await fetcher.data(from: url))
    }

    private var isInjected: Bool {
        #if DEBUG
        injected != nil
        #else
        false
        #endif
    }

    static func message(for error: Error) -> String {
        if error is WeatherOpenMeteo.Failure {
            String(localized: "Open-Meteo sent an incomplete answer. Rolltop will try again.", table: "Weather")
        } else {
            String(localized: "Couldn’t reach Open-Meteo. Rolltop will try again.", table: "Weather")
        }
    }

    private static func kind(of error: Error) -> String {
        switch error {
        case WeatherOpenMeteo.Failure.incomplete: "incomplete"
        case WeatherOpenMeteo.Failure.http(let code): "http \(code)"
        case let error as URLError: "url error \(error.code.rawValue)"
        default: "other"
        }
    }
}
