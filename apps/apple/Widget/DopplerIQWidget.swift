import WidgetKit
import SwiftUI
import AppIntents
import CoreLocation

// Home Screen and desktop widgets: current conditions, the next few hours, the week ahead, and a red
// banner when the National Weather Service has an alert for that spot. Free on every plan.

// MARK: - Settings (long-press the widget > Edit Widget)

struct WidgetPlaceIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Weather"
    static var description = IntentDescription("Weather where you are, or for any city.")

    @Parameter(title: "City", description: "Leave empty to follow your location.")
    var city: String?
}

// MARK: - Data

struct WxEntry: TimelineEntry {
    let date: Date
    var place = "DopplerIQ"
    var temp: Double?
    var code = 0
    var isDay = true
    var hi: Double?
    var lo: Double?
    var feels: Double?
    var rainChance: Int?
    var hours: [(time: Date, temp: Double, code: Int, isDay: Bool)] = []
    var days: [(date: Date, hi: Double, lo: Double, code: Int, rain: Int)] = []
    var alert: String?
    var message: String?
    /// Warmest and coolest hours in the next 24 (for the Temperature gauge).
    var peak: (time: Date, temp: Double)?
    var trough: (time: Date, temp: Double)?
    var locationBased = true

    static let sample: WxEntry = {
        var e = WxEntry(date: .now, place: "Atlanta", temp: 72, code: 2, hi: 78, lo: 61, feels: 74, rainChance: 20)
        for i in 1...6 { e.hours.append((time: Date.now.addingTimeInterval(Double(i) * 3600), temp: 72 + Double(i % 3), code: [2, 3, 61][i % 3], isDay: true)) }
        e.peak = (time: Date.now.addingTimeInterval(3 * 3600), temp: 92); e.trough = (time: Date.now.addingTimeInterval(18 * 3600), temp: 72); e.temp = 82
        for i in 0..<5 { e.days.append((date: Date.now.addingTimeInterval(Double(i) * 86400), hi: 78 - Double(i), lo: 60 + Double(i % 2), code: [1, 2, 61, 95, 0][i], rain: [10, 20, 60, 70, 0][i])) }
        return e
    }()
}

enum WidgetWeather {
    static var fahrenheit: Bool { Locale.current.measurementSystem == .us }

