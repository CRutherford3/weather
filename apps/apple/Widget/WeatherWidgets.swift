import WidgetKit
import SwiftUI
import AppIntents
import CoreLocation

// More Home Screen, desktop and Lock Screen widgets: 3-day forecast, retro dot-matrix, interactive conditions
// (temperature / rain / wind), wind compass, UV, sunrise and sunset, moon, air quality, pressure, four gauges,
// seas (waves and water temperature), and a glance card with AQI and UV.
// Every widget can follow your location or show a city you type when editing the widget.

// MARK: - Data

struct WxHour { let time: Date; let temp: Double; let code: Int; let isDay: Bool; let pop: Int; let wind: Double }
struct WxDay { let date: Date; let hi: Double; let lo: Double; let code: Int; let pop: Int; let uvMax: Double; let sunrise: Date?; let sunset: Date? }
struct WxSea { let wave: Double; let dir: Double; let period: Double; let water: Double? }

struct WxData: TimelineEntry {
    var date = Date()
    var place = "DopplerIQ"
    var located = true
    var temp: Double?
    var feels: Double?
    var humidity: Double?
    var dew: Double?
    var code = 0
    var isDay = true
    var wind: Double?
    var gust: Double?
    var windDir: Double?
    var pressure: Double?      // inHg (US) or hPa
    var uv: Double?
    var visibility: Double?    // miles (US) or km
    var hours: [WxHour] = []
    var days: [WxDay] = []
    var aqi: Int?
    var sea: WxSea?
    var message: String?
    var mode = 0               // Conditions widget: 0 temperature, 1 rain, 2 wind

    static let us = Locale.current.measurementSystem == .us
    var hi: Double? { days.first?.hi }
    var lo: Double? { days.first?.lo }
    var rainChance: Int? { hours.first?.pop ?? days.first?.pop }

    static var sample: WxData {
        var d = WxData(place: "Palm Bay", temp: 74, feels: 76, humidity: 86, dew: 69, code: 3, isDay: true,
                       wind: 4, gust: 10, windDir: 112, pressure: 30.10, uv: 3, visibility: 12, aqi: 46,
                       sea: WxSea(wave: 3.2, dir: 90, period: 8, water: 79))
        let now = Date()
        d.hours = (0..<6).map { i in WxHour(time: now.addingTimeInterval(Double(i) * 3600), temp: 74 - Double(i % 3), code: [3, 2, 61][i % 3], isDay: true, pop: [10, 20, 40][i % 3], wind: 4 + Double(i)) }
        let cal = Calendar.current
        d.days = (0..<7).map { i in
            let day = cal.date(byAdding: .day, value: i, to: now)!
            return WxDay(date: day, hi: 81 - Double(i), lo: 64 - Double(i % 3), code: [3, 61, 61, 2, 1, 0, 3][i], pop: [10, 75, 50, 20, 0, 0, 10][i], uvMax: 6,
                         sunrise: cal.date(bySettingHour: 6, minute: 41, second: 0, of: day), sunset: cal.date(bySettingHour: 17, minute: 31, second: 0, of: day))
        }
        return d
    }
}

/// What a widget needs beyond the basic forecast (each extra is one more download).
struct WxNeeds: OptionSet {
    let rawValue: Int
    static let aqi = WxNeeds(rawValue: 1)
    static let sea = WxNeeds(rawValue: 2)
}

enum WxLoader {
    /// Recent downloads, so tapping a widget button or several widgets refreshing together don't refetch.
    private static var cache: [String: (Date, WxData)] = [:]

    static func load(_ city: String?, needs: WxNeeds) async -> WxData {
        let typed = city?.trimmingCharacters(in: .whitespaces) ?? ""
        let key = "\(typed)|\(needs.rawValue)"
        if let (t, d) = cache[key], Date().timeIntervalSince(t) < 10 * 60 { var c = d; c.date = .now; return c }

        var lat: Double, lon: Double, name: String
        if !typed.isEmpty {
            guard let hit = await geocode(typed) else { return WxData(message: "Couldn't find \(typed)") }
            (lat, lon, name) = hit
        } else if let loc = CLLocationManager().location {
            lat = loc.coordinate.latitude; lon = loc.coordinate.longitude
            name = await placeName(lat, lon) ?? "My Location"
        } else {
            return WxData(message: "Open DopplerIQ once to share your location, or edit the widget to pick a city.")
        }
        var d = WxData(place: name, located: typed.isEmpty)
        let us = WxData.us
        let units = us ? "&temperature_unit=fahrenheit&wind_speed_unit=mph&precipitation_unit=inch" : ""
        let base = String(format: "latitude=%.3f&longitude=%.3f", lat, lon)
        let url = URL(string: "https://api.open-meteo.com/v1/forecast?\(base)"
            + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,dew_point_2m,weather_code,is_day,wind_speed_10m,wind_direction_10m,wind_gusts_10m,pressure_msl,uv_index,visibility"
            + "&hourly=temperature_2m,weather_code,is_day,precipitation_probability,wind_speed_10m"
            + "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,uv_index_max,sunrise,sunset"
            + "&forecast_days=7&timezone=auto&timeformat=unixtime\(units)")!
        guard let j = await json(url) else { d.message = "Weather is unavailable right now."; return d }

        let c = j["current"] as? [String: Any] ?? [:]
        d.temp = num(c["temperature_2m"]); d.feels = num(c["apparent_temperature"])
        d.humidity = num(c["relative_humidity_2m"]); d.dew = num(c["dew_point_2m"])
        d.code = Int(num(c["weather_code"]) ?? 0); d.isDay = (num(c["is_day"]) ?? 1) == 1
        d.wind = num(c["wind_speed_10m"]); d.gust = num(c["wind_gusts_10m"]); d.windDir = num(c["wind_direction_10m"])
        if let p = num(c["pressure_msl"]) { d.pressure = us ? p * 0.02953 : p }
        d.uv = num(c["uv_index"])
        if let v = num(c["visibility"]) { d.visibility = us ? v / 1609.34 : v / 1000 }

        if let h = j["hourly"] as? [String: Any] {
            let t = nums(h["time"]), tp = nums(h["temperature_2m"]), cd = nums(h["weather_code"]), dy = nums(h["is_day"]),
                pp = nums(h["precipitation_probability"]), ws = nums(h["wind_speed_10m"])
            let now = Date().timeIntervalSince1970
            let start = max(0, (t.firstIndex { $0 > now } ?? 1) - 1)   // the current hour first
            for i in start..<min(start + 24, t.count, tp.count) {
                d.hours.append(WxHour(time: Date(timeIntervalSince1970: t[i]), temp: tp[i], code: Int(cd[safe: i] ?? 0),
                                      isDay: (dy[safe: i] ?? 1) == 1, pop: Int(pp[safe: i] ?? 0), wind: ws[safe: i] ?? 0))
            }
        }
        if let dd = j["daily"] as? [String: Any] {
            let t = nums(dd["time"]), hi = nums(dd["temperature_2m_max"]), lo = nums(dd["temperature_2m_min"]), cd = nums(dd["weather_code"]),
                pp = nums(dd["precipitation_probability_max"]), uv = nums(dd["uv_index_max"]), sr = nums(dd["sunrise"]), ss = nums(dd["sunset"])
            for i in 0..<min(t.count, hi.count, lo.count) {
                d.days.append(WxDay(date: Date(timeIntervalSince1970: t[i]), hi: hi[i], lo: lo[i], code: Int(cd[safe: i] ?? 0), pop: Int(pp[safe: i] ?? 0),
                                    uvMax: uv[safe: i] ?? 0, sunrise: sr[safe: i].map { Date(timeIntervalSince1970: $0) }, sunset: ss[safe: i].map { Date(timeIntervalSince1970: $0) }))
            }
        }
        if needs.contains(.aqi), let u = URL(string: "https://air-quality-api.open-meteo.com/v1/air-quality?\(base)&current=us_aqi"),
           let a = await json(u), let cur = a["current"] as? [String: Any], let v = num(cur["us_aqi"]) {
            d.aqi = Int(v.rounded())
        }
        if needs.contains(.sea), let u = URL(string: "https://marine-api.open-meteo.com/v1/marine?\(base)&current=wave_height,wave_direction,wave_period,sea_surface_temperature\(us ? "&length_unit=imperial&temperature_unit=fahrenheit" : "")"),
           let m = await json(u), let cur = m["current"] as? [String: Any], let wave = num(cur["wave_height"]) {
            d.sea = WxSea(wave: wave, dir: num(cur["wave_direction"]) ?? 0, period: num(cur["wave_period"]) ?? 0, water: num(cur["sea_surface_temperature"]))
        }
        cache[key] = (Date(), d)
        return d
    }

