import SwiftUI
import Charts
import ImageIO
import CoreLocation

// MARK: - Animated image (GIF loops play, still images show as-is)

/// Loads an image from the web. Animated GIFs (radar and satellite loops) play like on the website.
struct RemoteImage: View {
    let url: URL?
    var minHeight: CGFloat = 140
    @State private var frames: [CGImage] = []
    @State private var delays: [Double] = []
    @State private var failed = false

    var body: some View {
        Group {
            if frames.count > 1 {
                TimelineView(.periodic(from: .now, by: 0.08)) { ctx in
                    Image(decorative: frames[frameIndex(ctx.date)], scale: 1).resizable().scaledToFit()
                }
            } else if let f = frames.first {
                Image(decorative: f, scale: 1).resizable().scaledToFit()
            } else if failed {
                Label("Image unavailable", systemImage: "photo").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: minHeight)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: minHeight)
            }
        }
        .task(id: url) { await load() }
    }

    private func frameIndex(_ d: Date) -> Int {
        let total = delays.reduce(0, +)
        guard total > 0 else { return 0 }
        var t = d.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: total)
        for (i, dl) in delays.enumerated() { if t < dl { return i }; t -= dl }
        return frames.count - 1
    }

    private func load() async {
        guard let url else { failed = true; return }
        var req = URLRequest(url: url)
        req.setValue(AppConfig.userAgent, forHTTPHeaderField: "User-Agent")
        guard let data = try? await URLSession.shared.data(for: req).0 else { failed = true; return }
        let decoded = await Task.detached(priority: .userInitiated) { Self.decode(data) }.value
        if decoded.0.isEmpty { failed = true } else { frames = decoded.0; delays = decoded.1 }
    }

    /// Decodes up to 60 frames, scaled to at most 1200 px, with each frame's delay (the last frame holds longer).
    nonisolated static func decode(_ data: Data) -> ([CGImage], [Double]) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return ([], []) }
        let n = min(CGImageSourceGetCount(src), 60)
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1200,
                                     kCGImageSourceShouldCacheImmediately: true, kCGImageSourceCreateThumbnailWithTransform: true]
        var imgs: [CGImage] = [], ds: [Double] = []
        for i in 0..<n {
            guard let img = CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary) else { continue }
            imgs.append(img)
            var d = 0.1
            if let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
               let gif = p[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                let v = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
                d = max(0.05, v)
            }
            ds.append(d)
        }
        if ds.count > 1 { ds[ds.count - 1] = max(ds[ds.count - 1], 1.2) }
        return (imgs, ds)
    }
}

// MARK: - Shared lookups

enum LiveData {
    static func get(_ s: String) async -> Data? {
        guard let url = URL(string: s) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(AppConfig.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/geo+json, application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 25
        return try? await URLSession.shared.data(for: req).0
    }
    static func json(_ s: String) async -> Any? {
        guard let d = await get(s) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }
    static func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }
    static func str(_ v: Any?) -> String { (v as? String) ?? (v as? NSNumber)?.stringValue ?? "" }

    struct Point { let cwa: String; let forecast: String; let radar: String }
    /// NWS office, forecast URL and radar for a US location.
    static func nwsPoint(_ p: Place) async -> Point? {
        guard let j = await json(String(format: "https://api.weather.gov/points/%.4f,%.4f", p.lat, p.lon)) as? [String: Any],
              let pr = j["properties"] as? [String: Any] else { return nil }
        return Point(cwa: str(pr["cwa"]), forecast: str(pr["forecast"]), radar: str(pr["radarStation"]))
    }

