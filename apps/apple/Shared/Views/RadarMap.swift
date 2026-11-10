import SwiftUI
import MapKit
import ImageIO

#if os(macOS)
typealias PColor = NSColor
#else
typealias PColor = UIColor
#endif

extension PColor {
    /// "#rrggbb" or "rrggbb". Falls back to gray.
    static func hex(_ s: String?) -> PColor {
        var h = (s ?? "").trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return .gray }
        return PColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}

// MARK: - Layers

/// Sections in the Layers sheet. Same groups as the website.
enum LayerGroup: String, CaseIterable, Identifiable {
    case radarSat = "Radar & Satellite", severe = "Severe Weather", tropics = "Tropics", snow = "Snow & Ice", marine = "Marine", more = "More"
    var id: String { rawValue }
}

/// A map tile source. `{z}/{x}/{y}` templates are normal map tiles; `{bbox}` templates are
/// WMS / ArcGIS image exports that work at any zoom.
struct TileSource {
    var template: String
    var nativeMaxZ: Int
    var opacity: Double
    var above: Bool = false   // draw above radar (outlines) instead of under it (backgrounds)
    var bbox: Bool { template.contains("{bbox}") }
}

/// Map layers the app can draw. Mirrors the website's layer list and plan levels.
enum MapLayer: String, CaseIterable, Identifiable {
    case radar, satIR, satVis, satWV, satColor, lightning, rain
    case warnings, spc, mcd, lsr
    case twoutlook, windprob
    case snowdepth, snowprob
    case sst, charts
    case drought, quakes, fires

    var id: String { rawValue }

    var title: String {
        switch self {
        case .radar: return "Hi-Def Radar"
        case .satIR: return "Satellite: Infrared"
        case .satVis: return "Satellite: Visible"
        case .satWV: return "Satellite: Water Vapor"
        case .satColor: return "Satellite: True Color"
        case .lightning: return "Lightning"
        case .rain: return "Rain Totals (24 hr)"
        case .warnings: return "Warnings & Watches"
        case .spc: return "SPC Severe Outlook"
        case .mcd: return "Mesoscale Discussions"
        case .lsr: return "Storm Reports (24 hr)"
        case .twoutlook: return "Tropical Development Areas"
        case .windprob: return "Tropical Storm Wind Chances"
        case .snowdepth: return "Snow Depth Now"
        case .snowprob: return "Snow Chances (4 in+, Day 1)"
        case .sst: return "Sea Surface Temperature"
        case .charts: return "Nautical Charts (NOAA)"
        case .drought: return "Droughts"
        case .quakes: return "Earthquakes"
        case .fires: return "Wildfires"
        }
    }

    var group: LayerGroup {
        switch self {
        case .radar, .satIR, .satVis, .satWV, .satColor, .lightning, .rain: return .radarSat
        case .warnings, .spc, .mcd, .lsr: return .severe
        case .twoutlook, .windprob: return .tropics
        case .snowdepth, .snowprob: return .snow
        case .sst, .charts: return .marine
        case .drought, .quakes, .fires: return .more
        }
    }

    var tier: Plan {
        switch self {
        case .lightning, .rain, .twoutlook, .windprob, .snowprob, .drought: return .plus
        case .sst, .charts: return .pro
        default: return .free
        }
    }

    /// Only one satellite view at a time.
    var isSatellite: Bool { [.satIR, .satVis, .satWV, .satColor].contains(self) }