    static func load(_ city: String?) async -> WxEntry {
        var lat: Double, lon: Double, name: String
        let typed = city?.trimmingCharacters(in: .whitespaces) ?? ""
        if !typed.isEmpty {
            guard let hit = await geocode(typed) else { return WxEntry(date: .now, message: "Couldn't find \(typed)") }
            (lat, lon, name) = hit
        } else if let loc = CLLocationManager().location {
            lat = loc.coordinate.latitude; lon = loc.coordinate.longitude
            name = await placeName(lat, lon) ?? "My Location"
        } else {
            return WxEntry(date: .now, message: "Open DopplerIQ once to share your location, or edit the widget to pick a city.")
        }
        var e = WxEntry(date: .now, place: name)
        e.locationBased = typed.isEmpty
        let unit = fahrenheit ? "&temperature_unit=fahrenheit" : ""
        let url = URL(string: String(format: "https://api.open-meteo.com/v1/forecast?latitude=%.3f&longitude=%.3f", lat, lon)
            + "&current=temperature_2m,apparent_temperature,weather_code,is_day&hourly=temperature_2m,weather_code,is_day&daily=temperature_2m_max,temperature_2m_min,weather_code,precipitation_probability_max&forecast_days=6&timezone=auto&timeformat=unixtime" + unit)!
        if let j = await json(url) {
            let c = j["current"] as? [String: Any] ?? [:]
            e.temp = num(c["temperature_2m"]); e.feels = num(c["apparent_temperature"])
            e.code = Int(num(c["weather_code"]) ?? 0); e.isDay = (num(c["is_day"]) ?? 1) == 1
            if let h = j["hourly"] as? [String: Any] {
                let t = nums(h["time"]), tp = nums(h["temperature_2m"]), cd = nums(h["weather_code"]), dy = nums(h["is_day"])
                let now = Date().timeIntervalSince1970
                let start = t.firstIndex { $0 > now } ?? 0
                for i in start..<min(start + 6, t.count) where i < tp.count {
                    e.hours.append((time: Date(timeIntervalSince1970: t[i]), temp: tp[i], code: Int(cd[safe: i] ?? 0), isDay: (dy[safe: i] ?? 1) == 1))
                }
                let next = Array(start..<min(start + 24, t.count, tp.count))
                if let hi = next.max(by: { tp[$0] < tp[$1] }) { e.peak = (time: Date(timeIntervalSince1970: t[hi]), temp: tp[hi]) }
                if let lo = next.min(by: { tp[$0] < tp[$1] }) { e.trough = (time: Date(timeIntervalSince1970: t[lo]), temp: tp[lo]) }
            }
            if let d = j["daily"] as? [String: Any] {
                let t = nums(d["time"]), hi = nums(d["temperature_2m_max"]), lo = nums(d["temperature_2m_min"]), cd = nums(d["weather_code"]), pr = nums(d["precipitation_probability_max"])
                e.hi = hi.first; e.lo = lo.first; e.rainChance = pr.first.map { Int($0) }
                for i in 0..<min(t.count, hi.count, lo.count) {
                    e.days.append((date: Date(timeIntervalSince1970: t[i]), hi: hi[i], lo: lo[i], code: Int(cd[safe: i] ?? 0), rain: Int(pr[safe: i] ?? 0)))
                }
            }
            // The hourly list starts at the next full hour, so the reading right now isn't in it.
            // Count it, otherwise the "high" pill can show a lower number than the current temperature.
            if let now = e.temp {
                if e.peak == nil || now >= e.peak!.temp { e.peak = (time: .now, temp: now) }
                if e.trough == nil || now <= e.trough!.temp { e.trough = (time: .now, temp: now) }
            }
        } else {
            e.message = "Weather is unavailable right now."
        }
        // NWS alerts (US only; elsewhere this just comes back empty)
        if let u = URL(string: String(format: "https://api.weather.gov/alerts/active?point=%.4f,%.4f", lat, lon)), let j = await json(u, nws: true),
           let f = (j["features"] as? [[String: Any]])?.compactMap({ ($0["properties"] as? [String: Any])?["event"] as? String }), let first = f.first {
            e.alert = f.count > 1 ? "\(first) +\(f.count - 1)" : first
        }
        return e
    }

