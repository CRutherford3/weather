import Foundation
import CoreLocation

/// A place the app shows weather for.
struct Place: Codable, Hashable, Identifiable {
    var name: String
    var lat: Double
    var lon: Double
    var id: String { String(format: "%.3f,%.3f", lat, lon) }
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }

    static let atlanta = Place(name: "Atlanta, GA", lat: 33.749, lon: -84.388)
}

enum Units: String, Codable, CaseIterable {
    case imperial, metric
    var tempSymbol: String { self == .imperial ? "°F" : "°C" }
    var windLabel: String { self == .imperial ? "mph" : "km/h" }
}

// MARK: - Open-Meteo forecast (values come back already in the chosen units)

struct Forecast: Decodable {
    struct Current: Decodable {
        let time: String
        let temperature_2m: Double
        let apparent_temperature: Double?
        let relative_humidity_2m: Double?
        let weather_code: Int
        let is_day: Int
        let wind_speed_10m: Double?
        let wind_direction_10m: Double?
        let wind_gusts_10m: Double?
        let pressure_msl: Double?
        let uv_index: Double?
        let dew_point_2m: Double?
        let visibility: Double?
    }
    struct Hourly: Decodable {
        let time: [String]
        let temperature_2m: [Double?]
        let precipitation_probability: [Int?]
        let weather_code: [Int?]
        let is_day: [Int?]
        let wind_speed_10m: [Double?]
    }
    struct Daily: Decodable {
        let time: [String]
        let weather_code: [Int?]
        let temperature_2m_max: [Double?]
        let temperature_2m_min: [Double?]
        let precipitation_probability_max: [Int?]
        let sunrise: [String]
        let sunset: [String]
        let uv_index_max: [Double?]
        let wind_speed_10m_max: [Double?]
    }
    let utc_offset_seconds: Int
    let current: Current
    let hourly: Hourly
    let daily: Daily

    /// Index of the current hour in `hourly`.
    var nowIndex: Int {
        let prefix = String(current.time.prefix(13))
        return hourly.time.firstIndex { $0.hasPrefix(prefix) } ?? 0
    }
}

// MARK: - NWS alerts

struct AlertsResponse: Decodable {
    struct Feature: Decodable { let properties: WeatherAlert }
    let features: [Feature]
}

struct WeatherAlert: Decodable, Identifiable, Hashable {
    let id: String
    let event: String
    let headline: String?
    let severity: String?
    let description: String?
    let instruction: String?
    let ends: String?
    let expires: String?
    let senderName: String?

    var isWarning: Bool { event.localizedCaseInsensitiveContains("warning") }
}

// MARK: - Weather codes (WMO) to text and SF Symbols

enum WX {
    static func text(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly Clear"
        case 2: return "Partly Cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing Drizzle"
        case 61: return "Light Rain"
        case 63: return "Rain"
        case 65: return "Heavy Rain"
        case 66, 67: return "Freezing Rain"
        case 71: return "Light Snow"
        case 73: return "Snow"
        case 75: return "Heavy Snow"
        case 77: return "Snow Grains"
        case 80, 81: return "Showers"
        case 82: return "Heavy Showers"
        case 85, 86: return "Snow Showers"
        case 95: return "Thunderstorms"
        case 96, 99: return "Severe Storms"
        default: return "—"
        }
    }

    static func symbol(_ code: Int, day: Bool = true) -> String {
        switch code {
        case 0: return day ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 80, 81: return "cloud.rain.fill"
        case 65, 82: return "cloud.heavyrain.fill"
        case 66, 67: return "cloud.sleet.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}

// MARK: - Formatting helpers

enum Fmt {
    static func temp(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))°" } ?? "--" }

    static func compass(_ deg: Double?) -> String {
        guard let d = deg else { return "" }
        let dirs = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        return dirs[Int((d / 22.5).rounded()) % 16]
    }

    /// Open-Meteo local times look like 2026-11-09T14:00 (no zone); parse them as the location's local time.
    static func date(_ s: String, offset: Int) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: offset)
        f.dateFormat = s.count > 10 ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd"
        return f.date(from: s)
    }

    static func hour(_ s: String, offset: Int) -> String {
        guard let d = date(s, offset: offset) else { return "" }
        let f = DateFormatter(); f.timeZone = TimeZone(secondsFromGMT: offset); f.dateFormat = "ha"
        return f.string(from: d).lowercased()
    }

    static func weekday(_ s: String, offset: Int) -> String {
        guard let d = date(s, offset: offset) else { return "" }
        let f = DateFormatter(); f.timeZone = TimeZone(secondsFromGMT: offset); f.dateFormat = "EEE"
        return f.string(from: d)
    }

    static func time(_ s: String, offset: Int) -> String {
        guard let d = date(s, offset: offset) else { return "" }
        let f = DateFormatter(); f.timeZone = TimeZone(secondsFromGMT: offset); f.dateFormat = "h:mm a"
        return f.string(from: d)
    }
}