    /// Tile layers. Time-based URLs get a cache-busting stamp so they refresh.
    var tiles: TileSource? {
        let iem = "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0"
        let ms = "https://mapservices.weather.noaa.gov"
        let now = Date().timeIntervalSince1970
        let b5 = Int(now / 300), b10 = Int(now / 600), b30 = Int(now / 1800), b2h = Int(now / 7200), b3h = Int(now / 10800)
        func ags(_ svc: String, _ layers: String, _ bust: Int) -> String {
            "\(ms)/\(svc)/export?bbox={bbox}&bboxSR=3857&imageSR=3857&size=256,256&format=png32&transparent=true&layers=show:\(layers)&f=image&_=\(bust)"
        }
        switch self {
        case .satIR: return TileSource(template: "\(iem)/goes_east_conus_ch13/{z}/{x}/{y}.png?_=\(b5)", nativeMaxZ: 9, opacity: 0.7)
        case .satVis: return TileSource(template: "\(iem)/goes_east_conus_ch02/{z}/{x}/{y}.png?_=\(b5)", nativeMaxZ: 9, opacity: 0.7)
        case .satWV: return TileSource(template: "\(iem)/goes_east_conus_ch09/{z}/{x}/{y}.png?_=\(b5)", nativeMaxZ: 9, opacity: 0.7)
        case .satColor:
            // NASA GIBS GeoColor runs about an hour behind; ask for 90 minutes ago, on a 10 minute step.
            let t = Date(timeIntervalSince1970: ((now - 5400) / 600).rounded(.down) * 600)
            let ts = ISO8601DateFormatter().string(from: t)
            return TileSource(template: "https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/GOES-East_ABI_GeoColor/default/\(ts)/GoogleMapsCompatible_Level7/{z}/{y}/{x}.jpg", nativeMaxZ: 7, opacity: 0.85)
        case .lightning:
            return TileSource(template: "https://nowcoast.noaa.gov/geoserver/observations/lightning_detection/ows?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetMap&LAYERS=ldn_lightning_strike_density&STYLES=&FORMAT=image/png&TRANSPARENT=true&CRS=EPSG:3857&WIDTH=256&HEIGHT=256&BBOX={bbox}&_=\(b5)", nativeMaxZ: 20, opacity: 0.55, above: true)
        case .rain: return TileSource(template: "\(iem)/q2-p24h-900913/{z}/{x}/{y}.png?_=\(b10)", nativeMaxZ: 10, opacity: 0.7)
        case .twoutlook: return TileSource(template: ags("tropical/rest/services/tropical/NHC_tropical_weather_summary/MapServer", "1,2,3,33", b30), nativeMaxZ: 20, opacity: 0.85, above: true)
        case .windprob: return TileSource(template: ags("tropical/rest/services/tropical/NHC_tropical_weather_summary/MapServer", "30,18", b30), nativeMaxZ: 20, opacity: 0.7, above: true)
        case .snowdepth: return TileSource(template: ags("raster/rest/services/snow/NOHRSC_Snow_Analysis/MapServer", "0", b3h), nativeMaxZ: 20, opacity: 0.7)
        case .snowprob: return TileSource(template: ags("vector/rest/services/precip/wpc_prob_winter_precip/MapServer", "1", b2h), nativeMaxZ: 20, opacity: 0.7)
        case .sst: return TileSource(template: "https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/GHRSST_L4_MUR_Sea_Surface_Temperature/default/default/GoogleMapsCompatible_Level7/{z}/{y}/{x}.png?_=\(Int(now / 21600))", nativeMaxZ: 7, opacity: 0.75)
        case .charts: return TileSource(template: "https://gis.charttools.noaa.gov/arcgis/rest/services/MCS/NOAAChartDisplay/MapServer/exts/MaritimeChartService/MapServer/export?bbox={bbox}&bboxSR=3857&imageSR=3857&size=256,256&format=png&transparent=true&f=image", nativeMaxZ: 20, opacity: 1)
        default: return nil
        }
    }

    /// GeoJSON layers (shapes and points).
    var geojson: URL? {
        switch self {
        case .warnings: return URL(string: "https://api.weather.gov/alerts/active?status=actual&message_type=alert,update")
        case .spc: return URL(string: "https://www.spc.noaa.gov/products/outlook/day1otlk_cat.lyr.geojson")
        case .mcd: return URL(string: "https://mesonet.agron.iastate.edu/api/1/nws/spc_mcd.geojson")
        case .lsr: return URL(string: "https://mesonet.agron.iastate.edu/geojson/lsr.geojson?hours=24")
        case .drought: return URL(string: "https://services5.arcgis.com/0OTVzJS4K09zlixn/arcgis/rest/services/USDM_current/FeatureServer/0/query?where=1%3D1&outFields=dm&maxAllowableOffset=0.05&geometryPrecision=3&f=geojson")
        case .quakes: return URL(string: "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/2.5_day.geojson")
        case .fires: return URL(string: "https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/WFIGS_Incident_Locations_Current/FeatureServer/0/query?where=IncidentSize%3E%3D100&outFields=IncidentName,IncidentSize,PercentContained&f=geojson")
        default: return nil
        }
    }
}