    private static func geocode(_ q: String) async -> (Double, Double, String)? {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: q.components(separatedBy: ",").first ?? q), .init(name: "count", value: "1")]
        guard let u = c.url, let j = await json(u), let r = (j["results"] as? [[String: Any]])?.first,
              let la = num(r["latitude"]), let lo = num(r["longitude"]) else { return nil }
        let name = [r["name"] as? String, r["admin1"] as? String ?? r["country_code"] as? String].compactMap { $0 }.joined(separator: ", ")
        return (la, lo, name.isEmpty ? q : name)
    }

    private static func placeName(_ lat: Double, _ lon: Double) async -> String? {
        let loc = CLLocation(latitude: lat, longitude: lon)
        guard let p = try? await CLGeocoder().reverseGeocodeLocation(loc).first else { return nil }
        return p.locality ?? p.subAdministrativeArea ?? p.administrativeArea
    }

    private static func json(_ url: URL, nws: Bool = false) async -> [String: Any]? {
        var r = URLRequest(url: url); r.timeoutInterval = 15
        r.setValue("DopplerIQWeather/1.0 (github.com/CRutherford3/weather)", forHTTPHeaderField: "User-Agent")
        if nws { r.setValue("application/geo+json", forHTTPHeaderField: "Accept") }
        guard let d = try? await URLSession.shared.data(for: r).0 else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
    private static func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
    private static func nums(_ v: Any?) -> [Double] { (v as? [Any] ?? []).map { ($0 as? NSNumber)?.doubleValue ?? 0 } }

    /// WMO weather code -> SF Symbol and words.
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
    static func words(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 56, 57, 66, 67: return "Freezing rain"
        case 61, 80: return "Light rain"
        case 63, 81: return "Rain"
        case 65, 82: return "Heavy rain"
        case 71, 85: return "Light snow"
        case 73, 75, 86: return "Snow"
        case 77: return "Snow grains"
        case 95: return "Thunderstorms"
        case 96, 99: return "Storms with hail"
        default: return ""
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

struct WxProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> WxEntry { .sample }
    func snapshot(for configuration: WidgetPlaceIntent, in context: Context) async -> WxEntry {
        context.isPreview ? .sample : await WidgetWeather.load(configuration.city)
    }
    func timeline(for configuration: WidgetPlaceIntent, in context: Context) async -> Timeline<WxEntry> {
        let e = await WidgetWeather.load(configuration.city)
        return Timeline(entries: [e], policy: .after(Date().addingTimeInterval(30 * 60)))
    }
}

// MARK: - Views

/// Where a tap on a widget goes. The app opens its Dashboard for this link.
enum WidgetLink {
    static let dashboard = URL(string: "doppleriq://dashboard")!
}

private let deg: (Double?) -> String = { $0.map { "\(Int($0.rounded()))°" } ?? "--" }

struct WxWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let e: WxEntry

    var body: some View {
        Group {
            if let m = e.message, e.temp == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Label("DopplerIQ", systemImage: "dot.radiowaves.left.and.right").font(.caption.bold())
                    Text(m).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                switch family {
                #if os(iOS)
                case .accessoryCircular: circular
                case .accessoryRectangular: rectangular
                case .accessoryInline: Text("\(deg(e.temp)) \(WidgetWeather.words(e.code))")
                #endif
                case .systemMedium: medium
                case .systemLarge, .systemExtraLarge: large
                default: small
                }
            }
        }
        .widgetURL(WidgetLink.dashboard)
        .containerBackground(for: .widget) {
            LinearGradient(colors: e.isDay ? [Color(red: 0.16, green: 0.38, blue: 0.78), Color(red: 0.36, green: 0.6, blue: 0.92)]
                                           : [Color(red: 0.05, green: 0.06, blue: 0.1), Color(red: 0.16, green: 0.17, blue: 0.22)],
                           startPoint: .top, endPoint: .bottom)
        }
        .foregroundStyle(.white)
    }

    private var header: some View {
        Text(e.place).font(.subheadline.bold()).lineLimit(1)
    }

    @ViewBuilder private var alertBar: some View {
        if let a = e.alert {
            Label(a, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2.bold()).lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.red.opacity(0.85), in: Capsule())
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            Text(deg(e.temp)).font(.system(size: 44, weight: .light)).minimumScaleFactor(0.6)
            Spacer(minLength: 0)
            if e.alert != nil { alertBar } else {
                Image(systemName: WidgetWeather.symbol(e.code, day: e.isDay)).symbolRenderingMode(.multicolor)
                Text(WidgetWeather.words(e.code)).font(.caption.bold()).lineLimit(1)
            }
            Text("H:\(deg(e.hi)) L:\(deg(e.lo))").font(.caption).opacity(0.9)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var hoursRow: some View {
        HStack {
            ForEach(Array(e.hours.prefix(6).enumerated()), id: \.offset) { _, h in
                VStack(spacing: 4) {
                    Text(h.time, format: .dateTime.hour()).font(.caption2).opacity(0.85)
                    Image(systemName: WidgetWeather.symbol(h.code, day: h.isDay)).symbolRenderingMode(.multicolor).frame(height: 18)
                    Text(deg(h.temp)).font(.caption.bold())
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Text(deg(e.temp)).font(.system(size: 38, weight: .light))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Image(systemName: WidgetWeather.symbol(e.code, day: e.isDay)).symbolRenderingMode(.multicolor).font(.title3)
                    Text(WidgetWeather.words(e.code)).font(.caption.bold())
                    Text("H:\(deg(e.hi)) L:\(deg(e.lo))").font(.caption).opacity(0.9)
                }
            }
            alertBar
            Spacer(minLength: 0)
            hoursRow
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 8) {
            medium.frame(height: 150)
            Divider().overlay(.white.opacity(0.3))
            ForEach(Array(e.days.prefix(5).enumerated()), id: \.offset) { i, d in
                HStack {
                    Text(i == 0 ? "Today" : d.date.formatted(.dateTime.weekday(.abbreviated))).font(.subheadline.bold()).frame(width: 54, alignment: .leading)
                    Image(systemName: WidgetWeather.symbol(d.code)).symbolRenderingMode(.multicolor).frame(width: 26)
                    Text(d.rain >= 20 ? "\(d.rain)%" : "").font(.caption.bold()).foregroundStyle(Color(red: 0.6, green: 0.85, blue: 1)).frame(width: 36)
                    Spacer()
                    Text(deg(d.lo)).opacity(0.75)
                    Text(deg(d.hi)).bold().frame(width: 40, alignment: .trailing)
                }
                .font(.subheadline)
            }
            Spacer(minLength: 0)
        }
    }

    private var circular: some View {
        VStack(spacing: 0) {
            Image(systemName: WidgetWeather.symbol(e.code, day: e.isDay))
            Text(deg(e.temp)).font(.headline)
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(e.alert ?? e.place).font(.headline).lineLimit(1)
            Text("\(deg(e.temp)) \(WidgetWeather.words(e.code))").lineLimit(1)
            Text("H:\(deg(e.hi)) L:\(deg(e.lo))").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Widget

struct DopplerIQWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "DopplerIQWeather", intent: WidgetPlaceIntent.self, provider: WxProvider()) { e in
            WxWidgetView(e: e)
        }
        .configurationDisplayName("DopplerIQ Weather")
        .description("Conditions, the next few hours and the week ahead, with severe weather alerts.")
        .supportedFamilies(Self.families)
    }

    static var families: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        #else
        [.systemSmall, .systemMedium, .systemLarge]
        #endif
    }
}