    private static func geocode(_ q: String) async -> (Double, Double, String)? {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: q.components(separatedBy: ",").first ?? q), .init(name: "count", value: "1")]
        guard let u = c.url, let j = await json(u), let r = (j["results"] as? [[String: Any]])?.first,
              let la = num(r["latitude"]), let lo = num(r["longitude"]) else { return nil }
        return (la, lo, (r["name"] as? String) ?? q)
    }
    private static func placeName(_ lat: Double, _ lon: Double) async -> String? {
        guard let p = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon)).first else { return nil }
        return p.locality ?? p.subAdministrativeArea ?? p.administrativeArea
    }
    private static func json(_ url: URL) async -> [String: Any]? {
        var r = URLRequest(url: url); r.timeoutInterval = 15
        r.setValue("DopplerIQWeather/1.0 (github.com/CRutherford3/weather)", forHTTPHeaderField: "User-Agent")
        guard let d = try? await URLSession.shared.data(for: r).0 else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
    private static func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
    private static func nums(_ v: Any?) -> [Double] { (v as? [Any] ?? []).map { ($0 as? NSNumber)?.doubleValue ?? 0 } }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

struct WxProvider2: AppIntentTimelineProvider {
    var needs: WxNeeds = []
    func placeholder(in context: Context) -> WxData { .sample }
    func snapshot(for configuration: WidgetPlaceIntent, in context: Context) async -> WxData {
        context.isPreview ? .sample : await WxLoader.load(configuration.city, needs: needs)
    }
    func timeline(for configuration: WidgetPlaceIntent, in context: Context) async -> Timeline<WxData> {
        var d = await WxLoader.load(configuration.city, needs: needs)
        d.mode = UserDefaults.standard.integer(forKey: "conditionsMode")
        return Timeline(entries: [d], policy: .after(Date().addingTimeInterval(30 * 60)))
    }
}

// MARK: - Shared look

private let f0: (Double?) -> String = { $0.map { "\(Int($0.rounded()))°" } ?? "--" }
private func hourLabel(_ d: Date, first: Bool) -> String {
    if first { return "Now" }
    let f = DateFormatter(); f.dateFormat = "ha"
    return f.string(from: d).replacingOccurrences(of: "M", with: "")
}
private func dayLabel(_ d: Date, first: Bool) -> String { first ? "Today" : d.formatted(.dateTime.weekday(.abbreviated)) }

/// Dark sky background: blue-gray by day, deep navy at night.
private struct SkyBackground: View {
    var isDay: Bool
    var body: some View {
        LinearGradient(colors: isDay ? [Color(red: 0.20, green: 0.26, blue: 0.36), Color(red: 0.12, green: 0.15, blue: 0.22)]
                                     : [Color(red: 0.09, green: 0.11, blue: 0.22), Color(red: 0.04, green: 0.05, blue: 0.11)],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// "UV INDEX" style label.
private struct Header: View {
    let icon: String, title: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(title.uppercased()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white.opacity(0.6))
    }
}

/// Colored scale with a white dot for where the value sits.
private struct ScaleBar: View {
    let colors: [Color]; let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)).frame(height: 5)
                Circle().fill(.white).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(.black.opacity(0.5), lineWidth: 1.5))
                    .offset(x: max(0, min(g.size.width - 9, g.size.width * fraction - 4.5)))
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 10)
    }
}

private let uvColors: [Color] = [.green, .yellow, .orange, .red, .purple]
private let aqiColors: [Color] = [.green, .yellow, .orange, .red, .purple, Color(red: 0.5, green: 0.1, blue: 0.2)]
private func uvLabel(_ v: Double) -> String { v < 3 ? "Low" : v < 6 ? "Moderate" : v < 8 ? "High" : v < 11 ? "Very High" : "Extreme" }
private func aqiLabel(_ v: Int) -> String { v <= 50 ? "Good" : v <= 100 ? "Moderate" : v <= 150 ? "Unhealthy for Some" : v <= 200 ? "Unhealthy" : v <= 300 ? "Very Unhealthy" : "Hazardous" }
private func aqiColor(_ v: Int) -> Color { aqiColors[min(5, v <= 50 ? 0 : v <= 100 ? 1 : v <= 150 ? 2 : v <= 200 ? 3 : v <= 300 ? 4 : 5)] }
private func uvColor(_ v: Double) -> Color { uvColors[min(4, v < 3 ? 0 : v < 6 ? 1 : v < 8 ? 2 : v < 11 ? 3 : 4)] }
private func compass(_ deg: Double) -> String { ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][Int(((deg / 45).rounded())) % 8] }
private func tempColor(_ t: Double) -> Color {
    let f = WxData.us ? t : t * 9 / 5 + 32
    return f < 32 ? Color(red: 0.4, green: 0.6, blue: 1) : f < 50 ? Color(red: 0.4, green: 0.85, blue: 0.85)
        : f < 65 ? Color(red: 0.6, green: 0.85, blue: 0.5) : f < 80 ? Color(red: 0.98, green: 0.82, blue: 0.3) : Color(red: 0.98, green: 0.55, blue: 0.25)
}

