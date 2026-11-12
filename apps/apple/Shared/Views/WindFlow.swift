import SwiftUI
import MapKit

// Animated wind: thousands of short streaks drifting with the wind, drawn over the radar map.
// Wind comes from Open-Meteo on a 9 x 9 grid over the area on screen (surface 10 m wind, or the
// 500 mb jet stream level) and is blended between grid points. Separate from the Winds value layer.

// MARK: - Settings

enum WindLevel: String, CaseIterable, Identifiable {
    case surface, jet
    var id: String { rawValue }
    var title: String { self == .surface ? "Surface Winds" : "Jet Stream (500 mb)" }
    /// Speed that gets the top color.
    var maxMph: Double { self == .surface ? 50 : 140 }
    /// Screen points per second for each mph.
    var pace: Double { self == .surface ? 0.9 : 0.4 }
}

enum WindScheme: String, CaseIterable, Identifiable {
    case noaa, greenRed, blueRed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .noaa: return "Spectrum"
        case .greenRed: return "Green Red"
        case .blueRed: return "Blue Red"
        }
    }
    /// Color stops from calm (0) to the level's top speed (1).
    private var stops: [(Double, (Double, Double, Double))] {
        switch self {
        case .noaa: return [(0, (0.30, 0.45, 0.98)), (0.25, (0.10, 0.85, 0.92)), (0.45, (0.25, 0.88, 0.45)),
                            (0.65, (0.98, 0.86, 0.22)), (0.82, (0.96, 0.38, 0.26)), (1, (0.88, 0.32, 0.90))]
        case .greenRed: return [(0, (0.55, 0.55, 0.55)), (0.3, (0.22, 0.80, 0.25)), (0.65, (0.92, 0.82, 0.15)), (1, (0.92, 0.22, 0.20))]
        case .blueRed: return [(0, (0.38, 0.42, 0.95)), (0.4, (0.35, 0.85, 0.30)), (0.7, (0.95, 0.85, 0.20)), (1, (0.92, 0.22, 0.20))]
        }
    }
    func color(_ f: Double) -> Color {
        let x = min(1, max(0, f))
        let s = stops
        guard let i = s.lastIndex(where: { $0.0 <= x }) else { return .white }
        if i == s.count - 1 { let c = s[i].1; return Color(red: c.0, green: c.1, blue: c.2) }
        let (a, ca) = s[i], (b, cb) = s[i + 1]
        let t = (x - a) / max(0.0001, b - a)
        return Color(red: ca.0 + (cb.0 - ca.0) * t, green: ca.1 + (cb.1 - ca.1) * t, blue: ca.2 + (cb.2 - ca.2) * t)
    }
}

// MARK: - What the map is showing (set by the map, read every animation frame)

/// The map's visible area and size. `rect` and `size` change constantly while panning and are read
/// directly each frame; `settled` bumps when the map stops moving, which is when new wind is fetched.
final class MapViewport: ObservableObject {
    var rect = MKMapRect.null
    var size = CGSize.zero
    @Published var settled = 0
}

// MARK: - Wind grid

struct WindField {
    let lat0: Double, lat1: Double, lon0: Double, lon1: Double
    let n: Int
    let u: [Double], v: [Double]   // mph, east and north
    let level: WindLevel
    let fetched: Date

    func contains(_ c: CLLocationCoordinate2D) -> Bool { c.latitude >= lat0 && c.latitude <= lat1 && c.longitude >= lon0 && c.longitude <= lon1 }

    /// Wind at a point, blended from the four nearest grid points.
    func sample(_ c: CLLocationCoordinate2D) -> (u: Double, v: Double)? {
        guard contains(c), n > 1 else { return nil }
        let fx = (c.longitude - lon0) / (lon1 - lon0) * Double(n - 1)
        let fy = (c.latitude - lat0) / (lat1 - lat0) * Double(n - 1)
        let x0 = min(n - 2, max(0, Int(fx))), y0 = min(n - 2, max(0, Int(fy)))
        let tx = fx - Double(x0), ty = fy - Double(y0)
        func at(_ x: Int, _ y: Int) -> Int { y * n + x }
        func mix(_ a: [Double]) -> Double {
            let top = a[at(x0, y0)] * (1 - tx) + a[at(x0 + 1, y0)] * tx
            let bot = a[at(x0, y0 + 1)] * (1 - tx) + a[at(x0 + 1, y0 + 1)] * tx
            return top * (1 - ty) + bot * ty
        }
        return (mix(u), mix(v))
    }