    struct Storm: Identifiable { let id: String; let name: String; let kind: String; let mph: Int; let pressure: String; let movement: String
        /// Tropical Tidbits storm id, e.g. "05L"
        var ttId: String {
            let b = id.prefix(2).uppercased(), num = id.dropFirst(2).prefix(2)
            return "\(num)\(["AL": "L", "EP": "E", "CP": "C"][b] ?? "L")"
        }
    }
    static func storms() async -> [Storm]? {
        guard let j = await json("https://www.nhc.noaa.gov/CurrentStorms.json") as? [String: Any] else { return nil }
        return (j["activeStorms"] as? [[String: Any]] ?? []).map { s in
            let c = str(s["classification"])
            let kind = c == "HU" ? "Hurricane" : c == "TS" ? "Tropical Storm" : c == "TD" ? "Tropical Depression" : c == "PTC" ? "Potential Tropical Cyclone" : "Tropical System"
            let mv = num(s["movementSpeed"]).map { "\(str(s["movementDir"]))° at \(Int(($0 * 1.15078).rounded())) mph" } ?? ""
            return Storm(id: str(s["id"]), name: str(s["name"]), kind: kind, mph: Int(((num(s["intensity"]) ?? 0) * 1.15078).rounded()),
                         pressure: str(s["pressure"]), movement: mv)
        }
    }

    /// Every NEXRAD (WSR-88D) radar, from the NWS. Loaded once per launch.
    private static var sitesCache: [RadarService.Site]?
    static func radarSites() async -> [RadarService.Site] {
        if let c = sitesCache { return c }
        guard let j = await json("https://api.weather.gov/radar/stations?stationType=WSR-88D") as? [String: Any],
              let fs = j["features"] as? [[String: Any]] else { return [] }
        let list: [RadarService.Site] = fs.compactMap { f in
            guard let p = f["properties"] as? [String: Any], let g = f["geometry"] as? [String: Any],
                  let c = g["coordinates"] as? [Any], c.count >= 2, let lo = num(c[0]), let la = num(c[1]) else { return nil }
            return RadarService.Site(id: str(p["id"]), name: str(p["name"]), lat: la, lon: lo)
        }
        sitesCache = list
        return list
    }
    static func nearestSite(_ p: Place) async -> RadarService.Site? {
        await radarSites().min { a, b in
            let da = pow(a.lat - p.lat, 2) + pow((a.lon - p.lon) * cos(p.lat * .pi / 180), 2)
            let db = pow(b.lat - p.lat, 2) + pow((b.lon - p.lon) * cos(p.lat * .pi / 180), 2)
            return da < db
        }
    }

    struct BuoyCam: Identifiable { let id: String; let name: String; let lat: Double; let lon: Double; let img: String
        var url: URL? { URL(string: "https://www.ndbc.noaa.gov/images/buoycam/\(img)") }
        var page: URL? { URL(string: "https://www.ndbc.noaa.gov/buoycam.php?station=\(id)") }
        /// Photo time, from the file name (…_2026_11_10_1310.jpg).
        var time: String {
            guard let r = img.range(of: #"\d{4}_\d\d_\d\d_\d{4}"#, options: .regularExpression) else { return "" }
            let s = String(img[r]); let f = DateFormatter()
            f.dateFormat = "yyyy_MM_dd_HHmm"; f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX")
            return f.date(from: s)?.formatted(date: .abbreviated, time: .shortened) ?? ""
        }
    }
    /// NOAA BuoyCAMs: live photos from cameras on offshore buoys.
    static func buoyCams() async -> [BuoyCam] {
        guard let list = await json("https://www.ndbc.noaa.gov/buoycams.php") as? [[String: Any]] else { return [] }
        return list.compactMap { c in
            let img = str(c["img"])
            guard !img.isEmpty, let la = num(c["lat"]), let lo = num(c["lng"]) else { return nil }
            return BuoyCam(id: str(c["id"]), name: str(c["name"]), lat: la, lon: lo, img: img)
        }
    }
}

// MARK: - Buoy camera viewer

/// Six views around the buoy in one wide photo; swipe sideways.
struct BuoyCamView: View {
    let title: String
    let url: URL
    var page: URL? = nil
    var time: String = ""
    var height: CGFloat = 220
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: true) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFit().frame(height: height)
                    case .failure: Label("Camera image unavailable", systemImage: "video.slash").frame(width: 300, height: height)
                    default: ProgressView().frame(width: 300, height: height)
                    }
                }
            }
            .background(Color.black, in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            HStack {
                Text([title, time, "swipe for all 6 views"].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let page { Link("NDBC ↗", destination: page).font(.caption) }
            }
        }
    }
}