/// Shown instead of a widget when there's nothing to show yet.
private struct WxMessage: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("DopplerIQ", systemImage: "dot.radiowaves.left.and.right").font(.caption.bold())
            Text(text).font(.caption).foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
    }
}

/// Wraps every widget: background, white text, the "no data" message, and Lock Screen backgrounds.
private struct WxFrame<Content: View>: View {
    @Environment(\.widgetFamily) private var family
    let d: WxData
    @ViewBuilder var content: () -> Content
    var body: some View {
        Group {
            if let m = d.message, d.temp == nil { WxMessage(text: m) } else { content() }
        }
        .foregroundStyle(.white)
        .widgetURL(WidgetLink.dashboard)
        .containerBackground(for: .widget) {
            if isAccessory { Color.clear } else { SkyBackground(isDay: d.isDay) }
        }
    }
    private var isAccessory: Bool {
        #if os(iOS)
        return [.accessoryCircular, .accessoryRectangular, .accessoryInline].contains(family)
        #else
        return false
        #endif
    }
}

private func families(_ home: [WidgetFamily], lock: [WidgetFamily] = []) -> [WidgetFamily] {
    #if os(iOS)
    return home + lock
    #else
    return home
    #endif
}

// MARK: - 1. Three-day forecast (and the Lock Screen summary)

struct ForecastStripWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "DopplerIQ3Day", intent: WidgetPlaceIntent.self, provider: WxProvider2()) { d in
            WxFrame(d: d) { ForecastStripView(d: d) }
        }
        .configurationDisplayName("3-Day Forecast")
        .description("Today's weather and the next two days. On the Lock Screen: now, the condition, and the high and low.")
        .supportedFamilies(families([.systemMedium], lock: lockFamilies))
    }
    private var lockFamilies: [WidgetFamily] {
        #if os(iOS)
        [.accessoryRectangular, .accessoryInline]
        #else
        []
        #endif
    }
}

struct ForecastStripView: View {
    @Environment(\.widgetFamily) private var family
    let d: WxData
    var body: some View {
        switch family {
        #if os(iOS)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: WidgetWeather.symbol(d.code, day: d.isDay))
                    Text(f0(d.temp)).bold()
                }
                .font(.headline)
                Text(WidgetWeather.words(d.code)).font(.headline).lineLimit(1)
                Text("H:\(f0(d.hi)) L:\(f0(d.lo))").font(.headline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            Label("\(f0(d.temp)) \(WidgetWeather.words(d.code))", systemImage: WidgetWeather.symbol(d.code, day: d.isDay))
        #endif
        default:
            HStack(alignment: .top, spacing: 0) {
                column(day: d.days.first, first: true)
                ForEach(Array(d.days.dropFirst().prefix(2).enumerated()), id: \.offset) { _, day in column(day: day, first: false) }
            }
        }
    }