// MARK: - Tile overlay that loads its own tiles

/// Ties the radar loop's frames together. A tile MapKit asks for in one frame is downloaded for
/// every frame at once, so the loop never waits on the network, and the loop can ask whether a
/// frame has finished loading before showing it.
final class RadarFrameGroup: @unchecked Sendable {
    private let lock = NSLock()
    private var overlays: [WxTileOverlay] = []
    private var pending: [Int: Int] = [:]   // frame index -> tiles still downloading

    func set(_ o: [WxTileOverlay]) { lock.lock(); overlays = o; pending = [:]; lock.unlock() }
    func prefetch(_ path: MKTileOverlayPath, from src: WxTileOverlay) {
        lock.lock(); let others = overlays.filter { $0 !== src }; lock.unlock()
        for o in others { o.warm(path) }
    }
    func began(_ f: Int) { lock.lock(); pending[f, default: 0] += 1; lock.unlock() }
    func ended(_ f: Int) { lock.lock(); pending[f] = max(0, (pending[f] ?? 1) - 1); lock.unlock() }
    func isReady(_ f: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return (pending[f] ?? 0) == 0 }
}

/// One download per tile URL, even when several frames or zoom levels ask for it at the same time.
final class TileInflight: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [NSString: [(Data?) -> Void]] = [:]
    /// Returns true if the caller should start the download.
    func join(_ key: NSString, _ cb: @escaping (Data?) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if waiting[key] != nil { waiting[key]?.append(cb); return false }
        waiting[key] = [cb]; return true
    }
    func finish(_ key: NSString, _ data: Data?) {
        lock.lock(); let cbs = waiting.removeValue(forKey: key) ?? []; lock.unlock()
        cbs.forEach { $0(data) }
    }
}

/// Loads tiles itself so it can send the app's User-Agent, cache them, and "overzoom":
/// past a source's highest zoom it crops and enlarges the parent tile instead of going blank.
final class WxTileOverlay: MKTileOverlay {
    let template: String
    let nativeMaxZ: Int
    let usesBBox: Bool
    /// Radar loop membership (nil for ordinary layers).
    weak var group: RadarFrameGroup?
    var frame = -1