struct BuoyCamSheet: View, Identifiable {
    let id = UUID()
    let title: String
    let url: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                BuoyCamView(title: "", url: url, height: 300)
                Text("Live photos from NOAA buoy cameras, updated about every hour in daylight.").font(.footnote).foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .navigationTitle(title)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 440)
        #endif
    }
}

// MARK: - Live widgets

/// Rain in the next 3 hours, 15 minutes at a time.
struct NowcastWidget: View {
    let place: Place
    @State private var mm: [Double]?
    var body: some View {
        Group {
            if let mm, !mm.isEmpty {
                let firstWet = mm.firstIndex(where: { $0 >= 0.1 }), wetNow = (mm.first ?? 0) >= 0.1
                let lastWet: Int? = wetNow ? mm.firstIndex(where: { $0 < 0.1 }) : nil
                let msg = wetNow ? (lastWet.map { "Rain ending in about \($0 * 15) min" } ?? "Rain continuing for the next few hours")
                    : (firstWet.map { "Rain starting in about \($0 * 15) min" } ?? "No rain expected in the next 3 hours")
                let top = max(0.5, mm.max() ?? 0)
                VStack(alignment: .leading, spacing: 8) {
                    Text(msg).font(.headline)
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(mm.indices, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.gradient)
                                .frame(height: max(mm[i] > 0 ? 6 : 2, 70 * min(1, mm[i] / top)))
                        }
                    }
                    .frame(height: 70, alignment: .bottom)
                    HStack { Text("Now"); Spacer(); Text("+1h"); Spacer(); Text("+2h"); Spacer(); Text("+3h") }.font(.caption).foregroundStyle(.secondary)
                }
            } else if mm != nil {
                Text("Minute-by-minute rain data isn't available here.").foregroundStyle(.secondary)
            } else { ProgressView().frame(maxWidth: .infinity, minHeight: 80) }
        }
        .task(id: place.id) {
            let s = String(format: "https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f&minutely_15=precipitation&forecast_minutely_15=12&timezone=auto", place.lat, place.lon)
            let j = await LiveData.json(s) as? [String: Any]
            let m = (j?["minutely_15"] as? [String: Any])?["precipitation"] as? [Any] ?? []
            mm = m.map { LiveData.num($0) ?? 0 }
        }
    }
}

/// US AQI and pollutants.
struct AQIWidget: View {
    let place: Place
    @State private var cur: [String: Any]?
    @State private var done = false
    var body: some View {
        Group {
            if let c = cur, let aqi = LiveData.num(c["us_aqi"]) {
                let info = Self.info(aqi)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Text("\(Int(aqi))").font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(info.1)
                        VStack(alignment: .leading) { Text(info.0).font(.headline); Text("US AQI").font(.caption).foregroundStyle(.secondary) }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], alignment: .leading, spacing: 6) {
                        ForEach([("PM2.5", "pm2_5"), ("PM10", "pm10"), ("Ozone", "ozone"), ("NO₂", "nitrogen_dioxide"), ("SO₂", "sulphur_dioxide"), ("CO", "carbon_monoxide")], id: \.1) { k in
                            VStack(alignment: .leading) {
                                Text(k.0).font(.caption).foregroundStyle(.secondary)
                                Text(LiveData.num(c[k.1]).map { "\(Int($0.rounded())) µg/m³" } ?? "--").font(.callout.weight(.semibold))
                            }
                        }
                    }
                }
            } else if done { Text("Air quality unavailable.").foregroundStyle(.secondary) }
            else { ProgressView().frame(maxWidth: .infinity, minHeight: 80) }
        }
        .task(id: place.id) {
            let s = String(format: "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=%.4f&longitude=%.4f&current=us_aqi,pm2_5,pm10,ozone,nitrogen_dioxide,sulphur_dioxide,carbon_monoxide", place.lat, place.lon)
            cur = (await LiveData.json(s) as? [String: Any])?["current"] as? [String: Any]
            done = true
        }
    }
    static func info(_ v: Double) -> (String, Color) {
        v <= 50 ? ("Good", .green) : v <= 100 ? ("Moderate", .yellow) : v <= 150 ? ("Unhealthy for sensitive groups", .orange)
            : v <= 200 ? ("Unhealthy", .red) : v <= 300 ? ("Very unhealthy", .purple) : ("Hazardous", Color(red: 0.5, green: 0, blue: 0.1))
    }
}

