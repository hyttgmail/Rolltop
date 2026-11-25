import Foundation

/// A place the user chose for the weather. Coordinates are rounded to 2 decimals (about
/// 1 km) when the place is decoded, so nothing more precise is ever stored or sent. It is a
/// normal exported setting: the user's choice, restored by a backup.
nonisolated struct WeatherFeaturePlace: Codable, Hashable, Sendable {
    var name: String
    var region: String?
    var country: String?
    var latitude: Double
    var longitude: Double

    /// "England, United Kingdom".
    var detail: String {
        [region, country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// Open-Meteo requests and answers (https://open-meteo.com/, no API key, CC BY 4.0).
/// Pure: builds URLs and decodes bodies; the provider does the I/O.
nonisolated enum WeatherOpenMeteo {
    enum Failure: Error, Equatable {
        /// The body is not the complete JSON answer (the local proxy can cut responses).
        case incomplete
        case http(Int)
    }

    /// Rounds a coordinate to `decimals` places; never yields negative zero.
    static func rounded(_ value: Double, decimals: Int) -> Double {
        let factor = pow(10, Double(decimals))
        return (value * factor).rounded() / factor + 0.0
    }

    static func forecastURL(latitude: Double, longitude: Double) -> URL {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", rounded(latitude, decimals: 2))),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", rounded(longitude, decimals: 2))),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m,wind_direction_10m,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "temperature_unit", value: "celsius"),
            URLQueryItem(name: "wind_speed_unit", value: "kmh"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]
        return components.url!
    }

    static func searchURL(query: String, language: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: trimmed),
            URLQueryItem(name: "count", value: "8"),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "format", value: "json"),
        ]
        return components.url
    }

    /// Decodes a forecast answer into a report. Values are requested in °C and km/h;
    /// consumers format the measurements, which follows the user's units.
    static func decodeForecast(_ data: Data, placeName: String, fetchedAt: Date) throws -> WeatherReport {
        let forecast: Forecast
        do {
            forecast = try decoder.decode(Forecast.self, from: data)
        } catch {
            throw Failure.incomplete
        }
        guard let high = forecast.daily.temperature2mMax.first ?? nil,
              let low = forecast.daily.temperature2mMin.first ?? nil else { throw Failure.incomplete }
        let current = forecast.current
        return WeatherReport(
            placeName: placeName,
            temperature: Measurement(value: current.temperature2m, unit: .celsius),
            apparentTemperature: Measurement(value: current.apparentTemperature, unit: .celsius),
            condition: WeatherCondition(wmoCode: current.weatherCode),
            isDaylight: current.isDay != 0,
            todayHigh: Measurement(value: high, unit: .celsius),
            todayLow: Measurement(value: low, unit: .celsius),
            windSpeed: Measurement(value: current.windSpeed10m, unit: .kilometersPerHour),
            windDirectionDegrees: current.windSpeed10m > 0 ? current.windDirection10m : nil,
            fetchedAt: fetchedAt)
    }

    /// Decodes a place search answer. No `results` key means no match; a body that is not
    /// complete JSON throws.
    static func decodePlaces(_ data: Data) throws -> [WeatherFeaturePlace] {
        let answer: SearchAnswer
        do {
            answer = try decoder.decode(SearchAnswer.self, from: data)
        } catch {
            throw Failure.incomplete
        }
        return (answer.results ?? []).map {
            WeatherFeaturePlace(name: $0.name, region: $0.admin1, country: $0.country,
                                latitude: rounded($0.latitude, decimals: 2),
                                longitude: rounded($0.longitude, decimals: 2))
        }
    }

    private static var decoder: JSONDecoder { JSONDecoder() }

    private struct Forecast: Decodable {
        struct Current: Decodable {
            let temperature2m: Double
            let apparentTemperature: Double
            let weatherCode: Int
            let windSpeed10m: Double
            let windDirection10m: Double?
            let isDay: Int

            enum CodingKeys: String, CodingKey {
                case temperature2m = "temperature_2m", apparentTemperature = "apparent_temperature"
                case weatherCode = "weather_code", windSpeed10m = "wind_speed_10m"
                case windDirection10m = "wind_direction_10m", isDay = "is_day"
            }
        }

        struct Daily: Decodable {
            let temperature2mMax: [Double?]
            let temperature2mMin: [Double?]

            enum CodingKeys: String, CodingKey {
                case temperature2mMax = "temperature_2m_max", temperature2mMin = "temperature_2m_min"
            }
        }

        let current: Current
        let daily: Daily
    }

    private struct SearchAnswer: Decodable {
        struct Result: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let country: String?
            let admin1: String?
        }

        let results: [Result]?
        // Present in every complete answer; its absence means the body was cut.
        let generationtimeMs: Double

        enum CodingKeys: String, CodingKey {
            case results, generationtimeMs = "generationtime_ms"
        }
    }
}