    static let inflight = TileInflight()
    static let cache: NSCache<NSString, NSData> = { let c = NSCache<NSString, NSData>(); c.totalCostLimit = 80 << 20; return c }()
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpAdditionalHeaders = ["User-Agent": AppConfig.userAgent]
        c.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 200 << 20)
        c.requestCachePolicy = .returnCacheDataElseLoad
        c.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: c)
    }()

    init(_ src: TileSource) {
        template = src.template
        nativeMaxZ = src.nativeMaxZ
        usesBBox = src.bbox
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        minimumZ = 1
        maximumZ = 20
    }

    private func url(z: Int, x: Int, y: Int) -> URL? {
        var s = template
        if usesBBox {
            let half = 20037508.342789244
            let size = 2 * half / pow(2, Double(z))
            let minX = -half + Double(x) * size, maxY = half - Double(y) * size
            s = s.replacingOccurrences(of: "{bbox}", with: String(format: "%.2f,%.2f,%.2f,%.2f", minX, maxY - size, minX + size, maxY))
        } else {
            s = s.replacingOccurrences(of: "{z}", with: String(z))
                .replacingOccurrences(of: "{x}", with: String(x))
                .replacingOccurrences(of: "{y}", with: String(y))
        }
        return URL(string: s)
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        group?.prefetch(path, from: self)
        tile(path) { result($0, nil) }
    }

    /// Download a tile into the cache without drawing it (used to preload other radar frames).
    func warm(_ path: MKTileOverlayPath) { tile(path) { _ in } }

    private func tile(_ path: MKTileOverlayPath, _ done: @escaping (Data?) -> Void) {
        if usesBBox || path.z <= nativeMaxZ {
            fetch(z: path.z, x: path.x, y: path.y, done)
            return
        }
        // past the source's top zoom: enlarge a piece of the parent tile
        let f = 1 << (path.z - nativeMaxZ)
        let subX = path.x % f, subY = path.y % f
        guard let parent = url(z: nativeMaxZ, x: path.x / f, y: path.y / f) else { done(nil); return }
        let cropKey = "\(parent.absoluteString)#\(f)-\(subX)-\(subY)" as NSString
        if let d = Self.cache.object(forKey: cropKey) { done(d as Data); return }
        fetch(z: nativeMaxZ, x: path.x / f, y: path.y / f) { data in
            guard let data, let out = Self.crop(data, parts: f, subX: subX, subY: subY) else { done(nil); return }
            Self.cache.setObject(out as NSData, forKey: cropKey, cost: out.count)
            done(out)
        }
    }

    private func fetch(z: Int, x: Int, y: Int, _ done: @escaping (Data?) -> Void) {
        guard let u = url(z: z, x: x, y: y) else { done(nil); return }
        let key = u.absoluteString as NSString
        if let d = Self.cache.object(forKey: key) { done(d as Data); return }
        guard Self.inflight.join(key, done) else { return }
        let g = group, fr = frame
        g?.began(fr)
        Self.session.dataTask(with: u) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
            let ok = data != nil && code < 400
            if ok, let data { Self.cache.setObject(data as NSData, forKey: key, cost: data.count) }
            g?.ended(fr)
            Self.inflight.finish(key, ok ? data : nil)
        }.resume()
    }

    /// Cut one piece out of a parent tile and scale it up to a full 256 px tile (pixels kept sharp).
    static func crop(_ data: Data, parts: Int, subX: Int, subY: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width / parts, h = img.height / parts
        guard w > 0, h > 0, let piece = img.cropping(to: CGRect(x: subX * w, y: subY * h, width: w, height: h)),
              let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(piece, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        guard let out = ctx.makeImage() else { return nil }
        let md = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(md as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, out, nil)
        return CGImageDestinationFinalize(dst) ? md as Data : nil
    }
}

/// A point on the map from a GeoJSON layer (storm report, earthquake, fire).
final class WxPoint: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?
    let color: PColor
    let size: CGFloat
    let layer: MapLayer
    init(_ c: CLLocationCoordinate2D, title: String, subtitle: String, color: PColor, size: CGFloat, layer: MapLayer) {
        coordinate = c; self.title = title; self.subtitle = subtitle; self.color = color; self.size = size; self.layer = layer
    }
}

// MARK: - Controller

/// Plays the radar loop and holds the chosen layers. Shared by iPhone, iPad and Mac.
/// Only ever touched on the main thread (timers and SwiftUI), so marking it Sendable is safe.
final class RadarController: ObservableObject, @unchecked Sendable {
    @Published var frames: [RadarService.Frame] = []
    @Published var index = 0
    @Published var playing = true
    @Published var layers: Set<MapLayer> {
        didSet { UserDefaults.standard.set(layers.map(\.rawValue), forKey: "mapLayers") }
    }
    @Published var opacity: Double = 0.75
    /// Set by the map: whether a frame's tiles have finished downloading.
    var isReady: ((Int) -> Bool)?
    private var waits = 0
    private var timer: Timer?
    private var refreshTimer: Timer?

    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: "mapLayers") {
            layers = Set(saved.compactMap(MapLayer.init(rawValue:)))
        } else {
            layers = [.radar, .warnings]   // default: Hi-Def radar plus warnings, like the website
        }
    }

    func load() async {
        let f = await RadarService.frames()
        await MainActor.run {
            self.frames = f
            self.index = max(0, f.count - 1)
            self.startTimer()
            // new radar scans arrive every 5 minutes
            if self.refreshTimer == nil {
                self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
                    Task { await self?.load() }
                }
            }
        }
    }

    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self, self.playing, !self.frames.isEmpty else { return }
            // pause briefly on the latest frame
            if self.index == self.frames.count - 1 && Int(Date().timeIntervalSince1970 * 2) % 4 != 0 { return }
            let next = (self.index + 1) % self.frames.count
            // hold the current frame (up to about 3 seconds) until the next one has loaded
            if let ready = self.isReady, !ready(next), self.waits < 6 { self.waits += 1; return }
            self.waits = 0
            self.index = next
        }
    }

    var currentTime: Date? { frames.indices.contains(index) ? frames[index].time : nil }
}

