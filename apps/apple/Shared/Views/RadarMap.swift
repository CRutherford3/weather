import SwiftUI
import MapKit

/// Map layers the app can draw. Mirrors the website's layer names.
enum MapLayer: String, CaseIterable, Identifiable {
    case radar, satellite, warnings, lightning
    var id: String { rawValue }
    var title: String {
        switch self {
        case .radar: return "Radar"
        case .satellite: return "Satellite (Infrared)"
        case .warnings: return "Warnings & Watches"
        case .lightning: return "Lightning"
        }
    }
    var tier: Plan { self == .lightning ? .plus : .free }
}

/// Plays the radar loop over Apple Maps. Shared by iPhone, iPad and Mac.
final class RadarController: ObservableObject {
    @Published var frames: [RadarService.Frame] = []
    @Published var index = 0
    @Published var playing = true
    @Published var layers: Set<MapLayer> = [.radar, .warnings]
    @Published var opacity: Double = 0.75
    private var timer: Timer?

    func load() async {
        let f = await RadarService.frames()
        await MainActor.run { self.frames = f; self.index = max(0, f.count - 1); self.startTimer() }
    }

    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self, self.playing, !self.frames.isEmpty else { return }
            // pause briefly on the latest frame
            if self.index == self.frames.count - 1 && Int(Date().timeIntervalSince1970 * 2) % 4 != 0 { return }
            self.index = (self.index + 1) % self.frames.count
        }
    }

    var currentTime: Date? { frames.indices.contains(index) ? frames[index].time : nil }
}

#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
#else
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

struct RadarMap: PlatformViewRepresentable {
    @ObservedObject var radar: RadarController
    var center: CLLocationCoordinate2D
    var recenterToken: Int            // change to fly back to `center`
    var onCenterChange: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    #if os(macOS)
    func makeNSView(context: Context) -> MKMapView { make(context) }
    func updateNSView(_ v: MKMapView, context: Context) { update(v, context) }
    #else
    func makeUIView(context: Context) -> MKMapView { make(context) }
    func updateUIView(_ v: MKMapView, context: Context) { update(v, context) }
    #endif

    private func make(_ context: Context) -> MKMapView {
        let m = MKMapView()
        m.delegate = context.coordinator
        m.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        m.showsUserLocation = true
        m.setRegion(MKCoordinateRegion(center: center, span: .init(latitudeDelta: 6, longitudeDelta: 6)), animated: false)
        context.coordinator.map = m
        return m
    }

    private func update(_ m: MKMapView, _ context: Context) {
        let c = context.coordinator
        c.parent = self
        if c.lastRecenter != recenterToken {
            c.lastRecenter = recenterToken
            m.setCenter(center, animated: true)
        }
        c.syncOverlays()
        c.showFrame(radar.index)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: RadarMap
        weak var map: MKMapView?
        var lastRecenter = 0
        private var frameOverlays: [Int: MKTileOverlay] = [:]
        private var frameRenderers: [ObjectIdentifier: MKTileOverlayRenderer] = [:]
        private var frameKey = ""
        private var satOverlay: MKTileOverlay?
        private var warnOverlays: [MKOverlay] = []
        private var warnLoaded = false
        private var strikes: [MKPointAnnotation] = []
        private var strikesTimer: Timer?

        init(_ p: RadarMap) { parent = p }

        // MARK: layers
        func syncOverlays() {
            guard let map else { return }
            let L = parent.radar.layers
            // radar frames (rebuilt when the frame list changes)
            let key = parent.radar.frames.map(\.template).joined()
            if key != frameKey || !L.contains(.radar) {
                frameOverlays.values.forEach { map.removeOverlay($0) }
                frameOverlays = [:]; frameRenderers = [:]; frameKey = ""
                if L.contains(.radar) {
                    frameKey = key
                    for f in parent.radar.frames {
                        let o = MKTileOverlay(urlTemplate: f.template)
                        o.canReplaceMapContent = false
                        o.maximumZ = 12
                        frameOverlays[f.id] = o
                        map.addOverlay(o, level: .aboveRoads)
                    }
                }
            }
            // infrared satellite
            if L.contains(.satellite), satOverlay == nil {
                let o = MKTileOverlay(urlTemplate: "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/goes_east_conus_ch13/{z}/{x}/{y}.png")
                o.maximumZ = 9
                satOverlay = o
                map.insertOverlay(o, at: 0, level: .aboveRoads)
            } else if !L.contains(.satellite), let o = satOverlay {
                map.removeOverlay(o); satOverlay = nil
            }
            // warnings (GeoJSON polygons from NWS)
            if L.contains(.warnings), !warnLoaded {
                warnLoaded = true
                Task { await loadWarnings() }
            } else if !L.contains(.warnings), warnLoaded {
                map.removeOverlays(warnOverlays); warnOverlays = []; warnLoaded = false
            }
            // lightning strikes (website API, last 30 minutes)
            if L.contains(.lightning), strikesTimer == nil {
                Task { await loadStrikes() }
                strikesTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { await self?.loadStrikes() } }
            } else if !L.contains(.lightning), let t = strikesTimer {
                t.invalidate(); strikesTimer = nil; map.removeAnnotations(strikes); strikes = []
            }
        }

