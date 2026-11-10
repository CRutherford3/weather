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

/// What the radar loop shows.
enum RadarMode: String, CaseIterable {
    case recent, history, future
    var title: String {
        switch self {
        case .recent: return "Last hour"
        case .history: return "Past 48 hours"
        case .future: return "Future radar"
        }
    }
}

/// Radar loop frames as whole images for the area on screen, from Iowa State's NEXRAD mosaic
/// (the same radar as the website) and, for future radar, the NOAA HRRR model's forecast radar.
enum RadarService {
    /// `template` holds {bbox} (EPSG:3857 meters), {w} and {h}.
    struct Frame: Identifiable { let id: Int; let time: Date; let template: String; var future = false }

    private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    /// Time of the newest radar mosaic.
    static func latest() async -> Date {
        struct TMS: Decodable { struct S: Decodable { let id: String?; let utc_valid: String? }; let services: [S]? }
        if let url = URL(string: "https://mesonet.agron.iastate.edu/json/tms.json"),
           let data = try? await URLSession.shared.data(from: url).0,
           let tms = try? JSONDecoder().decode(TMS.self, from: data),
           let s = tms.services?.first(where: { ($0.id ?? "").lowercased().contains("n0q") }), let v = s.utc_valid,
           let d = iso.date(from: v) {
            return d
        }
        return Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 300).rounded(.down) * 300 - 300)
    }

    private static func observed(_ t: Date) -> String {
        "https://mesonet.agron.iastate.edu/cgi-bin/wms/nexrad/n0q-t.cgi?SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap&LAYERS=nexrad-n0q-wmst&STYLES=&SRS=EPSG:3857&BBOX={bbox}&WIDTH={w}&HEIGHT={h}&FORMAT=image/png&TRANSPARENT=true&TIME=\(iso.string(from: t))"
    }

    static func frames(_ mode: RadarMode = .recent) async -> [Frame] {
        let base = await latest()
        switch mode {
        case .recent:
            // last hour, every 5 minutes
            return stride(from: 55, through: 0, by: -5).enumerated().map { i, m in
                let t = base.addingTimeInterval(TimeInterval(-m * 60))
                return Frame(id: i, time: t, template: observed(t))
            }
        case .history:
            // past 48 hours, every 30 minutes (smoother than hourly), ending with the latest scan
            let half = Date(timeIntervalSince1970: (base.timeIntervalSince1970 / 1800).rounded(.down) * 1800)
            var times = (1...95).reversed().map { half.addingTimeInterval(TimeInterval(-$0 * 1800)) }
            times.append(half); if base > half { times.append(base) }
            return times.enumerated().map { Frame(id: $0.offset, time: $0.element, template: observed($0.element)) }
        case .future:
            // now, then the HRRR forecast every 30 minutes for about 8 hours
            var out = [Frame(id: 0, time: base, template: observed(base))]
            guard let url = URL(string: "https://mesonet.agron.iastate.edu/data/gis/images/4326/hrrr/refd_1080.json"),
                  let data = try? await URLSession.shared.data(from: url).0,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let s = j["model_init_utc"] as? String, let initT = iso.date(from: s) else { return out }
            let now = Date()
            for f in stride(from: 0, through: 1080, by: 30) {
                let valid = initT.addingTimeInterval(TimeInterval(f * 60))
                guard valid > now.addingTimeInterval(-600), valid < now.addingTimeInterval(8.5 * 3600) else { continue }
                out.append(Frame(id: out.count, time: valid,
                                 template: String(format: "https://mesonet.agron.iastate.edu/cgi-bin/wms/hrrr/refd.cgi?SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap&LAYERS=refd_%04d&STYLES=&SRS=EPSG:3857&BBOX={bbox}&WIDTH={w}&HEIGHT={h}&FORMAT=image/png&TRANSPARENT=true", f),
                                 future: true))
            }
            return out
        }
    }
}