    /// Fetch a 9 x 9 grid covering `rect` plus a margin.
    static func fetch(_ rect: MKMapRect, level: WindLevel) async -> WindField? {
        let nw = MKMapPoint(x: rect.minX, y: rect.minY).coordinate, se = MKMapPoint(x: rect.maxX, y: rect.maxY).coordinate
        var lat0 = se.latitude, lat1 = nw.latitude, lon0 = nw.longitude, lon1 = se.longitude
        if rect.width >= MKMapRect.world.width * 0.95 || lon1 <= lon0 { lon0 = -180; lon1 = 180 }
        let padLat = (lat1 - lat0) * 0.2, padLon = (lon1 - lon0) * 0.2
        lat0 = max(-80, lat0 - padLat); lat1 = min(80, lat1 + padLat)
        lon0 = max(-180, lon0 - padLon); lon1 = min(180, lon1 + padLon)
        guard lat1 > lat0, lon1 > lon0 else { return nil }

        let n = 9
        var lats: [String] = [], lons: [String] = []
        for y in 0..<n {
            for x in 0..<n {
                lats.append(String(format: "%.2f", lat0 + (lat1 - lat0) * Double(y) / Double(n - 1)))
                lons.append(String(format: "%.2f", lon0 + (lon1 - lon0) * Double(x) / Double(n - 1)))
            }
        }
        let vars = level == .surface ? "current=wind_speed_10m,wind_direction_10m"
                                     : "hourly=wind_speed_500hPa,wind_direction_500hPa&forecast_hours=1"
        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lats.joined(separator: ","))&longitude=\(lons.joined(separator: ","))&\(vars)&wind_speed_unit=mph&timezone=GMT"),
              let data = try? await URLSession.shared.data(from: url).0,
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], list.count == n * n else { return nil }

        var u: [Double] = [], v: [Double] = []
        for item in list {
            var speed = 0.0, dir = 0.0
            if level == .surface, let c = item["current"] as? [String: Any] {
                speed = (c["wind_speed_10m"] as? NSNumber)?.doubleValue ?? 0
                dir = (c["wind_direction_10m"] as? NSNumber)?.doubleValue ?? 0
            } else if let h = item["hourly"] as? [String: Any] {
                speed = ((h["wind_speed_500hPa"] as? [Any])?.first as? NSNumber)?.doubleValue ?? 0
                dir = ((h["wind_direction_500hPa"] as? [Any])?.first as? NSNumber)?.doubleValue ?? 0
            }
            // direction is where the wind comes FROM; turn it into where it's going
            let r = dir * .pi / 180
            u.append(-speed * sin(r)); v.append(-speed * cos(r))
        }
        return WindField(lat0: lat0, lat1: lat1, lon0: lon0, lon1: lon1, n: n, u: u, v: v, level: level, fetched: .now)
    }
}

// MARK: - Particles

private final class WindParticles {
    struct P { var trail: [MKMapPoint]; var age: Double; var life: Double; var speed: Double }
    var ps: [P] = []
    var last: Date?

    private func spawn(in r: MKMapRect) -> P {
        let p = MKMapPoint(x: r.minX + Double.random(in: 0...1) * r.width, y: r.minY + Double.random(in: 0...1) * r.height)
        return P(trail: [p], age: 0, life: Double.random(in: 1.5...4), speed: 0)
    }

    func step(_ now: Date, rect: MKMapRect, size: CGSize, field: WindField) {
        let dt = min(0.1, now.timeIntervalSince(last ?? now))
        last = now
        guard rect.width > 0, size.width > 0 else { return }
        let target = Int(min(1400, max(250, size.width * size.height / 650)))
        if ps.count < target { for _ in 0..<(target - ps.count) { ps.append(spawn(in: rect)) } }
        if ps.count > target { ps.removeLast(ps.count - target) }

        let perPoint = rect.width / size.width   // map points per screen point
        for i in ps.indices {
            var p = ps[i]
            p.age += dt
            guard let head = p.trail.last, p.age < p.life, rect.contains(head),
                  let w = field.sample(head.coordinate) else { ps[i] = spawn(in: rect); continue }
            p.speed = (w.u * w.u + w.v * w.v).squareRoot()
            let k = field.level.pace * dt * perPoint
            p.trail.append(MKMapPoint(x: head.x + w.u * k, y: head.y - w.v * k))
            if p.trail.count > 8 { p.trail.removeFirst(p.trail.count - 8) }
            ps[i] = p
        }
    }