    private func column(day: WxDay?, first: Bool) -> some View {
        VStack(spacing: 8) {
            Text((day?.date ?? .now).formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.system(size: first ? 26 : 20, weight: .black, design: .rounded))
                .foregroundStyle(first ? .white : .white.opacity(0.75))
            Image(systemName: WidgetWeather.symbol(first ? d.code : day?.code ?? 0, day: first ? d.isDay : true))
                .font(.system(size: first ? 30 : 24))
                .symbolRenderingMode(.hierarchical)
            if first {
                Text(f0(d.temp)).font(.system(size: 30, weight: .heavy, design: .rounded))
            } else {
                HStack(spacing: 6) {
                    Text(f0(day?.hi)).foregroundStyle(.white.opacity(0.85))
                    Text(f0(day?.lo)).foregroundStyle(.white.opacity(0.5))
                }
                .font(.system(size: 18, weight: .heavy, design: .rounded))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 2. Retro dot-matrix

struct RetroWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "DopplerIQRetro", intent: WidgetPlaceIntent.self, provider: WxProvider2()) { d in
            WxFrame(d: d) { RetroView(d: d) }.containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("Retro")
        .description("A dot-matrix weather icon with the temperature, on black.")
        .supportedFamilies([.systemSmall])
    }
}

struct RetroView: View {
    let d: WxData
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { ctx, size in
                let step: CGFloat = 7
                var y: CGFloat = step / 2
                while y < size.height {
                    var x: CGFloat = step / 2
                    while x < size.width {
                        ctx.fill(Path(ellipseIn: CGRect(x: x - 2.2, y: y - 2.2, width: 4.4, height: 4.4)), with: .color(.white))
                        x += step
                    }
                    y += step
                }
            }
            .mask { Image(systemName: WidgetWeather.symbol(d.code, day: d.isDay)).resizable().scaledToFit() }
            .frame(height: 64)
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            Text(f0(d.temp)).font(.system(size: 36, weight: .medium, design: .monospaced))
            Text(WidgetWeather.words(d.code).uppercased()).font(.system(size: 12, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - 3. Conditions (interactive: temperature, rain or wind)

struct ConditionsModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Change Conditions View"
    @Parameter(title: "View") var mode: Int
    init() {}
    init(mode: Int) { self.mode = mode }
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(mode, forKey: "conditionsMode")
        return .result()
    }
}

struct ConditionsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "DopplerIQConditions", intent: WidgetPlaceIntent.self, provider: WxProvider2()) { d in
            WxFrame(d: d) { ConditionsView(d: d) }
        }
        .configurationDisplayName("Conditions")
        .description("The next hours: tap to switch between temperature, rain chance and wind. Large adds the week ahead.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct ConditionsView: View {
    @Environment(\.widgetFamily) private var family
    let d: WxData
    private let modes = [("cloud.sun.fill", "Temperature (\(WxData.us ? "°F" : "°C"))"), ("drop.fill", "Chance of Rain"), ("wind", "Wind (\(WxData.us ? "mph" : "km/h"))")]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Conditions").font(.headline)
                    Text(modes[d.mode].1).font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { i in
                        Button(intent: ConditionsModeIntent(mode: i)) {
                            Image(systemName: modes[i].0).font(.caption)
                                .frame(width: 34, height: 26)
                                .background(d.mode == i ? Color.white.opacity(0.22) : .clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Color.white.opacity(0.08), in: Capsule())
            }
            HStack(spacing: 0) {
                ForEach(Array(d.hours.prefix(6).enumerated()), id: \.offset) { i, h in
                    VStack(spacing: 6) {
                        Text(hourLabel(h.time, first: i == 0)).font(.caption.weight(.semibold))
                        Image(systemName: d.mode == 2 ? "wind" : d.mode == 1 ? "drop.fill" : WidgetWeather.symbol(h.code, day: h.isDay))
                            .symbolRenderingMode(.multicolor).font(.callout).frame(height: 20)
                            .foregroundStyle(d.mode == 1 ? Color(red: 0.4, green: 0.7, blue: 1) : .white)
                        Text(value(h)).font(.callout.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            if family == .systemLarge {
                Divider().overlay(.white.opacity(0.2))
                week
            }
        }
    }

    private func value(_ h: WxHour) -> String {
        switch d.mode {
        case 1: return "\(h.pop)%"
        case 2: return "\(Int(h.wind.rounded()))"
        default: return f0(h.temp)
        }
    }

    /// Daily rows with range bars, like the Weather app.
    private var week: some View {
        let days = Array(d.days.prefix(6))
        let lo = days.map(\.lo).min() ?? 0, hi = days.map(\.hi).max() ?? 1
        return VStack(spacing: 7) {
            ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                HStack(spacing: 10) {
                    Text(dayLabel(day.date, first: i == 0)).font(.subheadline.weight(.semibold)).frame(width: 48, alignment: .leading)
                    VStack(spacing: 0) {
                        Image(systemName: WidgetWeather.symbol(day.code)).symbolRenderingMode(.multicolor)
                        if day.pop >= 30 { Text("\(day.pop)%").font(.system(size: 9, weight: .bold)).foregroundStyle(Color(red: 0.4, green: 0.7, blue: 1)) }
                    }
                    .frame(width: 30)
                    Text(f0(day.lo)).font(.subheadline).foregroundStyle(.white.opacity(0.55)).frame(width: 34, alignment: .trailing)
                    GeometryReader { g in
                        let span = max(1, hi - lo)
                        let x0 = g.size.width * (day.lo - lo) / span, x1 = g.size.width * (day.hi - lo) / span
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.12)).frame(height: 5)
                            Capsule().fill(LinearGradient(colors: [tempColor(day.lo), tempColor(day.hi)], startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(6, x1 - x0), height: 5).offset(x: x0)
                            if i == 0, let t = d.temp {
                                Circle().fill(.white).frame(width: 7, height: 7)
                                    .overlay(Circle().stroke(.black.opacity(0.5), lineWidth: 1.5))
                                    .offset(x: g.size.width * (t - lo) / span - 3.5)
                            }
                        }
                        .frame(maxHeight: .infinity)
                    }
                    Text(f0(day.hi)).font(.subheadline.weight(.semibold)).frame(width: 34, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - 4. Wind

struct WindWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "DopplerIQWind", intent: WidgetPlaceIntent.self, provider: WxProvider2()) { d in
            WxFrame(d: d) { WindView(d: d) }
        }
        .configurationDisplayName("Wind")
        .description("A compass with wind speed, gusts and direction.")
        .supportedFamilies(families([.systemSmall], lock: circular))
    }
}

private var circular: [WidgetFamily] {
    #if os(iOS)
    [.accessoryCircular]
    #else
    []
    #endif
}

struct WindView: View {
    @Environment(\.widgetFamily) private var family
    let d: WxData
    private var unit: String { WxData.us ? "mph" : "km/h" }
    var body: some View {
        switch family {
        #if os(iOS)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "location.north.fill").font(.system(size: 10))
                    .offset(y: -20).rotationEffect(.degrees((d.windDir ?? 0) + 180))
                VStack(spacing: -2) {
                    Text("\(Int((d.wind ?? 0).rounded()))").font(.title3.bold())
                    Text(compass(d.windDir ?? 0)).font(.system(size: 9, weight: .semibold))
                }
            }
        #endif
        default:
            VStack(alignment: .leading, spacing: 4) {
                Header(icon: "wind", title: "Wind")
                Compass(dir: d.windDir ?? 0, speed: d.wind ?? 0, unit: unit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("Gusts \(Int((d.gust ?? 0).rounded())) \(unit) · \(compass(d.windDir ?? 0))")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.75)).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }
}

/// Ticks, N/E/S/W, an arrow pointing where the wind is blowing, and the speed in the middle.
private struct Compass: View {
    let dir: Double, speed: Double, unit: String
    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height), r = s / 2
            ZStack {
                ForEach(0..<60, id: \.self) { i in
                    Rectangle().fill(.white.opacity(i % 15 == 0 ? 0 : 0.35)).frame(width: 1, height: i % 5 == 0 ? 6 : 3)
                        .offset(y: -r + 4).rotationEffect(.degrees(Double(i) * 6))
                }
                ForEach(Array(["N", "E", "S", "W"].enumerated()), id: \.offset) { i, l in
                    Text(l).font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                        .offset(y: -r + 5).rotationEffect(.degrees(Double(i) * 90))
                        .rotationEffect(.degrees(0))
                }
                // arrow: wind comes FROM dir, so it points toward dir + 180
                Capsule().fill(.white).frame(width: 2.5, height: r * 1.3)
                    .overlay(alignment: .top) { Image(systemName: "arrowtriangle.up.fill").font(.system(size: 9)).offset(y: -5) }
                    .overlay(alignment: .bottom) { Circle().fill(.white).frame(width: 7, height: 7).offset(y: 3) }
                    .rotationEffect(.degrees(dir + 180))
                Circle().fill(Color(red: 0.13, green: 0.16, blue: 0.24)).frame(width: r * 0.95, height: r * 0.95)
                VStack(spacing: -2) {
                    Text("\(Int(speed.rounded()))").font(.system(size: r * 0.42, weight: .bold, design: .rounded))
                    Text(unit).font(.system(size: r * 0.2, weight: .semibold))
                }
            }
            .frame(width: s, height: s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - 5. UV index

struct UVWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "DopplerIQUV", intent: WidgetPlaceIntent.self, provider: WxProvider2()) { d in
            WxFrame(d: d) { UVView(d: d) }
        }
        .configurationDisplayName("UV Index")
        .description("The UV index now, how strong it is, and today's peak.")
        .supportedFamilies(families([.systemSmall], lock: circular))
    }
}

struct UVView: View {
    @Environment(\.widgetFamily) private var family
    let d: WxData
    var body: some View {
        let uv = d.uv ?? 0
        switch family {
        #if os(iOS)
        case .accessoryCircular:
            Gauge(value: min(uv, 11), in: 0...11) { Image(systemName: "sun.max.fill") } currentValueLabel: { Text("\(Int(uv.rounded()))") }
                .gaugeStyle(.accessoryCircular)
        #endif
        default:
            VStack(alignment: .leading, spacing: 4) {
                Header(icon: "sun.max.fill", title: "UV Index")
                Text("\(Int(uv.rounded()))").font(.system(size: 40, weight: .regular, design: .rounded))
                Text(uvLabel(uv)).font(.title3.weight(.semibold))
                Spacer(minLength: 0)
                ScaleBar(colors: uvColors, fraction: min(1, uv / 11))
                Text("Peak today: \(Int((d.days.first?.uvMax ?? uv).rounded())), \(uvLabel(d.days.first?.uvMax ?? uv))")
                    .font(.caption2).foregroundStyle(.white.opacity(0.75)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 6. Sunrise and sunset

struct SunWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "DopplerIQSun", intent: WidgetPlaceIntent.self, provider: WxProvider2()) { d in
            WxFrame(d: d) { SunView(d: d) }
        }
        .configurationDisplayName("Sunrise & Sunset")
        .description("The next sunrise or sunset, with the sun's path across the day.")
        .supportedFamilies(families([.systemSmall], lock: rectangular))
    }
}

private var rectangular: [WidgetFamily] {
    #if os(iOS)
    [.accessoryRectangular]
    #else
    []
    #endif
}

struct SunView: View {
    @Environment(\.widgetFamily) private var family
    let d: WxData
    private func t(_ x: Date?) -> String { x?.formatted(date: .omitted, time: .shortened) ?? "--" }
    var body: some View {
        let today = d.days.first, tomorrow = d.days.dropFirst().first
        let now = Date()
        let beforeRise = (today?.sunrise ?? now) > now
        let afterSet = (today?.sunset ?? now) < now
        let nextIsRise = beforeRise || afterSet
        let next = beforeRise ? today?.sunrise : afterSet ? tomorrow?.sunrise : today?.sunset
        switch family {
        #if os(iOS)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label(nextIsRise ? "Sunrise" : "Sunset", systemImage: nextIsRise ? "sunrise.fill" : "sunset.fill").font(.headline)
                Text(t(next)).font(.title3.bold())
                Text(nextIsRise ? "Sunset \(t(today?.sunset))" : "Sunrise \(t(tomorrow?.sunrise))").font(.caption).foregroundStyle(.secondary)
            }
        #endif
        default:
            VStack(alignment: .leading, spacing: 4) {
                Header(icon: nextIsRise ? "sunrise.fill" : "sunset.fill", title: nextIsRise ? "Sunrise" : "Sunset")
                Text(t(next)).font(.system(size: 28, weight: .regular, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
                SunCurve(rise: today?.sunrise, set: today?.sunset).frame(maxHeight: .infinity)
                Text(nextIsRise ? "Sunset: \(t(today?.sunset))" : "Sunrise: \(t(tomorrow?.sunrise))")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.75))
            }
        }
    }
}

/// A day-long wave with the horizon line; the sun dot sits at the current time.
private struct SunCurve: View {
    let rise: Date?, set: Date?
    private var start: Date { Calendar.current.startOfDay(for: .now) }
    private func frac(_ d: Date?) -> Double { (d ?? start).timeIntervalSince(start) / 86400 }
    /// Height of the sun's path: above the horizon between sunrise and sunset.
    private func y(_ x: Double, _ h: CGFloat) -> CGFloat {
        let r = frac(rise), s = frac(set)
        let mid = (r + s) / 2, half = max(0.05, (s - r) / 2)
        return h * 0.55 - CGFloat(cos((x - mid) / half * .pi / 2)) * h * 0.45
    }
    private func curve(_ w: CGFloat, _ h: CGFloat) -> Path {
        var p = Path()
        for i in 0...60 {
            let x = Double(i) / 60
            let pt = CGPoint(x: w * x, y: y(x, h))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let n = frac(.now)
            let up = n > frac(rise) && n < frac(set)
            ZStack {
                curve(w, h).stroke(.white.opacity(0.35), lineWidth: 2)
                Path { p in p.move(to: CGPoint(x: 0, y: h * 0.55)); p.addLine(to: CGPoint(x: w, y: h * 0.55)) }
                    .stroke(.white.opacity(0.3), lineWidth: 1)
                Circle().fill(up ? Color.yellow : .white.opacity(0.4)).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 1))
                    .position(x: w * n, y: y(n, h))
            }
        }
    }
}

// MARK: - 7. Moon

enum Moon {
    static let period = 29.530588853
    /// Days since the last new moon.
    static func age(_ d: Date = .now) -> Double {
        let ref = Date(timeIntervalSince1970: 947_182_440)   // new moon, Jan 6 2000 18:14 UTC
        let a = d.timeIntervalSince(ref) / 86400
        return a.truncatingRemainder(dividingBy: period) + (a < 0 ? period : 0)
    }
    static func illumination(_ age: Double) -> Double { (1 - cos(2 * .pi * age / period)) / 2 }
    static func name(_ age: Double) -> String {
        switch age / period {
        case ..<0.03, 0.97...: return "New Moon"
        case ..<0.22: return "Waxing Crescent"
        case ..<0.28: return "First Quarter"
        case ..<0.47: return "Waxing Gibbous"
        case ..<0.53: return "Full Moon"
        case ..<0.72: return "Waning Gibbous"
        case ..<0.78: return "Last Quarter"
        default: return "Waning Crescent"
        }
    }
    static func daysToFull(_ age: Double) -> Int { Int(((period / 2 - age).truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period).rounded()) }
    /// SF Symbol for the phase, for the Lock Screen.
    static func symbol(_ age: Double) -> String {
        switch name(age) {
        case "New Moon": return "moonphase.new.moon"
        case "Waxing Crescent": return "moonphase.waxing.crescent"
        case "First Quarter": return "moonphase.first.quarter"
        case "Waxing Gibbous": return "moonphase.waxing.gibbous"
        case "Full Moon": return "moonphase.full.moon"
        case "Waning Gibbous": return "moonphase.waning.gibbous"
        case "Last Quarter": return "moonphase.last.quarter"
        default: return "moonphase.waning.crescent"
        }
    }
    static func daysToNew(_ age: Double) -> Int { Int((period - age).rounded()) % Int(period.rounded()) }
}

/// The moon, lit on the right while waxing and on the left while waning.
private struct MoonDisc: View {
    let age: Double
    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            let ill = Moon.illumination(age), waxing = age < Moon.period / 2
            ZStack {
                Circle().fill(Color(white: 0.85))
                Circle().fill(Color(red: 0.12, green: 0.14, blue: 0.2))
                    .offset(x: (waxing ? -1 : 1) * s * CGFloat(ill) * 1.0)
                    .opacity(ill > 0.98 ? 0 : 1)
            }
            .frame(width: s, height: s)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct MoonWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "DopplerIQMoon", intent: WidgetPlaceIntent.self, provider: WxProvider2()) { d in
            WxFrame(d: d) { MoonView() }
        }
        .configurationDisplayName("Moon Phase")
        .description("Tonight's moon, how much is lit, and the next full and new moons.")
        .supportedFamilies(families([.systemSmall, .systemMedium], lock: moonLock))
    }
    private var moonLock: [WidgetFamily] {
        #if os(iOS)
        [.accessoryCircular, .accessoryInline]
        #else
        []
        #endif
    }
}