#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
#else
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

// MARK: - Map view

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

        // radar loop: one overlay per frame; only the current one is visible
        private var frameOverlays: [Int: WxTileOverlay] = [:]
        private let frameGroup = RadarFrameGroup()
        private var frameIndex: [ObjectIdentifier: Int] = [:]
        private var frameRenderers: [ObjectIdentifier: MKTileOverlayRenderer] = [:]
        private var frameKey = ""
        private var shownFrame = -1
        private var shownOpacity = -1.0

        // other tile layers
        private var tileOverlays: [MapLayer: WxTileOverlay] = [:]
        private var tileOpacity: [ObjectIdentifier: Double] = [:]

        // GeoJSON layers
        private struct GeoStyle { var stroke: PColor; var fill: PColor; var fillAlpha: CGFloat; var width: CGFloat; var dashed: Bool }
        private var geoOverlays: [MapLayer: [MKOverlay]] = [:]
        private var geoPoints: [MapLayer: [WxPoint]] = [:]
        private var geoLoading: Set<MapLayer> = []
        private var shapes: [ObjectIdentifier: GeoStyle] = [:]

        // lightning strikes from the website (empty while the website is private)
        private var strikes: [MKPointAnnotation] = []
        private var strikesTimer: Timer?

        init(_ p: RadarMap) { parent = p }

        /// Hidden radar frames keep a tiny opacity instead of zero so MapKit still loads their tiles
        /// ahead of time and the loop plays smoothly.
        private let hiddenAlpha: CGFloat = 0.003

        // MARK: sync
        func syncOverlays() {
            guard let map else { return }
            let L = parent.radar.layers

            // radar frames (rebuilt when the frame list changes)
            let key = L.contains(.radar) ? parent.radar.frames.map(\.template).joined() : ""
            if key != frameKey {
                map.removeOverlays(Array(frameOverlays.values))
                frameOverlays = [:]; frameIndex = [:]; frameRenderers = [:]; shownFrame = -1
                frameKey = key
                frameGroup.set([])
                if L.contains(.radar) {
                    var all: [WxTileOverlay] = []
                    for (i, f) in parent.radar.frames.enumerated() {
                        let o = WxTileOverlay(TileSource(template: f.template, nativeMaxZ: 10, opacity: parent.radar.opacity))
                        o.group = frameGroup
                        o.frame = i
                        frameOverlays[i] = o
                        frameIndex[ObjectIdentifier(o)] = i
                        all.append(o)
                        map.addOverlay(o, level: .aboveRoads)
                    }
                    frameGroup.set(all)
                    let g = frameGroup
                    parent.radar.isReady = { [weak g] i in g?.isReady(i) ?? true }
                }
            }

            // tile layers
            for layer in MapLayer.allCases where layer != .radar {
                guard let src = layer.tiles else { continue }
                let want = L.contains(layer)
                if want, tileOverlays[layer] == nil {
                    let o = WxTileOverlay(src)
                    tileOverlays[layer] = o
                    tileOpacity[ObjectIdentifier(o)] = src.opacity
                    if src.above { map.addOverlay(o, level: .aboveLabels) } else { map.insertOverlay(o, at: 0, level: .aboveRoads) }
                } else if !want, let o = tileOverlays[layer] {
                    map.removeOverlay(o)
                    tileOverlays[layer] = nil
                    tileOpacity[ObjectIdentifier(o)] = nil
                }
            }

            // GeoJSON layers
            for layer in MapLayer.allCases where layer.geojson != nil {
                let want = L.contains(layer)
                let have = geoOverlays[layer] != nil || geoPoints[layer] != nil
                if want, !have, !geoLoading.contains(layer) {
                    geoLoading.insert(layer)
                    Task { await loadGeo(layer) }
                } else if !want, have {
                    removeGeo(layer)
                }
            }

            // lightning strike markers ride along with the lightning layer
            if L.contains(.lightning), strikesTimer == nil {
                Task { await loadStrikes() }
                strikesTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { await self?.loadStrikes() } }
            } else if !L.contains(.lightning), let t = strikesTimer {
                t.invalidate(); strikesTimer = nil; map.removeAnnotations(strikes); strikes = []
            }
        }

        func showFrame(_ i: Int) {
            let op = parent.radar.opacity
            guard i != shownFrame || op != shownOpacity else { return }
            shownFrame = i; shownOpacity = op
            for (idx, o) in frameOverlays {
                guard let r = frameRenderers[ObjectIdentifier(o)] else { continue }
                let a: CGFloat = idx == i ? CGFloat(op) : hiddenAlpha
                if r.alpha != a { r.alpha = a; r.setNeedsDisplay() }
            }
        }

        // MARK: GeoJSON
        private func removeGeo(_ layer: MapLayer) {
            guard let map else { return }
            if let o = geoOverlays[layer] { map.removeOverlays(o); o.forEach { shapes[ObjectIdentifier($0)] = nil } }
            if let p = geoPoints[layer] { map.removeAnnotations(p) }
            geoOverlays[layer] = nil; geoPoints[layer] = nil
        }

        private static func props(_ f: MKGeoJSONFeature) -> [String: Any] {
            guard let d = f.properties, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
            return o
        }
        private static func str(_ v: Any?) -> String {
            if let s = v as? String { return s }
            if let n = v as? NSNumber { return n.stringValue }
            return ""
        }
        private static func num(_ v: Any?) -> Double? {
            if let n = v as? NSNumber { return n.doubleValue }
            if let s = v as? String { return Double(s) }
            return nil
        }

        @MainActor private func loadGeo(_ layer: MapLayer) async {
            defer { geoLoading.remove(layer) }
            guard let url = layer.geojson else { return }
            var req = URLRequest(url: url)
            req.setValue(AppConfig.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("application/geo+json, application/json", forHTTPHeaderField: "Accept")
            guard let data = try? await URLSession.shared.data(for: req).0,
                  let objs = try? MKGeoJSONDecoder().decode(data) else { return }

            var overlays: [MKOverlay] = []
            var points: [WxPoint] = []
            for case let f as MKGeoJSONFeature in objs {
                let p = Self.props(f)
                for g in f.geometry {
                    if let pt = g as? MKPointAnnotation {
                        if let w = Self.point(layer, p, pt.coordinate) { points.append(w) }
                    } else if let o = g as? MKOverlay {
                        shapes[ObjectIdentifier(o)] = Self.shape(layer, p)
                        overlays.append(o)
                    }
                }
            }
            guard let map, parent.radar.layers.contains(layer) else { return }
            removeGeo(layer)
            if !overlays.isEmpty {
                // draw warnings and outlooks under the labels; fill areas sit below the radar
                map.addOverlays(overlays, level: .aboveLabels)
            }
            map.addAnnotations(points)
            geoOverlays[layer] = overlays
            geoPoints[layer] = points
        }

        private static func shape(_ layer: MapLayer, _ p: [String: Any]) -> GeoStyle {
            switch layer {
            case .warnings:
                let ev = str(p["event"])
                let warn = ev.contains("Warning") || ev.contains("Emergency")
                let c = alertColor(ev)
                return GeoStyle(stroke: c, fill: c, fillAlpha: warn ? 0.22 : 0.08, width: warn ? 2.5 : 1.5, dashed: !warn)
            case .spc:
                return GeoStyle(stroke: .hex(str(p["stroke"])), fill: .hex(str(p["fill"])), fillAlpha: 0.3, width: 1.5, dashed: false)
            case .mcd:
                let c = PColor.hex("#22d3ee")
                return GeoStyle(stroke: c, fill: c, fillAlpha: 0.12, width: 2, dashed: true)
            case .drought:
                let colors = ["#ffff00", "#fcd37f", "#ffaa00", "#e60000", "#730000"]
                let i = Int(num(p["dm"]) ?? -1)
                let c = PColor.hex(colors.indices.contains(i) ? colors[i] : "#999999")
                return GeoStyle(stroke: c, fill: c, fillAlpha: 0.4, width: 0.5, dashed: false)
            default:
                return GeoStyle(stroke: .gray, fill: .gray, fillAlpha: 0.15, width: 1, dashed: false)
            }
        }

        private static func point(_ layer: MapLayer, _ p: [String: Any], _ c: CLLocationCoordinate2D) -> WxPoint? {
            switch layer {
            case .lsr:
                let t = str(p["typetext"]).uppercased()
                let color: String = t.contains("TORNADO") || t.contains("FUNNEL") ? "#ef4444" : t.contains("HAIL") ? "#22c55e"
                    : t.contains("WIND") || t.contains("TSTM") ? "#3b82f6" : t.contains("FLOOD") || t.contains("RAIN") ? "#06b6d4"
                    : t.contains("SNOW") || t.contains("ICE") || t.contains("SLEET") ? "#e5e7eb" : "#a855f7"
                let mag = str(p["magnitude"]), unit = str(p["unit"])
                let title = str(p["typetext"]) + (mag.isEmpty || mag == "0" ? "" : " \(mag) \(unit)")
                return WxPoint(c, title: title.trimmingCharacters(in: .whitespaces), subtitle: "\(str(p["city"])), \(str(p["st"]))", color: .hex(color), size: 10, layer: layer)
            case .quakes:
                let m = num(p["mag"]) ?? 0
                return WxPoint(c, title: String(format: "M%.1f earthquake", m), subtitle: str(p["place"]), color: .hex("#fb923c"), size: CGFloat(max(8, m * 4)), layer: layer)
            case .fires:
                var sub = ""
                if let a = num(p["IncidentSize"]) { sub = "\(Int(a).formatted()) acres" }
                if let pc = num(p["PercentContained"]) { sub += sub.isEmpty ? "\(Int(pc))% contained" : ", \(Int(pc))% contained" }
                return WxPoint(c, title: "\(str(p["IncidentName"])) Fire", subtitle: sub, color: .hex("#f97316"), size: 11, layer: layer)
            default:
                return nil
            }
        }

        // MARK: lightning strikes
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
                let id = ObjectIdentifier(t)
                if let i = frameIndex[id] {
                    r.alpha = i == parent.radar.index ? CGFloat(parent.radar.opacity) : hiddenAlpha
                    frameRenderers[id] = r
                } else {
                    r.alpha = CGFloat(tileOpacity[id] ?? 0.7)
                }
                return r
            }
            let s = shapes[ObjectIdentifier(overlay)] ?? GeoStyle(stroke: .gray, fill: .gray, fillAlpha: 0.15, width: 1, dashed: false)
            let r: MKOverlayPathRenderer
            if let p = overlay as? MKPolygon { r = MKPolygonRenderer(polygon: p) }
            else if let p = overlay as? MKMultiPolygon { r = MKMultiPolygonRenderer(multiPolygon: p) }
            else if let p = overlay as? MKPolyline { r = MKPolylineRenderer(polyline: p) }
            else if let p = overlay as? MKMultiPolyline { r = MKMultiPolylineRenderer(multiPolyline: p) }
            else { return MKOverlayRenderer(overlay: overlay) }
            r.strokeColor = s.stroke
            r.fillColor = s.fill.withAlphaComponent(s.fillAlpha)
            r.lineWidth = s.width
            if s.dashed { r.lineDashPattern = [6, 4] }
            return r
        }

        func mapView(_ m: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let w = annotation as? WxPoint {
                let v = m.dequeueReusableAnnotationView(withIdentifier: "wxpoint") ?? MKAnnotationView(annotation: w, reuseIdentifier: "wxpoint")
                v.annotation = w
                v.image = Self.dot(w.color, w.size)
                v.canShowCallout = true
                return v
            }
            guard (annotation.title ?? nil) == "strike" else { return nil }
            let v = m.dequeueReusableAnnotationView(withIdentifier: "strike") ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "strike")
            v.annotation = annotation
            let age = Int((annotation.subtitle ?? nil) ?? "0") ?? 0
            v.image = Self.symbol(age < 5 ? "bolt.fill" : "circle.fill", color: age < 5 ? .systemYellow : (age < 15 ? .systemOrange : .systemRed), size: age < 5 ? 14 : 6)
            v.canShowCallout = false
            return v
        }

        func mapView(_ m: MKMapView, regionDidChangeAnimated animated: Bool) {
            parent.onCenterChange(m.centerCoordinate)
        }

        // MARK: drawing helpers
        #if os(macOS)
        static func symbol(_ name: String, color: NSColor, size: CGFloat) -> NSImage? {
            let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .bold).applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        }
        static func dot(_ color: NSColor, _ size: CGFloat) -> NSImage {
            NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
                color.setFill(); NSColor.black.withAlphaComponent(0.7).setStroke()
                let p = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)); p.lineWidth = 1.2; p.fill(); p.stroke()
                return true
            }
        }
        #else
        static func symbol(_ name: String, color: UIColor, size: CGFloat) -> UIImage? {
            UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .bold))?
                .withTintColor(color, renderingMode: .alwaysOriginal)
        }
        static func dot(_ color: UIColor, _ size: CGFloat) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
                let r = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: 1, dy: 1)
                color.setFill(); UIColor.black.withAlphaComponent(0.7).setStroke()
                let p = UIBezierPath(ovalIn: r); p.lineWidth = 1.2; p.fill(); p.stroke()
            }
        }
        #endif

        /// Official NWS hazard colors for the most common alerts (same table as the website).
        static func alertColor(_ e: String) -> PColor {
            let table: [String: String] = [
                "Tornado Warning": "#ff0000", "Tornado Emergency": "#8b0000", "Severe Thunderstorm Warning": "#ffa500",
                "Flash Flood Warning": "#8b0000", "Flash Flood Emergency": "#8b0000", "Flood Warning": "#00ff00",
                "Flood Advisory": "#00ff7f", "Flood Watch": "#2e8b57", "Flash Flood Watch": "#2e8b57",
                "Tornado Watch": "#ffff00", "Severe Thunderstorm Watch": "#db7093", "Special Weather Statement": "#ffe4b5",
                "Special Marine Warning": "#ffa500", "Hurricane Warning": "#dc143c", "Hurricane Watch": "#ff00ff",
                "Tropical Storm Warning": "#b22222", "Tropical Storm Watch": "#f08080", "Storm Surge Warning": "#b524f7",
                "Storm Surge Watch": "#db7ff7", "Winter Storm Warning": "#ff69b4", "Winter Storm Watch": "#4682b4",
                "Winter Weather Advisory": "#7b68ee", "Ice Storm Warning": "#8b008b", "Blizzard Warning": "#ff4500",
                "High Wind Warning": "#daa520", "Wind Advisory": "#d2b48c", "Extreme Heat Warning": "#c71585",
                "Heat Advisory": "#ff7f50", "Extreme Cold Warning": "#0000ff", "Cold Weather Advisory": "#afeeee",
                "Freeze Warning": "#483d8b", "Frost Advisory": "#6495ed", "Red Flag Warning": "#ff1493",
                "Fire Weather Watch": "#ffdead", "Dense Fog Advisory": "#708090", "Gale Warning": "#dda0dd",
                "Small Craft Advisory": "#d8bfd8", "Rip Current Statement": "#40e0d0", "High Surf Advisory": "#ba55d3",
                "Coastal Flood Warning": "#228b22", "Coastal Flood Advisory": "#7cfc00",
            ]
            return .hex(table[e] ?? "#9aa6b2")
        }
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