/// The NWS forecast in words, period by period.
struct NWSTextWidget: View {
    let place: Place
    @State private var periods: [(String, String, String)]?
    var body: some View {
        Group {
            if let periods, !periods.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(periods.indices, id: \.self) { i in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack { Text(periods[i].0).bold(); Spacer(); Text(periods[i].1).foregroundStyle(.secondary) }
                                Text(periods[i].2).font(.callout)
                            }
                        }
                    }
                }
                .frame(maxHeight: 420)
            } else if periods != nil { Text("The NWS text forecast covers US locations only.").foregroundStyle(.secondary) }
            else { ProgressView().frame(maxWidth: .infinity, minHeight: 80) }
        }
        .task(id: place.id) {
            guard let pt = await LiveData.nwsPoint(place), let j = await LiveData.json(pt.forecast) as? [String: Any],
                  let ps = (j["properties"] as? [String: Any])?["periods"] as? [[String: Any]] else { periods = []; return }
            periods = ps.prefix(14).map { p in
                (LiveData.str(p["name"]), "\(LiveData.str(p["temperature"]))°\(LiveData.str(p["temperatureUnit"]))", LiveData.str(p["detailedForecast"]))
            }
        }
    }
}

/// The local NWS office's Area Forecast Discussion.
struct AFDWidget: View {
    let place: Place
    @State private var text: String?
    @State private var issued = ""
    var body: some View {
        Group {
            if let text, !text.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if !issued.isEmpty { Text("Issued \(issued)").font(.caption).foregroundStyle(.secondary) }
                    ScrollView { Text(text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 460)
                }
            } else if text != nil { Text("Forecast discussion unavailable (US only).").foregroundStyle(.secondary) }
            else { ProgressView().frame(maxWidth: .infinity, minHeight: 80) }
        }
        .task(id: place.id) {
            guard let pt = await LiveData.nwsPoint(place), !pt.cwa.isEmpty,
                  let list = await LiveData.json("https://api.weather.gov/products/types/AFD/locations/\(pt.cwa)") as? [String: Any],
                  let first = (list["@graph"] as? [[String: Any]])?.first,
                  let prod = await LiveData.json("https://api.weather.gov/products/\(LiveData.str(first["id"]))") as? [String: Any] else { text = ""; return }
            text = LiveData.str(prod["productText"])
            if let d = ISO8601DateFormatter().date(from: LiveData.str(prod["issuanceTime"])) { issued = d.formatted(date: .abbreviated, time: .shortened) }
        }
    }
}

/// Temperature forecast from six weather models side by side, like the website.
struct ModelsWidget: View {
    let place: Place
    let units: Units
    struct Pt: Identifiable { let id = UUID(); let model: String; let time: Date; let temp: Double }
    @State private var pts: [Pt]?
    @State private var rain: [(String, Double)] = []
    static let models = [("ncep_nbm_conus", "NBM (NWS blend)"), ("gfs_hrrr", "HRRR"), ("gfs_seamless", "GFS"),
                         ("ecmwf_ifs025", "ECMWF"), ("icon_seamless", "ICON (German)"), ("gem_seamless", "GEM (Canadian)")]
    var body: some View {
        Group {
            if let pts, !pts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Chart(pts) { p in
                        LineMark(x: .value("Time", p.time), y: .value("Temp", p.temp))
                            .foregroundStyle(by: .value("Model", p.model))
                            .interpolationMethod(.catmullRom)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartYAxisLabel { Text(units.tempSymbol) }
                    .frame(height: 240)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], alignment: .leading, spacing: 4) {
                        ForEach(rain, id: \.0) { r in
                            Text("\(r.0): \(units == .imperial ? String(format: "%.2f in", r.1) : String(format: "%.1f mm", r.1)) rain").font(.caption)
                        }
                    }
                    Text("When the lines agree, the forecast is more certain.").font(.caption).foregroundStyle(.secondary)
                }
            } else if pts != nil { Text("Model data unavailable.").foregroundStyle(.secondary) }
            else { ProgressView().frame(maxWidth: .infinity, minHeight: 120) }
        }
        .task(id: place.id) { await load() }
    }
    private func load() async {
        var s = String(format: "https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f&hourly=temperature_2m,precipitation&forecast_days=7&timeformat=unixtime&models=", place.lat, place.lon)
        s += Self.models.map(\.0).joined(separator: ",")
        if units == .imperial { s += "&temperature_unit=fahrenheit&precipitation_unit=inch" }
        guard let j = await LiveData.json(s) as? [String: Any], let h = j["hourly"] as? [String: Any],
              let times = h["time"] as? [Any] else { pts = []; return }
        var out: [Pt] = [], totals: [(String, Double)] = []
        for (key, name) in Self.models {
            let t = h["temperature_2m_\(key)"] as? [Any] ?? []
            var any = false
            for i in stride(from: 0, to: min(t.count, times.count), by: 3) {
                guard let v = LiveData.num(t[i]), let ts = LiveData.num(times[i]) else { continue }
                out.append(Pt(model: name, time: Date(timeIntervalSince1970: ts), temp: v)); any = true
            }
            if any { totals.append((name, (h["precipitation_\(key)"] as? [Any] ?? []).compactMap { LiveData.num($0) }.reduce(0, +))) }
        }
        pts = out; rain = totals
    }
}

