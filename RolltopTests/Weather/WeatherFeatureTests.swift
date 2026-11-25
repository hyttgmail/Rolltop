import Foundation
import RolltopCore
import Testing
@testable import Rolltop

/// Open-Meteo decoding and the provider's guards, on answers recorded for the fixed public
/// coordinates of the Royal Observatory Greenwich (51.4779, -0.0015) on 2026-11-25.
@MainActor
@Suite struct WeatherFeatureTests {
    static let forecast = #"{"latitude":51.472404,"longitude":0.011566162,"generationtime_ms":0.18,"utc_offset_seconds":0,"timezone":"Europe/London","timezone_abbreviation":"GMT","elevation":17.0,"current_units":{"time":"iso8601","interval":"seconds","temperature_2m":"°C","apparent_temperature":"°C","weather_code":"wmo code","wind_speed_10m":"km/h","wind_direction_10m":"°","is_day":""},"current":{"time":"2026-11-25T09:45","interval":900,"temperature_2m":5.2,"apparent_temperature":1.9,"weather_code":3,"wind_speed_10m":9.4,"wind_direction_10m":42,"is_day":1},"daily_units":{"time":"iso8601","temperature_2m_max":"°C","temperature_2m_min":"°C"},"daily":{"time":["2026-11-25"],"temperature_2m_max":[6.2],"temperature_2m_min":[3.9]}}"#
    static let search = #"{"results":[{"id":2648110,"name":"Greenwich","latitude":51.4779,"longitude":-0.0015,"feature_code":"PPLX","country_code":"GB","country":"United Kingdom","admin1":"England"}],"generationtime_ms":0.29}"#
    static let greenwich = WeatherFeaturePlace(name: "Greenwich", region: "England", country: "United Kingdom",
                                               latitude: 51.48, longitude: 0)

    @Test func decodesARecordedForecast() throws {
        let report = try WeatherOpenMeteo.decodeForecast(Data(Self.forecast.utf8), placeName: "Greenwich",
                                                         fetchedAt: Date(timeIntervalSince1970: 0))
        #expect(report.temperature == Measurement(value: 5.2, unit: .celsius))
        #expect(report.todayHigh.value == 6.2 && report.todayLow.value == 3.9)
        #expect(report.condition == .overcast)
        #expect(report.isDaylight)
        #expect(report.windDirectionDegrees == 42)
        // The report carries units, so consumers format it in the user's unit.
        #expect(report.temperature.converted(to: .fahrenheit).value.rounded() == 41)
    }

    @Test func aCutBodyIsAFailureNotAnEmptyAnswer() {
        for body in [Self.forecast, Self.search] {
            let cut = Data(body.utf8.prefix(body.utf8.count - 20))
            #expect(throws: WeatherOpenMeteo.Failure.incomplete) {
                _ = try WeatherOpenMeteo.decodeForecast(cut, placeName: "x", fetchedAt: .now)
            }
            #expect(throws: WeatherOpenMeteo.Failure.incomplete) { _ = try WeatherOpenMeteo.decodePlaces(cut) }
        }
    }

    @Test func placesAreRoundedToTwoDecimalsBeforeTheyAreStoredOrSent() throws {
        let places = try WeatherOpenMeteo.decodePlaces(Data(Self.search.utf8))
        #expect(places == [Self.greenwich])
        #expect(places[0].longitude.sign == .plus, "no negative zero in the URL")
        let url = WeatherOpenMeteo.forecastURL(latitude: 51.4779, longitude: -0.0015).absoluteString
        #expect(url.contains("latitude=51.48&longitude=0.00&"))
    }

    @Test func offOrWithoutAPlaceSendsNothing() async throws {
        let settings = try Self.settings()
        let fetcher = WeatherFeatureFakeFetcher()
        let provider = WeatherFeatureProvider(settings: settings, fetcher: fetcher)
        provider.update()
        await provider.refresh()
        await provider.fetch(minimumInterval: 0)
        #expect(!provider.isEnabled && provider.report == nil && provider.lastError == nil)

        settings[WeatherFeatureSettings.enabled] = true
        provider.update()
        await provider.fetch(minimumInterval: 0)
        #expect(provider.lastError == WeatherFeatureProvider.choosePlaceMessage)
        #expect(fetcher.urls.isEmpty)
    }

    @Test func aFailedRefreshKeepsTheLastReportAndRefreshIsLimitedToOncePerMinute() async throws {
        let settings = try Self.settings()
        settings[WeatherFeatureSettings.enabled] = true
        settings[WeatherFeatureSettings.place] = Self.greenwich
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let fetcher = WeatherFeatureFakeFetcher()
        let provider = WeatherFeatureProvider(settings: settings, fetcher: fetcher, now: { clock })

        fetcher.bodies = [Data(Self.forecast.utf8)]
        await provider.fetch(minimumInterval: 0)
        #expect(provider.report?.placeName == "Greenwich")

        fetcher.bodies = [Data(Self.forecast.utf8.prefix(100))]
        await provider.refresh()
        #expect(fetcher.urls.count == 1, "refresh within a minute sends nothing")

        clock += 61
        await provider.refresh()
        #expect(fetcher.urls.count == 2)
        #expect(provider.report?.temperature.value == 5.2)
        #expect(provider.lastError != nil)

        settings[WeatherFeatureSettings.enabled] = false
        provider.update()
        #expect(provider.report == nil && provider.lastError == nil)
    }

    private static func settings() throws -> SettingsStore {
        SettingsStore(defaults: try #require(UserDefaults(suiteName: "com.alphapengwang.rolltop.tests.\(UUID().uuidString)")))
    }
}

/// Records each URL and answers with the next queued body.
@MainActor
final class WeatherFeatureFakeFetcher: WeatherFeatureFetching {
    var urls: [URL] = []
    var bodies: [Data] = []

    func data(from url: URL) async throws -> Data {
        urls.append(url)
        guard !bodies.isEmpty else { throw URLError(.notConnectedToInternet) }
        return bodies.removeFirst()
    }
}