@main
struct DopplerIQWidgets: WidgetBundle {
    var body: some Widget {
        DopplerIQWidget()
        TemperatureWidget()
        MoreWidgets().body
    }
}

// MARK: - Temperature gauge widget

/// Current temperature on a ring that runs from the next 24 hours' low to high, with the warmest and
/// coolest hours beside it. Small on the Home Screen / desktop, and a round gauge on the Lock Screen.
struct TemperatureWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "DopplerIQTemperature", intent: WidgetPlaceIntent.self, provider: WxProvider()) { e in
            TemperatureView(e: e)
        }
        .configurationDisplayName("Temperature")
        .description("Today's temperature on a gauge, with the high and low and when they happen.")
        .supportedFamilies(Self.families)
    }
    static var families: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .accessoryCircular, .accessoryRectangular]
        #else
        [.systemSmall]
        #endif
    }
}

struct TemperatureView: View {
    @Environment(\.widgetFamily) private var family
    let e: WxEntry

    private var lo: Double { min(e.trough?.temp ?? e.lo ?? (e.temp ?? 0) - 10, e.temp ?? .infinity) }
    private var hi: Double { max(e.peak?.temp ?? e.hi ?? (e.temp ?? 0) + 10, e.temp ?? -.infinity, lo + 1) }
    /// Where the current temperature sits between the low and the high (0...1).
    private var fraction: Double { guard let t = e.temp else { return 0.5 }; return min(1, max(0, (t - lo) / (hi - lo))) }