        func showFrame(_ i: Int) {
            for (idx, o) in frameOverlays {
                guard let r = frameRenderers[ObjectIdentifier(o)] else { continue }
                let a: CGFloat = idx == i ? CGFloat(parent.radar.opacity) : 0
                if r.alpha != a { r.alpha = a; r.setNeedsDisplay() }
            }
        }

        @MainActor private func loadWarnings() async {
            var req = URLRequest(url: URL(string: "https://api.weather.gov/alerts/active?status=actual&message_type=alert,update")!)
            req.setValue(AppConfig.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("application/geo+json", forHTTPHeaderField: "Accept")
            guard let data = try? await URLSession.shared.data(for: req).0,
                  let objs = try? MKGeoJSONDecoder().decode(data) else { return }
            var out: [MKOverlay] = []
            for case let f as MKGeoJSONFeature in objs {
                let event = (try? JSONSerialization.jsonObject(with: f.properties ?? Data()) as? [String: Any])?["event"] as? String ?? ""
                for g in f.geometry {
                    if let poly = g as? MKPolygon { poly.title = event; out.append(poly) }
                    if let multi = g as? MKMultiPolygon { multi.title = event; out.append(multi) }
                }
            }
            guard let map, parent.radar.layers.contains(.warnings) else { return }
            map.removeOverlays(warnOverlays)
            warnOverlays = out
            map.addOverlays(out, level: .aboveLabels)
        }

        @MainActor private func loadStrikes() async {
            struct R: Decodable { let f: [[Double]] }
            guard let url = URL(string: "/api/lightning", relativeTo: AppConfig.webBase),
                  let data = try? await URLSession.shared.data(from: url).0,
                  let r = try? JSONDecoder().decode(R.self, from: data), let map else { return }
            map.removeAnnotations(strikes)
            let now = Date().timeIntervalSince1970 * 1000
            strikes = r.f.prefix(3000).compactMap { a in
                guard a.count >= 3 else { return nil }
                let p = MKPointAnnotation()
                p.coordinate = .init(latitude: a[1], longitude: a[0])
                p.title = "strike"
                p.subtitle = String(Int((now - a[2]) / 60000)) // minutes old
                return p
            }
            map.addAnnotations(strikes)
        }

        // MARK: delegate
        func mapView(_ m: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let t = overlay as? MKTileOverlay {
                let r = MKTileOverlayRenderer(tileOverlay: t)
                if t === satOverlay { r.alpha = 0.6 } else { r.alpha = 0; frameRenderers[ObjectIdentifier(t)] = r }
                return r
            }
            let color = Self.alertColor((overlay as? MKShape)?.title ?? "")
            if let p = overlay as? MKPolygon {
                let r = MKPolygonRenderer(polygon: p); r.strokeColor = color; r.lineWidth = 1.5; r.fillColor = color.withAlphaComponent(0.12); return r
            }
            if let p = overlay as? MKMultiPolygon {
                let r = MKMultiPolygonRenderer(multiPolygon: p); r.strokeColor = color; r.lineWidth = 1.5; r.fillColor = color.withAlphaComponent(0.12); return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ m: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard (annotation.title ?? nil) == "strike" else { return nil }
            let v = m.dequeueReusableAnnotationView(withIdentifier: "strike") ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "strike")
            v.annotation = annotation
            let age = Int((annotation.subtitle ?? nil) ?? "0") ?? 0
            #if os(macOS)
            let cfg = NSImage.SymbolConfiguration(pointSize: age < 5 ? 14 : 7, weight: .bold)
            v.image = NSImage(systemSymbolName: age < 5 ? "bolt.fill" : "circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            #else
            let cfg = UIImage.SymbolConfiguration(pointSize: age < 5 ? 14 : 6, weight: .bold)
            v.image = UIImage(systemName: age < 5 ? "bolt.fill" : "circle.fill", withConfiguration: cfg)?
                .withTintColor(age < 5 ? .systemYellow : (age < 15 ? .systemOrange : .systemRed), renderingMode: .alwaysOriginal)
            #endif
            v.canShowCallout = false
            return v
        }

        func mapView(_ m: MKMapView, regionDidChangeAnimated animated: Bool) {
            parent.onCenterChange(m.centerCoordinate)
        }

        #if os(macOS)
        static func alertColor(_ e: String) -> NSColor { e.contains("Tornado") ? .systemRed : e.contains("Thunderstorm") ? .systemYellow : e.contains("Flood") ? .systemGreen : e.contains("Hurricane") || e.contains("Tropical") ? .systemPink : e.contains("Winter") || e.contains("Snow") || e.contains("Ice") ? .systemCyan : .systemOrange }
        #else
        static func alertColor(_ e: String) -> UIColor { e.contains("Tornado") ? .systemRed : e.contains("Thunderstorm") ? .systemYellow : e.contains("Flood") ? .systemGreen : e.contains("Hurricane") || e.contains("Tropical") ? .systemPink : e.contains("Winter") || e.contains("Snow") || e.contains("Ice") ? .systemCyan : .systemOrange }
        #endif
    }
}

/// The crosshair in the middle of the map.
struct Crosshair: View {
    var body: some View {
        ZStack {
            Rectangle().frame(width: 2, height: 26)
            Rectangle().frame(width: 26, height: 2)
            Circle().fill(.background).frame(width: 8, height: 8)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 2)
        .allowsHitTesting(false)
    }
}