struct MoonView: View {
    @Environment(\.widgetFamily) private var family
    var body: some View {
        let a = Moon.age()
        let ill = Int((Moon.illumination(a) * 100).rounded())
        #if os(iOS)
        if family == .accessoryCircular {
            VStack(spacing: 0) {
                Image(systemName: Moon.symbol(a)).font(.system(size: 22))
                Text("\(ill)%").font(.system(size: 13, weight: .semibold))
            }
            .widgetAccentable()
        } else if family == .accessoryInline {
            Label("\(Moon.name(a)), \(ill)%", systemImage: Moon.symbol(a))
        } else {
            homeMoon(a, ill)
        }
        #else
        homeMoon(a, ill)
        #endif
    }

    @ViewBuilder private func homeMoon(_ a: Double, _ ill: Int) -> some View {
        if family == .systemMedium {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Header(icon: "moonphase.waxing.crescent", title: Moon.name(a))
                    row("Illumination", "\(ill)%")
                    Divider().overlay(.white.opacity(0.2))
                    row("Next Full Moon", "\(Moon.daysToFull(a)) days")
                    Divider().overlay(.white.opacity(0.2))
                    row("Next New Moon", "\(Moon.daysToNew(a)) days")
                }
                MoonDisc(age: a).frame(width: 110)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Header(icon: "moonphase.waxing.crescent", title: Moon.name(a))
                MoonDisc(age: a).frame(maxHeight: .infinity)
                Text("\(ill)% lit").font(.headline)
                Text("Full moon in \(Moon.daysToFull(a)) days").font(.caption2).foregroundStyle(.white.opacity(0.75))
            }
        }
    }
    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).font(.subheadline); Spacer(); Text(v).font(.subheadline).foregroundStyle(.white.opacity(0.65)) }
    }
}

