import Foundation
import CoreLocation

/// Talks to the free public weather services: Open-Meteo (forecast, search) and the National Weather Service (alerts).
struct WeatherService {
    static let shared = WeatherService()

    private let http: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpAdditionalHeaders = ["User-Agent": AppConfig.userAgent, "Accept": "application/geo+json, application/json"]
        c.timeoutIntervalForRequest = 20
        c.requestCachePolicy = .reloadRevalidatingCacheData
        return URLSession(configuration: c)
    }()

    private func get<T: Decodable>(_ url: URL, as: T.Type) async throws -> T {
        let (data, resp) = try await http.data(from: url)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func forecast(for p: Place, units: Units) async throws -> Forecast {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", p.lat)),
            .init(name: "longitude", value: String(format: "%.4f", p.lon)),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "16"),
            .init(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,is_day,wind_speed_10m,wind_direction_10m,wind_gusts_10m,pressure_msl,uv_index,dew_point_2m,visibility"),
            .init(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code,is_day,wind_speed_10m"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset,uv_index_max,wind_speed_10m_max"),
        ]
        if units == .imperial {
            c.queryItems! += [.init(name: "temperature_unit", value: "fahrenheit"), .init(name: "wind_speed_unit", value: "mph"), .init(name: "precipitation_unit", value: "inch")]
        }
        return try await get(c.url!, as: Forecast.self)
    }

    func alerts(for p: Place) async -> [WeatherAlert] {
        guard let url = URL(string: String(format: "https://api.weather.gov/alerts/active?point=%.4f,%.4f", p.lat, p.lon)) else { return [] }
        return (try? await get(url, as: AlertsResponse.self).features.map(\.properties)) ?? []
    }

    /// Place search (cities, towns, ZIP codes).
    func search(_ q: String) async -> [Place] {
        struct R: Decodable { struct Item: Decodable { let name: String; let latitude: Double; let longitude: Double; let admin1: String?; let country_code: String? }; let results: [Item]? }
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: q), .init(name: "count", value: "8"), .init(name: "language", value: "en")]
        guard let url = c.url, let r = try? await get(url, as: R.self) else { return [] }
        return (r.results ?? []).map { i in
            let region = i.country_code == "US" ? (i.admin1.map(Self.stateAbbrev) ?? "") : (i.country_code ?? "")
            return Place(name: region.isEmpty ? i.name : "\(i.name), \(region)", lat: i.latitude, lon: i.longitude)
        }
    }

    /// Town name for a coordinate, using Apple's geocoder.
    func placeName(_ lat: Double, _ lon: Double) async -> String {
        let marks = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon))
        guard let m = marks?.first else { return String(format: "%.2f, %.2f", lat, lon) }
        if let city = m.locality, let st = m.administrativeArea { return "\(city), \(st)" }
        if let water = m.ocean ?? m.inlandWater { return water }
        return m.name ?? m.administrativeArea ?? String(format: "%.2f, %.2f", lat, lon)
    }

    static func stateAbbrev(_ s: String) -> String {
        let m = ["Alabama": "AL", "Alaska": "AK", "Arizona": "AZ", "Arkansas": "AR", "California": "CA", "Colorado": "CO", "Connecticut": "CT", "Delaware": "DE", "Florida": "FL", "Georgia": "GA", "Hawaii": "HI", "Idaho": "ID", "Illinois": "IL", "Indiana": "IN", "Iowa": "IA", "Kansas": "KS", "Kentucky": "KY", "Louisiana": "LA", "Maine": "ME", "Maryland": "MD", "Massachusetts": "MA", "Michigan": "MI", "Minnesota": "MN", "Mississippi": "MS", "Missouri": "MO", "Montana": "MT", "Nebraska": "NE", "Nevada": "NV", "New Hampshire": "NH", "New Jersey": "NJ", "New Mexico": "NM", "New York": "NY", "North Carolina": "NC", "North Dakota": "ND", "Ohio": "OH", "Oklahoma": "OK", "Oregon": "OR", "Pennsylvania": "PA", "Rhode Island": "RI", "South Carolina": "SC", "South Dakota": "SD", "Tennessee": "TN", "Texas": "TX", "Utah": "UT", "Vermont": "VT", "Virginia": "VA", "Washington": "WA", "West Virginia": "WV", "Wisconsin": "WI", "Wyoming": "WY", "District of Columbia": "DC", "Puerto Rico": "PR"]
        return m[s] ?? s
    }
}

/// Radar loop frames from Iowa State's NEXRAD mosaic tiles (same source as the website).
enum RadarService {
    struct Frame: Identifiable { let id: Int; let time: Date; let template: String }

    static func frames() async -> [Frame] {
        struct TMS: Decodable { struct S: Decodable { let id: String?; let utc_valid: String? }; let services: [S]? }
        var base = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 300).rounded(.down) * 300 - 300)
        if let url = URL(string: "https://mesonet.agron.iastate.edu/json/tms.json"),
           let data = try? await URLSession.shared.data(from: url).0,
           let tms = try? JSONDecoder().decode(TMS.self, from: data),
           let s = tms.services?.first(where: { ($0.id ?? "").lowercased().contains("n0q") }), let v = s.utc_valid,
           let d = ISO8601DateFormatter().date(from: v) {
            base = d
        }
        let bust = Int(Date().timeIntervalSince1970 / 300)
        return stride(from: 50, through: 0, by: -5).enumerated().map { i, m in
            let layer = m == 0 ? "nexrad-n0q-900913" : String(format: "nexrad-n0q-900913-m%02dm", m)
            return Frame(id: i, time: base.addingTimeInterval(TimeInterval(-m * 60)),
                         template: "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/\(layer)/{z}/{x}/{y}.png?_=\(bust)")
        }
    }
}