    /// Streaks grouped into a few color bands so each frame is a handful of strokes.
    func draw(_ ctx: GraphicsContext, rect: MKMapRect, size: CGSize, level: WindLevel, scheme: WindScheme) {
        guard rect.width > 0 else { return }
        let sx = size.width / rect.width, sy = size.height / rect.height
        let bands = 10
        var paths = Array(repeating: Path(), count: bands)
        for p in ps where p.trail.count > 1 {
            let b = min(bands - 1, Int(p.speed / level.maxMph * Double(bands)))
            for (j, m) in p.trail.enumerated() {
                let pt = CGPoint(x: (m.x - rect.minX) * sx, y: (m.y - rect.minY) * sy)
                if j == 0 { paths[b].move(to: pt) } else { paths[b].addLine(to: pt) }
            }
        }
        for b in 0..<bands where !paths[b].isEmpty {
            ctx.stroke(paths[b], with: .color(scheme.color((Double(b) + 0.5) / Double(bands))),
                       style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - The overlay

/// Drawn over the map; touches pass straight through to it.
struct WindFlowView: View {
    @ObservedObject var viewport: MapViewport
    @AppStorage("windLevel") private var levelRaw = WindLevel.surface.rawValue
    @AppStorage("windScheme") private var schemeRaw = WindScheme.noaa.rawValue
    @AppStorage("windOpacity") private var opacity = 0.8
    @State private var field: WindField?
    @State private var particles = WindParticles()

    private var level: WindLevel { WindLevel(rawValue: levelRaw) ?? .surface }
    private var scheme: WindScheme { WindScheme(rawValue: schemeRaw) ?? .noaa }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
            Canvas { ctx, size in
                guard let f = field, f.level == level else { return }
                particles.step(tl.date, rect: viewport.rect, size: size, field: f)
                particles.draw(ctx, rect: viewport.rect, size: size, level: level, scheme: scheme)
            }
        }
        .opacity(opacity)
        .allowsHitTesting(false)
        .task(id: "\(viewport.settled)-\(levelRaw)") { await refresh() }
    }

    /// New wind when the map settles somewhere the current grid doesn't cover, the level changes,
    /// or the data is more than 15 minutes old.
    private func refresh() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
        let r = viewport.rect
        guard r.width > 0, !Task.isCancelled else { return }
        let nw = MKMapPoint(x: r.minX, y: r.minY).coordinate, se = MKMapPoint(x: r.maxX, y: r.maxY).coordinate
        if let f = field, f.level == level, Date().timeIntervalSince(f.fetched) < 15 * 60,
           f.contains(nw), f.contains(se), (f.lat1 - f.lat0) < (nw.latitude - se.latitude) * 3 { return }
        if let f = await WindField.fetch(r, level: level), !Task.isCancelled {
            field = f
            particles.ps.removeAll()
        }
    }
}

// MARK: - Settings page (Layers > Overlays > Wind Animation)

struct WindSettingsPage: View {
    @AppStorage("windLevel") private var levelRaw = WindLevel.surface.rawValue
    @AppStorage("windScheme") private var schemeRaw = WindScheme.noaa.rawValue
    @AppStorage("windOpacity") private var opacity = 0.8

    var body: some View {
        KitPage(title: "Wind Animation") {
            KitPills(options: WindLevel.allCases.map { (value: $0.rawValue, title: $0.title) }, selection: $levelRaw)
                .padding(.horizontal, 16).padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(Kit.row)

            HStack(spacing: 12) {
                Text("Opacity")
                Spacer(minLength: 20)
                Image(systemName: "circle").foregroundStyle(.secondary)
                Slider(value: $opacity, in: 0.2...1).tint(Kit.purple).frame(maxWidth: 220)
                Image(systemName: "circle.fill").foregroundStyle(.secondary)
            }
            .kitRow()

            HStack(alignment: .top, spacing: 14) {
                ForEach(WindScheme.allCases) { s in
                    Button { schemeRaw = s.rawValue } label: {
                        VStack(spacing: 8) {
                            WindSwatch(scheme: s)
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(schemeRaw == s.rawValue ? Kit.purple : .clear, lineWidth: 3))
                            Text(s.title).font(.headline)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(16)
            .background(Kit.row)

            KitFooter(text: "Surface winds are about 30 feet above the ground. The jet stream level (500 mb) is about 18,000 feet up and steers storms. Updates every 15 minutes from Open-Meteo.")
        }
    }
}

/// A swirl of streaks in a scheme's colors, for picking a color scheme.
struct WindSwatch: View {
    let scheme: WindScheme
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.22)))
            let c = CGPoint(x: size.width * 0.42, y: size.height * 0.5)
            var seed: UInt64 = 7
            func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
            for _ in 0..<260 {
                let r = 6 + rnd() * Double(size.width) * 0.75
                let a = rnd() * .pi * 2
                let sweep = 0.18 + rnd() * 0.12
                let speed = min(1, r / Double(size.width) * 1.3 + rnd() * 0.15)
                var p = Path()
                p.addArc(center: c, radius: r, startAngle: .radians(a), endAngle: .radians(a + sweep), clockwise: false)
                ctx.stroke(p, with: .color(scheme.color(speed).opacity(0.9)), lineWidth: 1.6)
            }
        }
    }
}