// MARK: - 8. Air quality

struct AirWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "DopplerIQAir", intent: WidgetPlaceIntent.self, provider: WxProvider2(needs: .aqi)) { d in
            WxFrame(d: d) { AirView(d: d) }
        }
        .configurationDisplayName("Air Quality")
        .description("The US air quality index and what it means.")
        .supportedFamilies(families([.systemSmall], lock: circular))
    }
}

struct AirView: View {
    @Environment(\.widgetFamily) private var family
    let d: WxData
    var body: some View {
        let v = d.aqi ?? 0
        switch family {
        #if os(iOS)
        case .accessoryCircular:
            Gauge(value: Double(min(v, 300)), in: 0...300) { Text("AQI") } currentValueLabel: { Text(d.aqi.map(String.init) ?? "--") }
                .gaugeStyle(.accessoryCircular)
        #endif
        default:
            VStack(alignment: .leading, spacing: 4) {
                Header(icon: "aqi.medium", title: "Air Quality")
                Text(d.aqi.map(String.init) ?? "--").font(.system(size: 40, weight: .regular, design: .rounded))
                Text(d.aqi.map(aqiLabel) ?? "No data").font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                ScaleBar(colors: aqiColors, fraction: min(1, Double(v) / 300))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 9. Pressure

struct PressureWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "DopplerIQPressure", intent: WidgetPlaceIntent.self, provider: WxProvider2()) { d in
            WxFrame(d: d) { PressureView(d: d) }
        }
        .configurationDisplayName("Pressure")
        .description("Air pressure on a dial from low to high.")
        .supportedFamilies(families([.systemSmall], lock: circular))
    }
}

struct PressureView: View {
    @Environment(\.widgetFamily) private var family
    let d: WxData
    var body: some View {
        let us = WxData.us
        let p = d.pressure ?? (us ? 29.92 : 1013)
        let lo = us ? 28.9 : 980.0, hi = us ? 30.9 : 1046.0
        let frac = min(1, max(0, (p - lo) / (hi - lo)))
        #if os(iOS)
        if family == .accessoryCircular {
            Gauge(value: frac) { Text(us ? "inHg" : "hPa") } currentValueLabel: { Text(us ? String(format: "%.2f", p) : "\(Int(p.rounded()))") }
                .gaugeStyle(.accessoryCircular)
        } else {
            dial(p: p, frac: frac, us: us)
        }
        #else
        dial(p: p, frac: frac, us: us)
        #endif
    }

    private func dial(p: Double, frac: Double, us: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Header(icon: "gauge.with.dots.needle.33percent", title: "Pressure")
            GeometryReader { g in
                let s = min(g.size.width, g.size.height), r = s / 2
                ZStack {
                    ForEach(0..<40, id: \.self) { i in
                        let a = -135 + Double(i) * 270 / 39
                        Rectangle().fill(.white.opacity(abs(Double(i) / 39 - frac) < 0.03 ? 1 : 0.3))
                            .frame(width: abs(Double(i) / 39 - frac) < 0.03 ? 3 : 1.5, height: abs(Double(i) / 39 - frac) < 0.03 ? 12 : 7)
                            .offset(y: -r + 6).rotationEffect(.degrees(a))
                    }
                    VStack(spacing: 0) {
                        Text(us ? String(format: "%.2f", p) : "\(Int(p.rounded()))").font(.system(size: r * 0.42, weight: .semibold, design: .rounded))
                        Text(us ? "inHg" : "hPa").font(.system(size: r * 0.2))
                    }
                }
                .frame(width: s, height: s)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack { Text("Low"); Spacer(); Text("High") }.font(.caption2).foregroundStyle(.white.opacity(0.7))
        }
    }
}

// MARK: - 10. Four gauges: AQI, humidity, UV, rain

struct GaugesWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "DopplerIQGauges", intent: WidgetPlaceIntent.self, provider: WxProvider2(needs: .aqi)) { d in
            WxFrame(d: d) { GaugesView(d: d) }
        }
        .configurationDisplayName("At a Glance")
        .description("Air quality, humidity, UV and rain chance as four small gauges.")
        .supportedFamilies(families([.systemSmall], lock: rectangular))
    }
}