/// The animated loop from the nearest NWS radar.
struct NWSLoopWidget: View {
    let place: Place
    @State private var station: String?
    var body: some View {
        Group {
            if let s = station, !s.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    RemoteImage(url: URL(string: "https://radar.weather.gov/ridge/standard/\(s)_loop.gif?t=\(Int(Date().timeIntervalSince1970 / 300))"))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Text("Radar site \(s)").font(.caption).foregroundStyle(.secondary)
                }
            } else if station != nil { Text("Local NWS radar loops cover US locations only.").foregroundStyle(.secondary) }
            else { ProgressView().frame(maxWidth: .infinity, minHeight: 120) }
        }
        .task(id: place.id) { station = await LiveData.nwsPoint(place)?.radar ?? "" }
    }
}

/// Active hurricanes and tropical storms from the National Hurricane Center.
struct StormsWidget: View {
    @State private var storms: [LiveData.Storm]?
    var body: some View {
        Group {
            if let storms, !storms.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(storms) { s in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "hurricane").font(.title2).foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(s.kind) \(s.name)").font(.headline)
                                Text("Winds \(s.mph) mph · \(s.pressure) mb").font(.callout)
                                if !s.movement.isEmpty { Text("Moving \(s.movement)").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    Link("National Hurricane Center ↗", destination: URL(string: "https://www.nhc.noaa.gov/")!).font(.callout)
                }
            } else if storms != nil { Label("No active tropical systems right now.", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
            else { ProgressView().frame(maxWidth: .infinity, minHeight: 80) }
        }
        .task { storms = await LiveData.storms() ?? [] }
    }
}

/// Spaghetti model plots for every active storm (Tropical Tidbits), like spaghettimodels.com.
struct SpaghettiWidget: View {
    @State private var storms: [LiveData.Storm]?
    var body: some View {
        Group {
            if let storms, !storms.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                    ForEach(storms) { s in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(s.name) (\(s.ttId))").font(.headline)
                            RemoteImage(url: URL(string: "https://www.tropicaltidbits.com/storminfo/\(s.ttId)_tracks_latest.png"))
                            RemoteImage(url: URL(string: "https://www.tropicaltidbits.com/storminfo/\(s.ttId)_gefs_latest.png"))
                        }
                    }
                }
            } else if storms != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Label("No active storms, so no spaghetti plots right now.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    ModelLinksWidget()
                }
            } else { ProgressView().frame(maxWidth: .infinity, minHeight: 80) }
        }
        .task { storms = await LiveData.storms() ?? [] }
    }
}