    var body: some View {
        Group {
            if let m = e.message, e.temp == nil {
                Text(m).font(.caption).foregroundStyle(.secondary)
            } else {
                switch family {
                #if os(iOS)
                case .accessoryCircular:
                    Gauge(value: e.temp ?? lo, in: lo...hi) { Text("°") } currentValueLabel: { Text(deg(e.temp)) }
                        minimumValueLabel: { Text(deg(lo)).font(.system(size: 9)) } maximumValueLabel: { Text(deg(hi)).font(.system(size: 9)) }
                        .gaugeStyle(.accessoryCircular)
                case .accessoryRectangular:
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(deg(e.temp)) \(e.place)").font(.headline).lineLimit(1)
                        Gauge(value: e.temp ?? lo, in: lo...hi) { EmptyView() }.gaugeStyle(.accessoryLinearCapacity)
                        Text("\(deg(lo)) \(time(e.trough?.time))  ·  \(deg(hi)) \(time(e.peak?.time))").font(.caption2).foregroundStyle(.secondary)
                    }
                #endif
                default: small
                }
            }
        }
        .widgetURL(WidgetLink.dashboard)
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(white: 0.13), Color(white: 0.04)], startPoint: .top, endPoint: .bottom)
        }
    }

    private var small: some View {
        VStack(spacing: 6) {
            HStack(spacing: 3) {
                if e.locationBased { Image(systemName: "location.fill").font(.system(size: 8)) }
                Text(e.locationBased && e.place == "My Location" ? "Current Location" : e.place).lineLimit(1)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
            HStack(spacing: 4) {
                ring.frame(width: 80, height: 80)
                VStack(spacing: 2) {
                    pill(e.peak?.temp ?? hi, warm: true)
                    Text(time(e.peak?.time)).font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    pill(e.trough?.temp ?? lo, warm: false)
                    Text(time(e.trough?.time)).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .layoutPriority(1)
            }
        }
        .foregroundStyle(.white)
    }

    /// 270 degree ring, open at the bottom, colored cool to warm, with a dot at the current temperature.
    private var ring: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height), lw = side * 0.11
            let r = (side - lw) / 2
            let angle = Angle.degrees(135 + 270 * fraction)
            ZStack {
                Circle().trim(from: 0, to: 0.75)
                    .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle().trim(from: 0, to: 0.75)
                    .stroke(AngularGradient(colors: [Color(red: 0.35, green: 0.65, blue: 1), Color(red: 0.98, green: 0.8, blue: 0.3), Color(red: 0.98, green: 0.4, blue: 0.3)],
                                            center: .center, startAngle: .degrees(0), endAngle: .degrees(270)),
                            style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle().fill(.white).frame(width: lw * 1.25, height: lw * 1.25)
                    .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 2))
                    .offset(x: r * cos(angle.radians), y: r * sin(angle.radians))
                Text(deg(e.temp)).font(.system(size: side * 0.3, weight: .medium)).minimumScaleFactor(0.6)
            }
            .frame(width: side, height: side)
        }
    }

    private func pill(_ v: Double, warm: Bool) -> some View {
        Text(deg(v))
            .font(.system(size: 15, weight: .semibold)).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.6)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .frame(minWidth: 44)
            .background((warm ? Color(red: 0.98, green: 0.45, blue: 0.3) : Color(red: 0.35, green: 0.62, blue: 1)).opacity(0.35), in: Capsule())
    }

    private func time(_ d: Date?) -> String {
        guard let d else { return "" }
        if abs(d.timeIntervalSinceNow) < 45 * 60 { return "now" }
        let f = DateFormatter(); f.dateFormat = "ha"
        return f.string(from: d).lowercased().replacingOccurrences(of: "m", with: "")   // 3p, 6a
    }
}