struct GaugesView: View {
    @Environment(\.widgetFamily) private var family
    let d: WxData
    var body: some View {
        #if os(iOS)
        if family == .accessoryRectangular {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                GridRow { lockItem("aqi.medium", "AQI", d.aqi.map(String.init) ?? "--"); lockItem("humidity.fill", "Hum", "\(Int((d.humidity ?? 0).rounded()))%") }
                GridRow { lockItem("sun.max.fill", "UV", "\(Int((d.uv ?? 0).rounded()))"); lockItem("drop.fill", "Rain", "\(d.rainChance ?? 0)%") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            grid
        }
        #else
        grid
        #endif
    }

    private func lockItem(_ icon: String, _ label: String, _ v: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 11))
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(v).font(.system(size: 14, weight: .bold)).monospacedDigit()
        }
        .lineLimit(1).minimumScaleFactor(0.7)
    }

    private var grid: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                arc(value: Double(d.aqi ?? 0) / 300, text: d.aqi.map(String.init) ?? "--", unit: "", label: "AQI", color: d.aqi.map(aqiColor) ?? .gray)
                arc(value: (d.humidity ?? 0) / 100, text: "\(Int((d.humidity ?? 0).rounded()))", unit: "%", label: "Humidity", color: Color(red: 0.45, green: 0.7, blue: 1))
            }
            GridRow {
                let uv = d.uv ?? 0
                VStack(spacing: 2) {
                    ZStack {
                        Image(systemName: "seal.fill").font(.system(size: 38)).foregroundStyle(uvColor(uv).opacity(0.55))
                        Circle().fill(uvColor(uv)).frame(width: 28, height: 28)
                        Text("\(Int(uv.rounded()))").font(.system(size: 15, weight: .bold, design: .rounded))
                    }
                    .frame(height: 40)
                    Text(uv < 3 ? "Safe" : uvLabel(uv)).font(.caption2).foregroundStyle(.white.opacity(0.75)).lineLimit(1).minimumScaleFactor(0.7)
                }
                VStack(spacing: 2) {
                    let pop = d.rainChance ?? 0
                    ZStack(alignment: .bottom) {
                        Circle().fill(.white.opacity(0.1))
                        Rectangle().fill(Color(red: 0.4, green: 0.65, blue: 1).opacity(0.8))
                            .frame(height: 40 * CGFloat(pop) / 100)
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                    .overlay(Text("\(pop)%").font(.system(size: 13, weight: .bold, design: .rounded)))
                    Text("Rain").font(.caption2).foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func arc(value: Double, text: String, unit: String, label: String, color: Color) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().trim(from: 0, to: 0.5).stroke(.white.opacity(0.15), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(180))
                Circle().trim(from: 0, to: 0.5 * min(1, max(0.02, value))).stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(180))
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(text).font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(unit).font(.system(size: 8, weight: .bold))
                }
                .offset(y: -2)
            }
            .frame(width: 44, height: 44)
            .offset(y: 8)
            Text(label).font(.caption2).foregroundStyle(.white.opacity(0.75))
        }
    }
}

// MARK: - 11. Seas

struct SeasWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "DopplerIQSeas", intent: WidgetPlaceIntent.self, provider: WxProvider2(needs: .sea)) { d in
            WxFrame(d: d) { SeasView(d: d) }
        }
        .configurationDisplayName("Seas")
        .description("Wave height, period and direction, and the water temperature. Pick a coastal city when editing the widget.")
        .supportedFamilies(families([.systemSmall, .systemMedium], lock: rectangular))
    }
}

struct SeasView: View {
    @Environment(\.widgetFamily) private var family
    let d: WxData
    private var len: String { WxData.us ? "ft" : "m" }
    var body: some View {
        if let s = d.sea {
            switch family {
            #if os(iOS)
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Label("Seas · \(d.place)", systemImage: "water.waves").font(.headline).lineLimit(1)
                    Text(String(format: "%.1f %@ · %d s · %@", s.wave, len, Int(s.period.rounded()), compass(s.dir)))
                    if let w = s.water { Text("Water \(f0(w))").foregroundStyle(.secondary) }
                }
            #endif
            case .systemMedium:
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Header(icon: "water.waves", title: "Seas · \(d.place)")
                        Text(String(format: "%.1f %@", s.wave, len)).font(.system(size: 38, weight: .regular, design: .rounded))
                        Text("Waves every \(Int(s.period.rounded())) seconds").font(.caption).foregroundStyle(.white.opacity(0.75))
                        Spacer(minLength: 0)
                        if let w = s.water { Label("Water \(f0(w))", systemImage: "thermometer.medium").font(.subheadline.weight(.semibold)) }
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: 6) {
                        Compass(dir: s.dir, speed: d.wind ?? 0, unit: WxData.us ? "mph" : "km/h").frame(width: 96, height: 96)
                        Text("Waves from \(compass(s.dir))").font(.caption2).foregroundStyle(.white.opacity(0.75))
                    }
                }
            default:
                VStack(alignment: .leading, spacing: 4) {
                    Header(icon: "water.waves", title: "Seas")
                    Text(String(format: "%.1f %@", s.wave, len)).font(.system(size: 34, weight: .regular, design: .rounded))
                    Text("\(Int(s.period.rounded())) s from \(compass(s.dir))").font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    WaveShape().fill(Color(red: 0.3, green: 0.6, blue: 0.95).opacity(0.6)).frame(height: 18)
                    if let w = s.water { Text("Water \(f0(w))").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.8)) }
                }
            }
        } else {
            WxMessage(text: "No sea data for \(d.place). Edit the widget and pick a coastal city.")
        }
    }
}

private struct WaveShape: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 0, y: r.midY))
            for i in 0...40 {
                let x = r.width * CGFloat(i) / 40
                p.addLine(to: CGPoint(x: x, y: r.midY + sin(Double(i) / 40 * .pi * 4) * r.height * 0.35))
            }
            p.addLine(to: CGPoint(x: r.width, y: r.height)); p.addLine(to: CGPoint(x: 0, y: r.height)); p.closeSubpath()
        }
    }
}

// MARK: - 12. Glance: temperature ring with the sky under it, high and low on the right, AQI and UV along the bottom
// Small on iPhone, a wider version for iPad and the Mac desktop, and three simple Lock Screen styles.

struct GlanceWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "DopplerIQGlance", intent: WidgetPlaceIntent.self, provider: WxProvider2(needs: .aqi)) { d in
            WxFrame(d: d) { GlanceView(d: d) }
                .containerBackground(for: .widget) { GlanceBackdrop() }
        }
        .configurationDisplayName("Glance")
        .description("The temperature ring with today's sky under it, the high and low, plus air quality and UV.")
        .supportedFamilies(families([.systemSmall, .systemMedium], lock: allLock))
    }
}

private var allLock: [WidgetFamily] {
    #if os(iOS)
    [.accessoryCircular, .accessoryRectangular, .accessoryInline]
    #else
    []
    #endif
}

/// Dark gradient on the Home Screen and desktop, clear on the Lock Screen.
private struct GlanceBackdrop: View {
    @Environment(\.widgetFamily) private var family
    var body: some View {
        switch family {
        #if os(iOS)
        case .accessoryCircular, .accessoryRectangular, .accessoryInline: Color.clear
        #endif
        default: LinearGradient(colors: [Color(white: 0.13), Color(white: 0.04)], startPoint: .top, endPoint: .bottom)
        }
    }
}