struct ModelLinksWidget: View {
    private let models = [("GFS", "gfs"), ("Euro", "ecmwf"), ("Canadian", "cmc"), ("ICON", "icon"), ("HRRR", "hrrr"), ("NAM 3km", "nam3km"), ("Euro AI", "ecmwf-aifs"), ("GEFS", "gfs-ens")]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], alignment: .leading, spacing: 8) {
                ForEach(models, id: \.1) { m in
                    Link(m.0, destination: URL(string: "https://www.tropicaltidbits.com/analysis/models/?model=\(m.1)")!).buttonStyle(.bordered)
                }
            }
            Link("Storm tracks & intensity ↗", destination: URL(string: "https://www.tropicaltidbits.com/storminfo/")!)
            Link("Pivotal Weather models ↗", destination: URL(string: "https://www.pivotalweather.com/model.php")!)
            Link("College of DuPage models ↗", destination: URL(string: "https://weather.cod.edu/forecast/")!)
        }
        .font(.callout)
    }
}

struct LinksWidget: View {
    let place: Place
    @State private var office: String?
    var body: some View {
        let links: [(String, String)] = (office.map { [("Your NWS Office", "https://www.weather.gov/\($0.lowercased())")] } ?? []) + [
            ("National Hurricane Center", "https://www.nhc.noaa.gov/"), ("Storm Prediction Center", "https://www.spc.noaa.gov/"),
            ("Weather Prediction Center", "https://www.wpc.ncep.noaa.gov/"), ("Tropical Tidbits (models, spaghetti)", "https://www.tropicaltidbits.com/"),
            ("Pivotal Weather (models)", "https://www.pivotalweather.com/"), ("College of DuPage Models", "https://weather.cod.edu/forecast/"),
            ("GOES Satellite Viewer", "https://www.star.nesdis.noaa.gov/GOES/"), ("Mike's Weather Page", "https://www.mikesweatherpage.com/"),
            ("Windy", "https://www.windy.com/"),
        ]
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], alignment: .leading, spacing: 6) {
            ForEach(links, id: \.1) { l in
                if let u = URL(string: l.1) {
                    Link(destination: u) { HStack { Text(l.0).lineLimit(1); Spacer(); Image(systemName: "arrow.up.right").font(.caption2) } }
                }
            }
        }
        .font(.footnote)
        .task(id: place.id) { if let c = await LiveData.nwsPoint(place)?.cwa, !c.isEmpty { office = c } }
    }
}

struct ScalesWidget: View {
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Saffir-Simpson (mph)").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach([("TD", "< 39", "#5ebaff"), ("TS", "39-73", "#00faf4"), ("Cat 1", "74-95", "#ffffcc"), ("Cat 2", "96-110", "#ffe775"),
                         ("Cat 3", "111-129", "#ffc140"), ("Cat 4", "130-156", "#ff8f20"), ("Cat 5", "157+", "#ff6060")], id: \.0) { r in
                    HStack { Circle().fill(Color(PColor.hex(r.2))).frame(width: 10, height: 10); Text(r.0).frame(width: 46, alignment: .leading); Text(r.1) }.font(.callout)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Enhanced Fujita (mph)").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach([("EF0", "65-85"), ("EF1", "86-110"), ("EF2", "111-135"), ("EF3", "136-165"), ("EF4", "166-200"), ("EF5", "200+")], id: \.0) { r in
                    HStack { Text(r.0).frame(width: 46, alignment: .leading); Text(r.1) }.font(.callout)
                }
            }
        }
    }
}

/// The live camera on the buoy nearest the selected place (like the website's marine card).
struct BuoyCamWidget: View {
    let place: Place
    @State private var cam: LiveData.BuoyCam?
    @State private var miles: Int = 0
    @State private var done = false
    var body: some View {
        Group {
            if let c = cam, let u = c.url {
                BuoyCamView(title: "\(c.name) · \(miles) mi", url: u, page: c.page, time: c.time)
            } else if done { Text("No buoy camera reporting within 300 miles.").foregroundStyle(.secondary) }
            else { ProgressView().frame(maxWidth: .infinity, minHeight: 120) }
        }
        .task(id: place.id) {
            let here = CLLocation(latitude: place.lat, longitude: place.lon)
            let best = await LiveData.buoyCams().map { ($0, here.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lon)) / 1609.34) }
                .min { $0.1 < $1.1 }
            if let b = best, b.1 < 300 { cam = b.0; miles = Int(b.1) }
            done = true
        }
    }
}