struct GlanceView: View {
    @Environment(\.widgetFamily) private var family
    let d: WxData

    private var next: [WxHour] { Array(d.hours.prefix(24)) }
    private var peak: WxHour? { next.max(by: { $0.temp < $1.temp }) }
    private var trough: WxHour? { next.min(by: { $0.temp < $1.temp }) }
    private var lo: Double { min(trough?.temp ?? d.lo ?? (d.temp ?? 0) - 10, d.temp ?? .infinity) }
    private var hi: Double { max(peak?.temp ?? d.hi ?? (d.temp ?? 0) + 10, d.temp ?? -.infinity, lo + 1) }
    private var frac: Double { min(1, max(0, ((d.temp ?? lo) - lo) / (hi - lo))) }
    private var aqiText: String { d.aqi.map(String.init) ?? "--" }
    private var uvText: String { "\(Int((d.uv ?? 0).rounded()))" }

    var body: some View {
        switch family {
        #if os(iOS)
        case .accessoryCircular:
            Gauge(value: d.temp ?? lo, in: lo...hi) { Text("°") } currentValueLabel: { Text(f0(d.temp)) }
                minimumValueLabel: { Text(f0(lo)).font(.system(size: 9)) } maximumValueLabel: { Text(f0(hi)).font(.system(size: 9)) }
                .gaugeStyle(.accessoryCircular)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: WidgetWeather.symbol(d.code, day: d.isDay))
                    Text(f0(d.temp)).bold()
                    Text("H:\(f0(hi)) L:\(f0(lo))").foregroundStyle(.secondary)
                }
                .font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                Text("AQI \(aqiText)  ·  UV \(uvText)").font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            Label("\(f0(d.temp))  AQI \(aqiText)  UV \(uvText)", systemImage: WidgetWeather.symbol(d.code, day: d.isDay))
        #endif
        case .systemMedium: medium
        default: small
        }
    }

    // iPhone Home Screen (and the small size on iPad and Mac)
    private var small: some View {
        VStack(spacing: 4) {
            place
            HStack(spacing: 4) {
                ring.frame(width: 76, height: 76)
                VStack(spacing: 1) {
                    tempPill(hi, warm: true)
                    Text(clock(peak?.time)).font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 2)
                    tempPill(lo, warm: false)
                    Text(clock(trough?.time)).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: 76)
                .layoutPriority(1)
            }
            HStack(spacing: 6) {
                chip("AQI", aqiText, color: d.aqi.map(aqiColor) ?? .gray)
                chip("UV", uvText, color: uvColor(d.uv ?? 0))
            }
        }
    }

    // iPad and Mac desktop: bigger ring, high and low beside it, AQI and UV with what they mean
    private var medium: some View {
        VStack(spacing: 6) {
            place
            HStack(spacing: 14) {
                ring.frame(width: 104, height: 104)
                VStack(spacing: 2) {
                    tempPill(hi, warm: true)
                    Text("High \(clock(peak?.time))").font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    tempPill(lo, warm: false)
                    Text("Low \(clock(trough?.time))").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(width: 70, height: 104)
                VStack(alignment: .leading, spacing: 8) {
                    reading("AQI", aqiText, d.aqi.map(aqiLabel) ?? "No data", color: d.aqi.map(aqiColor) ?? .gray)
                    reading("UV", uvText, uvLabel(d.uv ?? 0), color: uvColor(d.uv ?? 0))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var place: some View {
        HStack(spacing: 3) {
            if d.located { Image(systemName: "location.fill").font(.system(size: 8)) }
            Text(d.place).lineLimit(1)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
    }

    private var ring: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height), lw = s * 0.11, r = (s - lw) / 2
            let a = Angle.degrees(135 + 270 * frac)
            ZStack {
                Circle().trim(from: 0, to: 0.75).stroke(.white.opacity(0.12), style: StrokeStyle(lineWidth: lw, lineCap: .round)).rotationEffect(.degrees(135))
                Circle().trim(from: 0, to: 0.75)
                    .stroke(AngularGradient(colors: [Color(red: 0.35, green: 0.65, blue: 1), Color(red: 0.98, green: 0.8, blue: 0.3), Color(red: 0.98, green: 0.4, blue: 0.3)],
                                            center: .center, startAngle: .degrees(0), endAngle: .degrees(270)),
                            style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle().fill(.white).frame(width: lw * 1.25, height: lw * 1.25)
                    .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 2))
                    .offset(x: r * cos(a.radians), y: r * sin(a.radians))
                VStack(spacing: 0) {
                    Text(f0(d.temp)).font(.system(size: s * 0.27, weight: .medium)).minimumScaleFactor(0.6)
                    Image(systemName: WidgetWeather.symbol(d.code, day: d.isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: s * 0.17))
                }
            }
            .frame(width: s, height: s)
        }
    }

    private func tempPill(_ v: Double, warm: Bool) -> some View {
        Text("\(Int(v.rounded()))°")
            .font(.system(size: 15, weight: .semibold)).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.6)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .frame(minWidth: 44)
            .background((warm ? Color(red: 0.98, green: 0.45, blue: 0.3) : Color(red: 0.35, green: 0.62, blue: 1)).opacity(0.35), in: Capsule())
    }

    /// Small "AQI 46" / "UV 3" capsule for the bottom row.
    private func chip(_ label: String, _ v: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
            Text(v).font(.system(size: 12, weight: .bold)).monospacedDigit()
        }
        .lineLimit(1).minimumScaleFactor(0.7)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.4), in: Capsule())
    }

    /// Medium size: a colored value pill with its name and what it means.
    private func reading(_ label: String, _ v: String, _ meaning: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(v).font(.system(size: 17, weight: .bold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(minWidth: 46).padding(.vertical, 4)
                .background(color.opacity(0.4), in: Capsule())
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(meaning).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }

    private func clock(_ t: Date?) -> String {
        guard let t else { return "" }
        if abs(t.timeIntervalSinceNow) < 45 * 60 { return "now" }
        let f = DateFormatter(); f.dateFormat = "ha"
        return f.string(from: t).lowercased().replacingOccurrences(of: "m", with: "")   // 3p, 6a
    }
}

// MARK: - Bundle (WidgetKit takes up to 10 per bundle, so these sit in their own group)

struct MoreWidgets: WidgetBundle {
    var body: some Widget {
        GlanceWidget()
        ForecastStripWidget()
        ConditionsWidget()
        RetroWidget()
        WindWidget()
        UVWidget()
        SunWidget()
        MoonWidget()
        AirWidget()
        MoreWidgets2().body
    }
}

struct MoreWidgets2: WidgetBundle {
    var body: some Widget {
        GaugesWidget()
        PressureWidget()
        SeasWidget()
    }
}
