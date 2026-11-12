import SwiftUI
import MapKit
import ImageIO
import QuartzCore
import CoreImage

#if os(macOS)
typealias PColor = NSColor
typealias PImage = NSImage
#else
typealias PColor = UIColor
typealias PImage = UIImage
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
    case radarSat = "Radar & Satellite", severe = "Severe Weather", conditions = "Conditions", tropics = "Tropics"
    case snow = "Snow & Ice", marine = "Marine", more = "More"
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
    case radar, sites, satIR, satVis, satWV, satColor, lightning, rainRate, rain1h, rain, rain72, echoTops, tempMap
    case warnings, spc, mcd, lsr, hail
    case fronts, temps, winds, windFlow, road, aqi
    case hurricanes, twoutlook, windprob, surge
    case snowdepth, snowprob
    case buoys, cams, waves, sst, charts
    case traffic, aviation, iss, outages, avalanche, drought, quakes, fires
    case sigmets, airmets, tfrs, vfrChart

    var id: String { rawValue }

    var title: String {
        switch self {
        case .radar: return "Hi-Def Radar"
        case .sites: return "Doppler Radar (tap a site)"
        case .satIR: return "Clouds: Infrared Satellite"
        case .satVis: return "Clouds: Visible Satellite"
        case .satWV: return "Clouds: Water Vapor"
        case .satColor: return "Clouds: True Color"
        case .lightning: return "Lightning"
        case .rainRate: return "Rain Rate (now)"
        case .rain1h: return "Rain (past hour)"
        case .tempMap: return "Temperature Map"
        case .echoTops: return "Echo Tops (storm height)"
        case .road: return "Road Weather (estimated)"
        case .rain: return "Rain Totals (24 hr)"
        case .rain72: return "Rain Totals (3 days)"
        case .warnings: return "Weather Alerts"
        case .spc: return "SPC Severe Outlook"
        case .mcd: return "Mesoscale Discussions"
        case .lsr: return "Storm Reports (24 hr)"
        case .hail: return "Hail (reports and risk)"
        case .fronts: return "Fronts & Pressure"
        case .temps: return "Temperatures"
        case .winds: return "Winds"
        case .windFlow: return "Wind Animation"
        case .aqi: return "Air Quality"
        case .hurricanes: return "Hurricane Tracker"
        case .twoutlook: return "Tropical Development Areas"
        case .windprob: return "Tropical Storm Wind Chances"
        case .surge: return "Storm Surge Risk"
        case .snowdepth: return "Snow Depth Now"
        case .snowprob: return "Next Day Snow (4 in+)"
        case .buoys: return "Buoys (live)"
        case .cams: return "Buoy Cameras (live)"
        case .waves: return "Wave Heights"
        case .sst: return "Sea Surface Temperature"
        case .charts: return "Nautical Charts (NOAA)"
        case .traffic: return "Traffic"
        case .aviation: return "Aviation (flight rules)"
        case .iss: return "Orbital Tracking (ISS)"
        case .outages: return "Power Outages"
        case .avalanche: return "Avalanche Danger"
        case .drought: return "Droughts"
        case .quakes: return "Earthquakes"
        case .fires: return "Wildfires"
        case .sigmets: return "SIGMETs"
        case .airmets: return "AIRMETs"
        case .tfrs: return "Temporary Flight Restrictions"
        case .vfrChart: return "VFR Sectional Chart"
        }
    }

    var group: LayerGroup {
        switch self {
        case .radar, .sites, .satIR, .satVis, .satWV, .satColor, .lightning, .rainRate, .rain1h, .rain, .rain72, .echoTops, .tempMap: return .radarSat
        case .warnings, .spc, .mcd, .lsr, .hail: return .severe
        case .fronts, .temps, .winds, .windFlow, .road, .aqi: return .conditions
        case .hurricanes, .twoutlook, .windprob, .surge: return .tropics
        case .snowdepth, .snowprob, .avalanche: return .snow
        case .buoys, .cams, .waves, .sst, .charts: return .marine
        case .traffic, .aviation, .iss, .outages, .drought, .quakes, .fires, .sigmets, .airmets, .tfrs, .vfrChart: return .more
        }
    }

    /// Plan needed (same levels as the website). The Radar Pack unlocks every layer.
    var tier: Plan {
        switch self {
        case .lightning, .rainRate, .rain1h, .echoTops, .road, .rain, .rain72, .hail, .temps, .winds, .windFlow, .aqi, .hurricanes, .twoutlook, .windprob, .surge, .snowprob, .drought, .aviation, .sigmets, .airmets, .tfrs:
            return .plus
        case .sst, .charts, .buoys, .cams, .waves, .traffic, .outages, .sites, .iss, .vfrChart:
            return .pro
        default:
            return .free
        }
    }

    /// Opened by the one-time Pro Radar Pack: every radar layer, nothing else.
    var inRadarPack: Bool { [.sites, .echoTops, .rainRate, .rain1h, .rain, .rain72].contains(self) }
    /// Shown in the Pro group (Professional Radar, Marine & Space) instead of its normal group.
    var isProRadar: Bool { self == .sites || isMarineSpace }
    var isMarineSpace: Bool { [.buoys, .cams, .waves, .sst, .charts, .iss].contains(self) }

    /// Only one satellite view at a time.
    var isSatellite: Bool { [.satIR, .satVis, .satWV, .satColor].contains(self) }

    /// Layers redrawn for whatever area is on screen.
    var followsView: Bool { [.temps, .winds, .road, .aqi, .waves, .aviation].contains(self) }

    /// Tile layers. Time-based URLs get a cache-busting stamp so they refresh.
    var tiles: TileSource? {
        let iem = "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0"
        let ms = "https://mapservices.weather.noaa.gov"
        let now = Date().timeIntervalSince1970
        let b5 = Int(now / 300), b10 = Int(now / 600), b30 = Int(now / 1800), b2h = Int(now / 7200), b3h = Int(now / 10800)
        func ags(_ svc: String, _ layers: String?, _ bust: Int) -> String {
            "\(ms)/\(svc)/export?bbox={bbox}&bboxSR=3857&imageSR=3857&size=256,256&format=png32&transparent=true\(layers.map { "&layers=show:\($0)" } ?? "")&f=image&_=\(bust)"
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
        case .rainRate:
            // MRMS precipitation rate, a new image every 2 minutes (named by its UTC time)
            let t = Date(timeIntervalSince1970: ((now - 360) / 120).rounded(.down) * 120)
            let f = DateFormatter(); f.dateFormat = "yyyyMMddHHmm"; f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX")
            return TileSource(template: "https://mesonet.agron.iastate.edu/c/tile.py/1.0.0/mrms::a2m-\(f.string(from: t))/{z}/{x}/{y}.png", nativeMaxZ: 10, opacity: 0.8)
        case .echoTops: return TileSource(template: "\(iem)/nexrad-eet/{z}/{x}/{y}.png?_=\(b5)", nativeMaxZ: 10, opacity: 0.75)
        case .rain1h: return TileSource(template: "\(iem)/q2-n1p-900913/{z}/{x}/{y}.png?_=\(b5)", nativeMaxZ: 10, opacity: 0.7)
        // NWS NDFD forecast temperature (NOAA map service)
        case .tempMap: return TileSource(template: ags("raster/rest/services/NDFD/NDFD_temp/MapServer", nil, b3h), nativeMaxZ: 20, opacity: 0.6)
        case .rain72: return TileSource(template: "\(iem)/q2-p72h-900913/{z}/{x}/{y}.png?_=\(b10)", nativeMaxZ: 10, opacity: 0.7)
        case .hurricanes: return TileSource(template: ags("tropical/rest/services/tropical/NHC_tropical_weather/MapServer", nil, b30), nativeMaxZ: 20, opacity: 0.9, above: true)
        case .twoutlook: return TileSource(template: ags("tropical/rest/services/tropical/NHC_tropical_weather_summary/MapServer", "1,2,3,33", b30), nativeMaxZ: 20, opacity: 0.85, above: true)
        case .windprob: return TileSource(template: ags("tropical/rest/services/tropical/NHC_tropical_weather_summary/MapServer", "30,18", b30), nativeMaxZ: 20, opacity: 0.7, above: true)
        case .surge: return TileSource(template: ags("tropical/rest/services/tropical/StormSurgeRisk/MapServer", "10", b3h), nativeMaxZ: 20, opacity: 0.75)
        case .snowdepth: return TileSource(template: ags("raster/rest/services/snow/NOHRSC_Snow_Analysis/MapServer", "0", b3h), nativeMaxZ: 20, opacity: 0.7)
        case .snowprob: return TileSource(template: ags("vector/rest/services/precip/wpc_prob_winter_precip/MapServer", "1", b2h), nativeMaxZ: 20, opacity: 0.7)
        case .sst: return TileSource(template: "https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/GHRSST_L4_MUR_Sea_Surface_Temperature/default/default/GoogleMapsCompatible_Level7/{z}/{y}/{x}.png?_=\(Int(now / 21600))", nativeMaxZ: 7, opacity: 0.75)
        // FAA VFR sectional charts (FAA AIS tile service)
        case .vfrChart: return TileSource(template: "https://tiles.arcgis.com/tiles/ssFJjBXIUyZDrSYZ/arcgis/rest/services/VFR_Sectional/MapServer/tile/{z}/{y}/{x}", nativeMaxZ: 12, opacity: 1)
        case .charts: return TileSource(template: "https://gis.charttools.noaa.gov/arcgis/rest/services/MCS/NOAAChartDisplay/MapServer/exts/MaritimeChartService/MapServer/export?bbox={bbox}&bboxSR=3857&imageSR=3857&size=256,256&format=png&transparent=true&f=image", nativeMaxZ: 20, opacity: 1)
        default: return nil
        }
    }

    /// GeoJSON layers (shapes and points).
    var geojson: [URL] {
        let s: [String]
        switch self {
        case .warnings: s = ["https://api.weather.gov/alerts/active?status=actual&message_type=alert,update"]
        case .spc: s = ["https://www.spc.noaa.gov/products/outlook/day1otlk_cat.lyr.geojson"]
        case .mcd: s = ["https://mesonet.agron.iastate.edu/api/1/nws/spc_mcd.geojson"]
        case .lsr: s = ["https://mesonet.agron.iastate.edu/geojson/lsr.geojson?hours=24"]
        case .hail: s = ["https://www.spc.noaa.gov/products/outlook/day1otlk_hail.lyr.geojson", "https://mesonet.agron.iastate.edu/geojson/lsr.geojson?hours=72"]
        case .drought: s = ["https://services5.arcgis.com/0OTVzJS4K09zlixn/arcgis/rest/services/USDM_current/FeatureServer/0/query?where=1%3D1&outFields=dm&maxAllowableOffset=0.05&geometryPrecision=3&f=geojson"]
        case .quakes: s = ["https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/2.5_day.geojson"]
        case .fires: s = ["https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/WFIGS_Incident_Locations_Current/FeatureServer/0/query?where=IncidentSize%3E%3D100&outFields=IncidentName,IncidentSize,PercentContained&f=geojson"]
        case .outages: s = ["https://openenergyhub.ornl.gov/api/explore/v2.1/catalog/datasets/odin-real-time-outages-county/exports/geojson?select=county%2Cstate%2Cmetersaffected%2Cgeom"]
        case .avalanche: s = ["https://api.avalanche.org/v2/public/products/map-layer"]
        case .sigmets: s = ["https://aviationweather.gov/api/data/airsigmet?format=geojson"]
        case .airmets: s = ["https://aviationweather.gov/api/data/gairmet?format=geojson"]
        case .tfrs: s = ["https://tfr.faa.gov/geoserver/TFR/ows?service=WFS&version=1.1.0&request=GetFeature&typeName=TFR:V_TFR_LOC&maxFeatures=500&outputFormat=application/json&srsname=EPSG:4326"]
        default: s = []
        }
        return s.compactMap(URL.init(string:))
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

/// A point on the map: a report, quake, fire, buoy, airport, or a value label (temperature, wind, AQI, waves).
final class WxPoint: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?
    let color: PColor
    let size: CGFloat
    let layer: MapLayer
    /// When set, the point is drawn as a colored badge with this text instead of a dot.
    let label: String?
    let darkText: Bool
    /// Buoy cameras: the live photo to open when tapped.
    let link: URL?
    init(_ c: CLLocationCoordinate2D, title: String, subtitle: String, color: PColor, size: CGFloat, layer: MapLayer,
         label: String? = nil, darkText: Bool = true, link: URL? = nil) {
        coordinate = c; self.title = title; self.subtitle = subtitle; self.color = color; self.size = size; self.layer = layer
        self.label = label; self.darkText = darkText; self.link = link
    }
}

/// Core Image context for the Hi-Def radar smoothing (a global so background image code can use it).
let radarCIContext = CIContext(options: [.cacheIntermediates: false])

/// A lightning flash that blooms and fades on the map (MyRadar style), then removes itself.
final class FlashAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    init(_ c: CLLocationCoordinate2D) { coordinate = c }
}

// MARK: - Radar image overlay

/// The radar is drawn as one image per frame covering the area on screen (like most radar apps), so
/// switching frames never shows half-loaded tiles. The overlay covers the world; the renderer draws
/// whichever image it was last given, at that image's own position.
final class RadarImageOverlay: NSObject, MKOverlay {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
}

final class RadarImageRenderer: MKOverlayRenderer {
    private let lock = NSLock()
    private var image: CGImage?
    private var imageRect = MKMapRect.null
    // previous frame, faded out while the new one fades in (smooth loop like MyRadar)
    private var prev: CGImage?
    private var prevRect = MKMapRect.null
    private var fade: CGFloat = 1
    private var fadeTimer: Timer?

    func show(_ img: CGImage, _ r: MKMapRect) {
        lock.lock()
        prev = image; prevRect = imageRect
        image = img; imageRect = r
        fade = prev == nil ? 1 : 0
        lock.unlock()
        fadeTimer?.invalidate()
        if fade < 1 {
            let start = Date()
            fadeTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                let f = min(1, CGFloat(Date().timeIntervalSince(start) / 0.28))
                self.lock.lock(); self.fade = f; if f >= 1 { self.prev = nil }; self.lock.unlock()
                self.setNeedsDisplay()
                if f >= 1 { t.invalidate() }
            }
        }
        setNeedsDisplay()
    }
    func clear() { lock.lock(); image = nil; prev = nil; lock.unlock(); setNeedsDisplay() }

    override func canDraw(_ mapRect: MKMapRect, zoomScale: MKZoomScale) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (image != nil && mapRect.intersects(imageRect)) || (prev != nil && mapRect.intersects(prevRect))
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in ctx: CGContext) {
        lock.lock(); let img = image, r0 = imageRect, old = prev, r1 = prevRect, f = fade; lock.unlock()
        ctx.interpolationQuality = .high   // smooth the radar pixels like MyRadar
        if let old, f < 1 { put(old, r1, alpha: 1 - f, ctx) }
        if let img { put(img, r0, alpha: f, ctx) }
    }

    private func put(_ img: CGImage, _ m: MKMapRect, alpha: CGFloat, _ ctx: CGContext) {
        let r = rect(for: m)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
    }
}

/// Map background. Auto picks Dark or Light from the app's appearance.
enum Basemap: String, CaseIterable, Identifiable {
    case auto, dark, light, roads, aerial, topo, proDark, proLight, vfr, apple, satellite
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Auto"
        case .dark: return "Grayscale"
        case .light: return "Daylight"
        case .roads: return "Roads"
        case .aerial: return "Aerial"
        case .topo: return "Topography"
        case .proDark: return "Pro Dark"
        case .proLight: return "Pro Light"
        case .vfr: return "VFR Sectional"
        case .apple: return "Apple"
        case .satellite: return "Apple Satellite"
        }
    }
    /// Plan needed for this background.
    var tier: Plan { self == .vfr ? .pro : .free }
    /// Light backgrounds get dark borders.
    var isLight: Bool { [.light, .roads, .topo, .proLight, .vfr].contains(self) }

    private static let esri = "https://services.arcgisonline.com/ArcGIS/rest/services"
    private static let carto = "https://basemaps.cartocdn.com"
    /// Background tiles, and place names drawn above the radar when the background has them separately.
    var tiles: (base: String, labels: String?, maxZ: Int)? {
        switch self {
        case .dark: return ("\(Self.esri)/Canvas/World_Dark_Gray_Base/MapServer/tile/{z}/{y}/{x}", "\(Self.esri)/Canvas/World_Dark_Gray_Reference/MapServer/tile/{z}/{y}/{x}", 16)
        case .light: return ("\(Self.esri)/Canvas/World_Light_Gray_Base/MapServer/tile/{z}/{y}/{x}", "\(Self.esri)/Canvas/World_Light_Gray_Reference/MapServer/tile/{z}/{y}/{x}", 16)
        case .roads: return ("\(Self.esri)/World_Street_Map/MapServer/tile/{z}/{y}/{x}", nil, 18)
        case .aerial: return ("\(Self.esri)/World_Imagery/MapServer/tile/{z}/{y}/{x}", "\(Self.esri)/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}", 18)
        case .topo: return ("\(Self.esri)/World_Topo_Map/MapServer/tile/{z}/{y}/{x}", nil, 18)
        case .proDark: return ("\(Self.carto)/dark_nolabels/{z}/{x}/{y}.png", "\(Self.carto)/dark_only_labels/{z}/{x}/{y}.png", 18)
        case .proLight: return ("\(Self.carto)/light_nolabels/{z}/{x}/{y}.png", "\(Self.carto)/light_only_labels/{z}/{x}/{y}.png", 18)
        case .vfr: return ("https://tiles.arcgis.com/tiles/ssFJjBXIUyZDrSYZ/arcgis/rest/services/VFR_Sectional/MapServer/tile/{z}/{y}/{x}", nil, 12)
        default: return nil
        }
    }
    /// Roads drawn over backgrounds that don't have their own.
    static let roadsOverlay = "\(esri)/Reference/World_Transportation/MapServer/tile/{z}/{y}/{x}"

    /// A small sample of the background (Southeast US) for the picker.
    var thumb: URL? {
        guard let t = tiles?.base else { return nil }
        let (z, x, y) = self == .vfr ? (9, 135, 204) : (5, 8, 12)
        return URL(string: t.replacingOccurrences(of: "{z}", with: "\(z)").replacingOccurrences(of: "{x}", with: "\(x)").replacingOccurrences(of: "{y}", with: "\(y)"))
    }
}

// MARK: - US borders

/// Our own US outline, state lines and county lines (US Census county shapes, built into the app's
/// asset catalog). Drawn by the app so they can be styled and faded with zoom, instead of relying on
/// the faint lines baked into the map tiles. Loaded once and shared by every map.
enum USBorders {
    /// US land borders with Canada and Mexico (thick).
    static let nation = load("USNation")
    /// US coastline (thinner than the land borders).
    static let coast = load("USCoast")
    /// Other countries' borders, and their states and provinces.
    static let world = load("WorldBorders")
    static let provinces = load("WorldProvinces")
    static let states = load("USStates")
    static let counties = load("USCounties")

    /// Each file is a list of lines, each line a flat [lon, lat, lon, lat, ...] list.
    private static func load(_ name: String) -> MKMultiPolyline {
        guard let d = NSDataAsset(name: name)?.data,
              let lines = try? JSONSerialization.jsonObject(with: d) as? [[Double]] else { return MKMultiPolyline([]) }
        return MKMultiPolyline(lines.map { l in
            var pts = [CLLocationCoordinate2D](); pts.reserveCapacity(l.count / 2)
            var i = 0
            while i + 1 < l.count { pts.append(CLLocationCoordinate2D(latitude: l[i + 1], longitude: l[i])); i += 2 }
            return MKPolyline(coordinates: pts, count: pts.count)
        })
    }

    /// County lines appear as you zoom in to about state level: hidden past ~9 degrees tall, full by ~4.
    static func countyAlpha(_ latDelta: Double) -> CGFloat {
        CGFloat(min(1, max(0, (9 - latDelta) / 5)))
    }
}

// MARK: - Controller

/// Plays the radar loop and holds the chosen layers. Shared by iPhone, iPad and Mac.
/// Only ever touched on the main thread (timers and SwiftUI), so marking it Sendable is safe.
final class RadarController: ObservableObject, @unchecked Sendable {
    @Published var frames: [RadarService.Frame] = []
    @Published var index = 0
    @Published var playing = true
    /// Split screen: this loop doesn't advance on its own; it follows the other radar's time.
    var follower = false
    @Published var layers: Set<MapLayer> {
        didSet { if persist { UserDefaults.standard.set(layers.map(\.rawValue), forKey: "mapLayers") } }
    }
    /// The main radar screen saves its choices; dashboard radar cards don't.
    let persist: Bool
    @Published var opacity: Double = 0.75
    /// Hi-Def: light speckle removed and edges smoothed (like MyRadar). Off = Standard (raw radar).
    @Published var hiDef: Bool = UserDefaults.standard.object(forKey: "radarHiDef") as? Bool ?? true {
        didSet { if persist { UserDefaults.standard.set(hiDef, forKey: "radarHiDef") } }
    }
    @Published var basemap: Basemap = Basemap(rawValue: UserDefaults.standard.string(forKey: "basemap") ?? "") ?? .auto {
        didSet { if persist { UserDefaults.standard.set(basemap.rawValue, forKey: "basemap") } }
    }
    /// Last hour, past 48 hours (Pro), or future radar (Pro).
    @Published private(set) var mode: RadarMode = .recent
    /// Showing one Doppler radar instead of the US mosaic (nil = Hi-Def mosaic).
    @Published private(set) var site: RadarService.Site?
    /// What the map is showing, for overlays drawn on top of it (wind animation).
    let viewport = MapViewport()
    /// Takes a picture of the map (set by the map view).
    var snapshot: (() -> CGImage?)?
    /// Set by the map: whether a frame's image has finished downloading.
    var isReady: ((Int) -> Bool)?
    private var waits = 0
    private var timer: Timer?
    private var refreshTimer: Timer?

    /// A raw radar for dashboard cards: just the radar (no buoys, sites or other layers), Standard style, not saved.
    init(raw: Bool) {
        persist = false
        layers = [.radar]
        if raw { hiDef = false }
    }

    init() {
        persist = true
        if let saved = UserDefaults.standard.stringArray(forKey: "mapLayers") {
            layers = Set(saved.compactMap(MapLayer.init(rawValue:)))
        } else {
            layers = [.radar, .warnings, .lightning]   // default: Hi-Def radar, warnings and live lightning
        }
        if !UserDefaults.standard.bool(forKey: "lightningDefault1") {   // one-time: turn lightning on now that strikes are live
            layers.insert(.lightning)
            UserDefaults.standard.set(true, forKey: "lightningDefault1")
        }
    }

    func setMode(_ m: RadarMode) {
        mode = m; site = nil
        Task { await load() }
    }

    /// Show one radar (Reflectivity or Velocity), or nil to go back to the Hi-Def mosaic.
    func setSite(_ s: RadarService.Site?) {
        site = s
        if s != nil { mode = .recent; layers.insert(.radar) }
        Task { await load() }
    }

    func load() async {
        let (m, s) = await MainActor.run { (mode, site) }
        let frames: [RadarService.Frame]
        if let s { frames = await RadarService.siteFrames(s) } else { frames = await RadarService.frames(m) }
        await MainActor.run {
            guard m == self.mode, s == self.site else { return }
            let f = frames
            self.frames = f
            // past radar starts at the newest frame; future radar starts at "now"
            self.index = m == .future ? 0 : max(0, f.count - 1)
            self.playing = true
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
        timer = Timer.scheduledTimer(withTimeInterval: mode == .history ? 0.15 : 0.5, repeats: true) { [weak self] _ in
            guard let self, self.playing, !self.follower, !self.frames.isEmpty else { return }
            // pause briefly on the latest frame
            if self.index == self.frames.count - 1 && Int(Date().timeIntervalSince1970 * 2) % 4 != 0 { return }
            // future radar: pause on "now" too
            if self.mode == .future && self.index == 0 && Int(Date().timeIntervalSince1970 * 2) % 3 != 0 { return }
            let next = (self.index + 1) % self.frames.count
            // hold the current frame (up to about 3 seconds) until the next one has loaded
            if let ready = self.isReady, !ready(next), self.waits < 6 { self.waits += 1; return }
            self.waits = 0
            self.index = next
        }
    }

    var currentTime: Date? { frames.indices.contains(index) ? frames[index].time : nil }

    /// Jump to the frame closest to a time (split screen keeps both radars on the same moment).
    func show(time: Date?) {
        guard let time, !frames.isEmpty else { return }
        let best = frames.indices.min { abs(frames[$0].time.timeIntervalSince(time)) < abs(frames[$1].time.timeIntervalSince(time)) } ?? index
        if best != index { index = best }
    }
    var currentIsFuture: Bool { frames.indices.contains(index) && frames[index].future }
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
    /// Tapped a buoy camera: its name and live photo.
    var onCamera: ((String, URL) -> Void)? = nil
    /// Tapped a radar site on the Doppler layer.
    var onSite: ((RadarService.Site) -> Void)? = nil
    /// Tapped a county on the Power Outages layer.
    var onOutage: ((OutageArea) -> Void)? = nil
    /// Split screen: maps that pan and zoom together.
    var sync: MapSync? = nil

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
        radar.snapshot = { [weak m] in m.flatMap { RadarMap.capture($0) } }
        sync?.add(m)
        // taps on shapes (power outage counties); annotations and map gestures still work
        #if os(iOS)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.mapTapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        m.addGestureRecognizer(tap)
        #else
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.mapTapped(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        m.addGestureRecognizer(click)
        #endif
        return m
    }

    private func update(_ m: MKMapView, _ context: Context) {
        let c = context.coordinator
        c.parent = self
        if c.lastRecenter != recenterToken {
            c.lastRecenter = recenterToken
            m.setCenter(center, animated: true)
        }
        c.syncBasemap(context.environment.colorScheme == .dark)
        c.syncOverlays()
        c.showFrame(radar.index)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: RadarMap
        weak var map: MKMapView?
        var lastRecenter = 0

        // Radar loop: one image per frame for the area on screen. If the next frame isn't downloaded yet,
        // the current one stays up, so the loop never goes blank.
        private let radarOverlay = RadarImageOverlay()
        private var radarRenderer: RadarImageRenderer?
        private var frameImages: [Int: (CGImage, MKMapRect)] = [:]
        private var frameKey = ""
        private var frameCount = 0
        private var wasSite = false
        private var wasHiDef = true
        private var shownFrame = -1
        private var shownOpacity = -1.0
        private var radarTask: Task<Void, Never>?

        // map background
        private var shownBasemap = ""
        private var baseOverlays: [WxTileOverlay] = []
        private var labelsOverlay: WxTileOverlay?
        private var borderOverlays: [MKOverlay] = []
        private weak var countyRenderer: MKOverlayRenderer?
        private var countyShown: CGFloat = -1

        // other tile layers
        private var tileOverlays: [MapLayer: WxTileOverlay] = [:]
        private var tileOpacity: [ObjectIdentifier: Double] = [:]

        // shapes and points
        private struct GeoStyle { var stroke: PColor; var fill: PColor; var fillAlpha: CGFloat; var width: CGFloat; var dashed: Bool }
        private var geoOverlays: [MapLayer: [MKOverlay]] = [:]
        private var geoPoints: [MapLayer: [WxPoint]] = [:]
        private var geoLoading: Set<MapLayer> = []
        private var shapes: [ObjectIdentifier: GeoStyle] = [:]
        private var outageInfo: [ObjectIdentifier: OutageArea] = [:]
        private var viewWork: DispatchWorkItem?
        private var issTimer: Timer?

        // lightning strikes from the website (empty while the website is private)
        private var strikes: [MKPointAnnotation] = []
        private var strikesTimer: Timer?
        private var lastStrikeT: Double = 0
        private var recentStrikes: [[Double]] = []
        private var flashTimer: Timer?
        private var flashGen = 0   // bumps when lightning is turned off, cancelling scheduled flashes

        init(_ p: RadarMap) { parent = p }

        private var imperial: Bool { (UserDefaults.standard.string(forKey: "units") ?? "imperial") == "imperial" }

        // MARK: sync
        func syncBasemap(_ dark: Bool) {
            guard let map else { return }
            var b = parent.radar.basemap
            if b == .auto { b = dark ? .dark : .light }
            let showBorders = UserDefaults.standard.object(forKey: "mapBorders") as? Bool ?? true
            let showCounties = UserDefaults.standard.object(forKey: "mapCounties") as? Bool ?? true
            let showLabels = UserDefaults.standard.object(forKey: "mapLabels") as? Bool ?? true
            let showRoads = UserDefaults.standard.object(forKey: "mapRoads") as? Bool ?? false
            let key = "\(b.rawValue)-\(dark)-\(showBorders)-\(showCounties)-\(showLabels)-\(showRoads)"
            guard key != shownBasemap else { return }
            shownBasemap = key
            map.removeOverlays(baseOverlays); baseOverlays = []
            map.removeOverlays(borderOverlays); borderOverlays = []
            switch b {
            case .satellite:
                map.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .flat)
            case _ where b.tiles != nil:
                // Dark and Light draw their own place names, so use Apple's label-free imagery underneath.
                // (Apple's standard map kept drawing its city names too, which is why names showed up twice.)
                map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
            default:
                map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
            }
            labelsOverlay = nil
            if let t = b.tiles {
                let base = WxTileOverlay(TileSource(template: t.base, nativeMaxZ: t.maxZ, opacity: 1))
                base.canReplaceMapContent = true
                tileOpacity[ObjectIdentifier(base)] = 1
                map.insertOverlay(base, at: 0, level: .aboveRoads)
                baseOverlays = [base]
                if showLabels, let l = t.labels {
                    let labels = WxTileOverlay(TileSource(template: l, nativeMaxZ: t.maxZ, opacity: 1))
                    tileOpacity[ObjectIdentifier(labels)] = 1
                    map.addOverlay(labels, level: .aboveLabels)
                    baseOverlays.append(labels)
                    labelsOverlay = labels
                }
                // roads over the radar, for backgrounds without their own
                if showRoads, ![.roads, .topo, .vfr].contains(b) {
                    let roads = WxTileOverlay(TileSource(template: Basemap.roadsOverlay, nativeMaxZ: 18, opacity: 1))
                    tileOpacity[ObjectIdentifier(roads)] = b.isLight ? 0.8 : 0.55
                    if let l = labelsOverlay { map.insertOverlay(roads, below: l) } else { map.addOverlay(roads, level: .aboveLabels) }
                    baseOverlays.append(roads)
                }
            }
            addBorders(map, light: b.isLight || (b == .apple && !dark), borders: showBorders, counties: showCounties)
        }

        /// County, state and national lines, drawn above the radar and just under the place names.
        private func addBorders(_ map: MKMapView, light: Bool, borders: Bool, counties: Bool) {
            let ink: PColor = light ? .black : .white
            let styles: [(MKMultiPolyline, CGFloat, CGFloat)] = [
                (USBorders.provinces, light ? 0.40 : 0.45, 1.0),
                (USBorders.counties, light ? 0.22 : 0.20, 0.5),
                (USBorders.states, light ? 0.55 : 0.60, 1.3),
                (USBorders.world, light ? 0.65 : 0.70, 1.8),
                (USBorders.coast, light ? 0.50 : 0.55, 1.0),
                (USBorders.nation, light ? 0.70 : 0.75, 2.4),
            ]
            for (o, a, w) in styles {
                if (o === USBorders.counties) ? !counties : !borders { continue }
                shapes[ObjectIdentifier(o)] = GeoStyle(stroke: ink.withAlphaComponent(a), fill: .clear, fillAlpha: 0, width: w, dashed: false)
                if let labels = labelsOverlay { map.insertOverlay(o, below: labels) } else { map.addOverlay(o, level: .aboveLabels) }
                borderOverlays.append(o)
            }
            countyShown = -1
        }

        /// Fade county lines in and out with the zoom.
        private func updateCounties(_ m: MKMapView) {
            guard let r = countyRenderer else { return }
            let a = USBorders.countyAlpha(m.region.span.latitudeDelta)
            guard abs(a - countyShown) > 0.02 || (a == 0) != (countyShown == 0) else { return }
            countyShown = a
            r.alpha = a
            r.setNeedsDisplay()
        }

        /// Tap on the map: open the power outage details for the county under the finger.
        #if os(iOS)
        @objc func mapTapped(_ g: UITapGestureRecognizer) { tapped(g.location(in: map)) }
        #else
        @objc func mapTapped(_ g: NSClickGestureRecognizer) { tapped(g.location(in: map)) }
        #endif

        private func tapped(_ pt: CGPoint) {
            guard let map, parent.radar.layers.contains(.outages), let polys = geoOverlays[.outages] else { return }
            let p = MKMapPoint(map.convert(pt, toCoordinateFrom: map))
            for o in polys where Self.hit(o, p) {
                if let info = outageInfo[ObjectIdentifier(o)] { parent.onOutage?(info); return }
            }
        }

        private static func hit(_ o: MKOverlay, _ p: MKMapPoint) -> Bool {
            guard o.boundingMapRect.contains(p) else { return false }
            if let poly = o as? MKPolygon { return inside(poly, p) }
            if let multi = o as? MKMultiPolygon { return multi.polygons.contains { inside($0, p) } }
            return false
        }

        private static func inside(_ poly: MKPolygon, _ p: MKMapPoint) -> Bool {
            let pts = poly.points(), n = poly.pointCount
            guard n > 2 else { return false }
            var hit = false
            var j = n - 1
            for i in 0..<n {
                let a = pts[i], b = pts[j]
                if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { hit.toggle() }
                j = i
            }
            if hit, let holes = poly.interiorPolygons, holes.contains(where: { inside($0, p) }) { return false }
            return hit
        }

        func mapViewDidChangeVisibleRegion(_ m: MKMapView) {
            parent.sync?.moved(m)
            updateCounties(m)
            parent.radar.viewport.rect = m.visibleMapRect
            parent.radar.viewport.size = m.bounds.size
        }

        func syncOverlays() {
            guard let map else { return }
            let L = parent.radar.layers

            // radar frames (rebuilt when the frame list changes)
            let on = map.overlays.contains { $0 === radarOverlay }
            if L.contains(.radar) {
                if !on { map.addOverlay(radarOverlay, level: .aboveRoads) }
                let key = parent.radar.frames.map { $0.template + ($0.tiles ?? "") + ($0.image?.absoluteString ?? "") }.joined() + (parent.radar.hiDef ? "#hd" : "")
                if key != frameKey {
                    frameKey = key
                    let isSite = parent.radar.frames.first.map { $0.tiles != nil || $0.image != nil } ?? false
                    // new mode, or switching to / from / between single radars: start fresh
                    if parent.radar.frames.count != frameCount || isSite || wasSite || parent.radar.hiDef != wasHiDef { frameImages = [:]; shownFrame = -1 }
                    wasHiDef = parent.radar.hiDef
                    wasSite = isSite
                    frameCount = parent.radar.frames.count
                    parent.radar.isReady = { [weak self] i in self?.frameImages[i] != nil }
                    loadRadarImages()
                }
            } else if on {
                map.removeOverlay(radarOverlay)
                radarTask?.cancel(); frameImages = [:]; frameKey = ""; frameCount = 0; shownFrame = -1
                radarRenderer?.clear()
            }

            // tile layers
            for layer in MapLayer.allCases where layer != .radar {
                guard let src = layer.tiles else { continue }
                let want = L.contains(layer)
                if want, tileOverlays[layer] == nil {
                    let o = WxTileOverlay(src)
                    tileOverlays[layer] = o
                    tileOpacity[ObjectIdentifier(o)] = src.opacity
                    if src.above { map.addOverlay(o, level: .aboveLabels) }
                    else if let base = baseOverlays.first { map.insertOverlay(o, above: base) }   // just above the base map, under the radar
                    else { map.insertOverlay(o, at: 0, level: .aboveRoads) }
                } else if !want, let o = tileOverlays[layer] {
                    map.removeOverlay(o)
                    tileOverlays[layer] = nil
                    tileOpacity[ObjectIdentifier(o)] = nil
                }
            }

            // shape and point layers
            for layer in MapLayer.allCases where layer.tiles == nil && layer != .radar && layer != .traffic && layer != .windFlow {
                let want = L.contains(layer)
                let have = geoOverlays[layer] != nil || geoPoints[layer] != nil
                if want, !have, !geoLoading.contains(layer) {
                    geoLoading.insert(layer)
                    Task { await load(layer) }
                } else if !want, have {
                    removeGeo(layer)
                }
            }
            // the hurricane tracker draws cones as tiles plus storm markers
            if L.contains(.hurricanes), geoPoints[.hurricanes] == nil, !geoLoading.contains(.hurricanes) {
                geoLoading.insert(.hurricanes)
                Task { await load(.hurricanes) }
            } else if !L.contains(.hurricanes), geoPoints[.hurricanes] != nil {
                removeGeo(.hurricanes)
            }

            // ISS position updates
            if L.contains(.iss), issTimer == nil {
                issTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                    Task { await self?.load(.iss) }
                }
            } else if !L.contains(.iss), let t = issTimer {
                t.invalidate(); issTimer = nil
            }

            // Apple's own live traffic
            if map.showsTraffic != L.contains(.traffic) { map.showsTraffic = L.contains(.traffic) }

            // lightning strike markers ride along with the lightning layer
            if L.contains(.lightning), strikesTimer == nil {
                Task { await loadStrikes() }
                strikesTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { await self?.loadStrikes() } }
            } else if !L.contains(.lightning), let t = strikesTimer {
                t.invalidate(); strikesTimer = nil; map.removeAnnotations(strikes); strikes = []
                flashGen += 1; lastStrikeT = 0; recentStrikes = []
                flashTimer?.invalidate(); flashTimer = nil
                map.removeAnnotations(map.annotations.filter { $0 is FlashAnnotation })
            }
        }

        func showFrame(_ i: Int) {
            guard let r = radarRenderer else { return }
            let op = parent.radar.opacity
            if op != shownOpacity { shownOpacity = op; r.alpha = CGFloat(op); r.setNeedsDisplay() }
            guard i != shownFrame, let (img, rect) = frameImages[i] else { return }   // not loaded yet: keep the current picture
            shownFrame = i
            r.show(img, rect)
        }

        /// One radar's frames: map tiles around the site stitched into one image per frame (fixed area, so
        /// panning doesn't reload them).
        private func loadSiteImages() {
            let frames = parent.radar.frames
            let current = parent.radar.index
            let order = frames.indices.sorted { abs($0 - current) < abs($1 - current) }
            radarTask = Task { [weak self] in
                await withTaskGroup(of: (Int, (CGImage, MKMapRect)?).self) { g in
                    var next = 0
                    while next < min(3, order.count) {
                        let i = order[next]; next += 1
                        let f = frames[i]
                        g.addTask { (i, await Coordinator.siteImage(f)) }
                    }
                    for await (i, res) in g {
                        if Task.isCancelled { break }
                        if let res {
                            await MainActor.run {
                                guard let self else { return }
                                self.frameImages[i] = res
                                if i == self.parent.radar.index { self.shownFrame = -1; self.showFrame(i) }
                            }
                        }
                        if next < order.count {
                            let j = order[next]; next += 1
                            let f = frames[j]
                            g.addTask { (j, await Coordinator.siteImage(f)) }
                        }
                    }
                }
            }
        }

        /// A Doppler frame's picture: one ready-made image (tilts, dual-pol...) or stitched map tiles.
        nonisolated static func siteImage(_ f: RadarService.Frame) async -> (CGImage, MKMapRect)? {
            if let u = f.image, let b = f.bounds, b.count == 4 {
                guard let img = await fetchImage(u) else { return nil }
                let tl = MKMapPoint(CLLocationCoordinate2D(latitude: b[3], longitude: b[0]))
                let br = MKMapPoint(CLLocationCoordinate2D(latitude: b[1], longitude: b[2]))
                return (img, MKMapRect(x: tl.x, y: tl.y, width: br.x - tl.x, height: br.y - tl.y))
            }
            return await stitch(f.tiles ?? "", center: f.center ?? .init())
        }

        /// Downloads the zoom-8 tiles covering about 260 km around a radar and joins them into one image.
        nonisolated static func stitch(_ template: String, center: CLLocationCoordinate2D, radiusKm: Double = 260, z: Int = 8) async -> (CGImage, MKMapRect)? {
            let ts = MKMapSize.world.width / Double(1 << z)
            let c = MKMapPoint(center), rad = radiusKm * 1000 * MKMapPointsPerMeterAtLatitude(center.latitude)
            let x0 = Int(((c.x - rad) / ts).rounded(.down)), x1 = Int(((c.x + rad) / ts).rounded(.down))
            let y0 = Int(((c.y - rad) / ts).rounded(.down)), y1 = Int(((c.y + rad) / ts).rounded(.down))
            let cols = x1 - x0 + 1, rows = y1 - y0 + 1
            guard cols > 0, rows > 0, cols * rows <= 36,
                  let ctx = CGContext(data: nil, width: cols * 256, height: rows * 256, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            var got = 0
            await withTaskGroup(of: (Int, Int, CGImage?).self) { g in
                for x in x0...x1 {
                    for y in y0...y1 {
                        let u = URL(string: template.replacingOccurrences(of: "{z}", with: String(z))
                            .replacingOccurrences(of: "{x}", with: String(x)).replacingOccurrences(of: "{y}", with: String(y)))
                        g.addTask { (x, y, await fetchImage(u)) }
                    }
                }
                for await (x, y, img) in g {
                    guard let img else { continue }
                    got += 1
                    ctx.draw(img, in: CGRect(x: (x - x0) * 256, y: (rows - 1 - (y - y0)) * 256, width: 256, height: 256))
                }
            }
            guard got > 0, let out = ctx.makeImage() else { return nil }
            return (out, MKMapRect(x: Double(x0) * ts, y: Double(y0) * ts, width: Double(cols) * ts, height: Double(rows) * ts))
        }

        nonisolated static func radarImage(_ url: URL?, hiDef: Bool) async -> CGImage? {
            guard let img = await fetchImage(url) else { return nil }
            return hiDef ? (Self.hiDef(img) ?? img) : img
        }


        /// Hi-Def look, as close to MyRadar as we can get:
        ///  1. drop the light-blue returns (about 5 to 15 dBZ: drizzle, clutter, speckle) and the gray clear-air returns
        ///  2. remove leftover isolated specks (pixels with almost no neighbours)
        ///  3. blur colours and edges, then sharpen the edge back up, so storms become smooth rounded
        ///     shapes with soft colour blending instead of pixel blocks.
        nonisolated static func hiDef(_ img: CGImage) -> CGImage? {
            let w = img.width, h = img.height
            guard w > 4, h > 4,
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let data = ctx.data else { return nil }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
            let n = w * h
            // 1. light blue out
            for k in 0..<n {
                let i = k * 4
                let mx = max(p[i], p[i + 1], p[i + 2]), mn = min(p[i], p[i + 1], p[i + 2])
                if p[i + 3] > 0 && ((p[i] < 90 && p[i + 2] > 130 && Int(p[i + 2]) > Int(p[i + 1]) - 40)
                    || (Int(mx) - Int(mn) < 80 && mx < 235)) {   // also the gray-blue clear-air returns
                    p[i] = 0; p[i + 1] = 0; p[i + 2] = 0; p[i + 3] = 0
                }
            }
            // 2. despeckle: clear pixels with fewer than 3 filled neighbours (two passes)
            var filled = [UInt8](repeating: 0, count: n)
            for _ in 0..<2 {
                for k in 0..<n { filled[k] = p[k * 4 + 3] > 0 ? 1 : 0 }
                for y in 1..<(h - 1) {
                    let row = y * w
                    for x in 1..<(w - 1) {
                        let k = row + x
                        guard filled[k] == 1 else { continue }
                        let c = Int(filled[k - w - 1]) + Int(filled[k - w]) + Int(filled[k - w + 1]) + Int(filled[k - 1])
                            + Int(filled[k + 1]) + Int(filled[k + w - 1]) + Int(filled[k + w]) + Int(filled[k + w + 1])
                        if c < 3 { let i = k * 4; p[i] = 0; p[i + 1] = 0; p[i + 2] = 0; p[i + 3] = 0 }
                    }
                }
            }
            guard let cleaned = ctx.makeImage() else { return nil }
            // 3. smooth: blur, then firm up the alpha so edges are smooth curves rather than a haze
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            let blurred = CIImage(cgImage: cleaned).clampedToExtent().applyingGaussianBlur(sigma: 2.6)
            let firmed = blurred.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1.9),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: -0.32),
            ]).cropped(to: rect)
            return radarCIContext.createCGImage(firmed, from: rect)
        }

        nonisolated static func fetchImage(_ url: URL?) async -> CGImage? {
            guard let url, let data = try? await WxTileOverlay.session.data(from: url).0,
                  let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }

        /// Download every frame's image for the area on screen (plus a margin so small pans don't need a reload).
        func loadRadarImages() {
            guard let map, parent.radar.layers.contains(.radar), !parent.radar.frames.isEmpty else { return }
            radarTask?.cancel()
            if let f0 = parent.radar.frames.first, f0.tiles != nil || f0.image != nil {   // one radar: fixed area, no need to reload after panning
                if frameImages.count < parent.radar.frames.count { loadSiteImages() }
                return
            }
            let v = map.visibleMapRect
            let r = v.insetBy(dx: -v.size.width * 0.3, dy: -v.size.height * 0.3).intersection(MKMapRect.world)
            guard !r.isNull, r.size.width > 0, r.size.height > 0 else { return }
            // corners in Web Mercator meters for the WMS request
            let nw = MKMapPoint(x: r.minX, y: r.minY).coordinate, se = MKMapPoint(x: r.maxX, y: r.maxY).coordinate
            func mx(_ lon: Double) -> Double { lon * 20037508.342789244 / 180 }
            func my(_ lat: Double) -> Double { let l = min(85, max(-85, lat)) * .pi / 180; return log(tan(.pi / 4 + l / 2)) * 6378137 }
            let bbox = String(format: "%.0f,%.0f,%.0f,%.0f", mx(nw.longitude), my(se.latitude), mx(se.longitude), my(nw.latitude))
            let aspect = r.size.width / r.size.height
            let side = parent.radar.mode == .history ? 1600.0 : 2048.0
            let w = Int(aspect >= 1 ? side : side * aspect), h = Int(aspect >= 1 ? side / aspect : side)
            let frames = parent.radar.frames
            let current = parent.radar.index
            // newest / current frame first, so something useful shows right away
            let order = frames.indices.sorted { abs($0 - current) < abs($1 - current) }
            let hd = parent.radar.hiDef
            radarTask = Task { [weak self] in
                await withTaskGroup(of: (Int, CGImage?).self) { g in
                    var next = 0
                    let url: (Int) -> URL? = { i in
                        URL(string: frames[i].template.replacingOccurrences(of: "{bbox}", with: bbox)
                            .replacingOccurrences(of: "{w}", with: String(w)).replacingOccurrences(of: "{h}", with: String(h)))
                    }
                    while next < min(8, order.count) {   // a few at a time
                        let i = order[next], u = url(i); next += 1
                        g.addTask { (i, await Coordinator.radarImage(u, hiDef: hd)) }
                    }
                    for await (i, img) in g {
                        if Task.isCancelled { break }
                        if let img {
                            await MainActor.run {
                                guard let self else { return }
                                self.frameImages[i] = (img, r)
                                if i == self.parent.radar.index { self.shownFrame = -1; self.showFrame(i) }
                            }
                        }
                        if next < order.count {
                            let j = order[next], u = url(j); next += 1
                            g.addTask { (j, await Coordinator.radarImage(u, hiDef: hd)) }
                        }
                    }
                }
            }
        }

        // MARK: loading
        private func removeGeo(_ layer: MapLayer) {
            guard let map else { return }
            if let o = geoOverlays[layer] { map.removeOverlays(o); o.forEach { shapes[ObjectIdentifier($0)] = nil } }
            if let p = geoPoints[layer] { map.removeAnnotations(p) }
            geoOverlays[layer] = nil; geoPoints[layer] = nil
        }

        /// Put a layer's new shapes and points on the map, replacing its old ones.
        @MainActor private func put(_ layer: MapLayer, _ overlays: [MKOverlay], _ points: [WxPoint]) {
            guard let map, parent.radar.layers.contains(layer) else { return }
            removeGeo(layer)
            if !overlays.isEmpty { map.addOverlays(overlays, level: .aboveLabels) }
            map.addAnnotations(points)
            geoOverlays[layer] = overlays
            geoPoints[layer] = points
        }

        private static func get(_ url: URL) async -> Data? {
            var req = URLRequest(url: url)
            req.setValue(AppConfig.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("application/geo+json, application/json, text/plain", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 30
            return try? await URLSession.shared.data(for: req).0
        }
        private static func json(_ url: URL) async -> Any? {
            guard let d = await get(url) else { return nil }
            return try? JSONSerialization.jsonObject(with: d)
        }

        @MainActor private func load(_ layer: MapLayer) async {
            defer { geoLoading.remove(layer) }
            switch layer {
            case .fronts: await loadFronts()
            case .hurricanes: await loadStorms()
            case .iss: await loadISS()
            case .buoys: await loadBuoys()
            case .cams: await loadCams()
            case .sites: await loadSites()
            case _ where layer.followsView: await loadView(layer)
            default: await loadGeo(layer)
            }
        }

        @MainActor private func loadGeo(_ layer: MapLayer) async {
            var overlays: [MKOverlay] = []
            var points: [WxPoint] = []
            for url in layer.geojson {
                guard let data = await Self.get(url), let objs = try? MKGeoJSONDecoder().decode(data) else { continue }
                for case let f as MKGeoJSONFeature in objs {
                    let p = Self.props(f)
                    // G-AIRMETs come as snapshots every 3 hours; show the current one
                    if layer == .airmets, p["forecast"] != nil, Self.str(p["forecast"]) != "0" { continue }
                    for g in f.geometry {
                        if let pt = g as? MKPointAnnotation {
                            if let w = Self.point(layer, p, pt.coordinate) { points.append(w) }
                        } else if let o = g as? MKOverlay {
                            shapes[ObjectIdentifier(o)] = Self.shape(layer, p)
                            if layer == .outages {
                                outageInfo[ObjectIdentifier(o)] = OutageArea(county: Self.str(p["county"]), state: Self.str(p["state"]),
                                                                             affected: Int(Self.num(p["metersaffected"]) ?? 0))
                            }
                            overlays.append(o)
                        }
                    }
                }
            }
            put(layer, overlays, points)
        }

        // Surface fronts and highs/lows from the WPC coded analysis (same parser as the website).
        @MainActor private func loadFronts() async {
            guard let url = URL(string: "https://www.wpc.ncep.noaa.gov/basicwx/coded_srp.txt"),
                  let d = await Self.get(url), let txt = String(data: d, encoding: .utf8) else { return }
            var items: [(type: String, toks: [String])] = []
            var cur: Int? = nil
            var valid = false
            for raw in txt.components(separatedBy: .newlines) {
                let l = raw.trimmingCharacters(in: .whitespaces)
                if l.isEmpty { cur = nil; continue }
                if l.range(of: #"VALID\s+\d{12}Z"#, options: .regularExpression) != nil { if valid { break }; valid = true }
                let parts = l.split(separator: " ").map(String.init)
                if let first = parts.first, ["HIGHS", "LOWS", "COLD", "WARM", "STNRY", "OCFNT", "TROF"].contains(first) {
                    items.append((first, Array(parts.dropFirst())))
                    cur = items.count - 1
                } else if let c = cur, l.first?.isNumber == true {
                    items[c].toks += parts
                } else {
                    cur = nil
                }
            }
            func pt(_ s: String) -> CLLocationCoordinate2D? {
                let latD = s.count >= 6 ? 3 : 2
                guard s.count > latD, let la = Double(s.prefix(latD)), let lo = Double(s.dropFirst(latD)) else { return nil }
                return CLLocationCoordinate2D(latitude: la / 10, longitude: -lo / 10)
            }
            var overlays: [MKOverlay] = []
            var points: [WxPoint] = []
            for it in items {
                if it.type == "HIGHS" || it.type == "LOWS" {
                    let hi = it.type == "HIGHS"
                    var i = 0
                    while i + 1 < it.toks.count {
                        if let c = pt(it.toks[i + 1]) {
                            points.append(WxPoint(c, title: hi ? "High pressure" : "Low pressure", subtitle: "\(it.toks[i]) mb",
                                                  color: hi ? .hex("#2563eb") : .hex("#dc2626"), size: 0, layer: .fronts,
                                                  label: "\(hi ? "H" : "L") \(it.toks[i])", darkText: false))
                        }
                        i += 2
                    }
                } else {
                    var coords = it.toks.compactMap(pt)
                    guard coords.count > 1 else { continue }
                    let line = MKPolyline(coordinates: &coords, count: coords.count)
                    let c: String = it.type == "COLD" ? "#3b82f6" : it.type == "WARM" || it.type == "STNRY" ? "#ef4444" : it.type == "OCFNT" ? "#a855f7" : "#f59e0b"
                    shapes[ObjectIdentifier(line)] = GeoStyle(stroke: .hex(c), fill: .clear, fillAlpha: 0, width: it.type == "TROF" ? 2 : 3.5,
                                                              dashed: it.type == "TROF" || it.type == "STNRY")
                    overlays.append(line)
                }
            }
            put(.fronts, overlays, points)
        }

        // Active tropical systems from the National Hurricane Center.
        @MainActor private func loadStorms() async {
            guard let url = URL(string: "https://www.nhc.noaa.gov/CurrentStorms.json"),
                  let j = await Self.json(url) as? [String: Any] else { put(.hurricanes, [], []); return }
            let storms = j["activeStorms"] as? [[String: Any]] ?? []
            let pts: [WxPoint] = storms.compactMap { s in
                guard let la = Self.num(s["latitudeNumeric"]), let lo = Self.num(s["longitudeNumeric"]) else { return nil }
                let cls = Self.str(s["classification"])
                let kind = cls == "HU" ? "Hurricane" : cls == "TS" ? "Tropical Storm" : cls == "TD" ? "Tropical Depression" : "Tropical System"
                let mph = Int(((Self.num(s["intensity"]) ?? 0) * 1.15078).rounded())
                return WxPoint(.init(latitude: la, longitude: lo), title: "\(kind) \(Self.str(s["name"]))",
                               subtitle: "Winds \(mph) mph, \(Self.str(s["pressure"])) mb", color: .hex("#ef4444"), size: 0,
                               layer: .hurricanes, label: "🌀 \(Self.str(s["name"]))", darkText: false)
            }
            put(.hurricanes, [], pts)
        }

        @MainActor private func loadISS() async {
            guard let url = URL(string: "https://api.wheretheiss.at/v1/satellites/25544"),
                  let j = await Self.json(url) as? [String: Any],
                  let la = Self.num(j["latitude"]), let lo = Self.num(j["longitude"]) else { return }
            let alt = Int(((Self.num(j["altitude"]) ?? 0) * 0.621).rounded())
            let spd = Int(((Self.num(j["velocity"]) ?? 0) * 0.621).rounded())
            put(.iss, [], [WxPoint(.init(latitude: la, longitude: lo), title: "International Space Station",
                                   subtitle: "Altitude \(alt) mi, \(spd.formatted()) mph", color: .hex("#7c3aed"), size: 0,
                                   layer: .iss, label: "🛰️ ISS", darkText: false)])
        }

        // Live NDBC buoys (one text file holds every station's latest report).
        @MainActor private func loadBuoys() async {
            guard let url = URL(string: "https://www.ndbc.noaa.gov/data/latest_obs/latest_obs.txt"),
                  let d = await Self.get(url), let txt = String(data: d, encoding: .utf8) else { return }
            let now = Date()
            var pts: [WxPoint] = []
            for line in txt.components(separatedBy: .newlines) where !line.hasPrefix("#") {
                let c = line.split(separator: " ").map(String.init)
                guard c.count >= 19, let la = Double(c[1]), let lo = Double(c[2]) else { continue }
                var comps = DateComponents()
                comps.year = Int(c[3]); comps.month = Int(c[4]); comps.day = Int(c[5]); comps.hour = Int(c[6]); comps.minute = Int(c[7])
                comps.timeZone = TimeZone(identifier: "UTC")
                if let t = Calendar(identifier: .gregorian).date(from: comps), now.timeIntervalSince(t) > 6 * 3600 { continue }
                let wv = Double(c[11]), ws = Double(c[9]), wt = Double(c[18])
                let ft = wv.map { Int(($0 * 3.28084).rounded()) }
                var sub: [String] = []
                if let wv { sub.append(imperial ? "Waves \(Int((wv * 3.28084).rounded())) ft" : String(format: "Waves %.1f m", wv)) }
                if let ws { sub.append("Wind \(Int((ws * 1.94384).rounded())) kn") }
                if let wt { sub.append("Water \(Int(imperial ? wt * 9 / 5 + 32 : wt))°") }
                let col = Self.waveColor(wv)
                pts.append(WxPoint(.init(latitude: la, longitude: lo), title: "Buoy \(c[0])", subtitle: sub.joined(separator: ", "),
                                   color: col, size: 9, layer: .buoys,
                                   label: wv == nil ? nil : (imperial ? "\(ft ?? 0)'" : String(format: "%.1fm", wv ?? 0))))
            }
            put(.buoys, [], pts)
        }

        @MainActor private func loadSites() async {
            let cur = parent.radar.site?.id
            let pts = await LiveData.radarSites().map { s in
                // a tiny radar dish instead of the station name (the name shows when you tap it)
                WxPoint(.init(latitude: s.lat, longitude: s.lon), title: "\(s.id) · \(s.name)", subtitle: "NEXRAD Doppler radar",
                        color: s.id == cur ? .hex("#a78bfa") : .hex("#c4b5fd"), size: s.id == cur ? 18 : 13, layer: .sites)
            }
            put(.sites, [], pts)
        }

        @MainActor private func loadCams() async {
            let pts = await LiveData.buoyCams().map { c in
                WxPoint(.init(latitude: c.lat, longitude: c.lon), title: c.name, subtitle: c.time, color: .hex("#0ea5e9"), size: 0,
                        layer: .cams, label: "📷", darkText: false, link: c.url)
            }
            put(.cams, [], pts)
        }

        /// Value labels for the area on screen: temperatures, winds, air quality, waves, airports.
        @MainActor private func loadView(_ layer: MapLayer) async {
            guard let map else { return }
            let r = map.region
            if layer == .aviation {
                guard r.span.latitudeDelta < 20 else { put(.aviation, [], []); return }
                let s = r.center.latitude - r.span.latitudeDelta / 2, n = r.center.latitude + r.span.latitudeDelta / 2
                let w = r.center.longitude - r.span.longitudeDelta / 2, e = r.center.longitude + r.span.longitudeDelta / 2
                guard let url = URL(string: String(format: "https://aviationweather.gov/api/data/metar?bbox=%.2f,%.2f,%.2f,%.2f&format=geojson", s, w, n, e)),
                      let data = await Self.get(url), let objs = try? MKGeoJSONDecoder().decode(data) else { return }
                var pts: [WxPoint] = []
                for case let f as MKGeoJSONFeature in objs {
                    let p = Self.props(f)
                    for g in f.geometry { if let pt = g as? MKPointAnnotation, let w = Self.point(.aviation, p, pt.coordinate) { pts.append(w) } }
                }
                put(.aviation, [], Array(pts.prefix(400)))
                return
            }
            var area = r
            if layer == .road, (UserDefaults.standard.string(forKey: "roadView") ?? "radius") == "radius" {
                let dLat = 60 / 69.0
                area = MKCoordinateRegion(center: parent.center, span: .init(latitudeDelta: dLat * 2,
                                          longitudeDelta: dLat * 2 / max(0.2, cos(parent.center.latitude * .pi / 180))))
            }
            let grid = Self.grid(area, cols: layer == .road ? 7 : 6, rows: 8)
            let lats = grid.map { String(format: "%.3f", $0.latitude) }.joined(separator: ",")
            let lons = grid.map { String(format: "%.3f", $0.longitude) }.joined(separator: ",")
            if layer == .road {
                guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?hourly=temperature_2m,dew_point_2m,precipitation,snowfall,weather_code&past_hours=3&forecast_hours=1&timezone=GMT&latitude=\(lats)&longitude=\(lons)"),
                      let j = await Self.json(url) else { return }
                let list: [[String: Any]] = (j as? [[String: Any]]) ?? ((j as? [String: Any]).map { [$0] } ?? [])
                var pts: [WxPoint] = []
                for (i, item) in list.enumerated() where i < grid.count {
                    guard let h = item["hourly"] as? [String: Any], let st = RoadWeather.state(h) else { continue }
                    pts.append(WxPoint(grid[i], title: "", subtitle: "", color: st.color, size: 0, layer: .road, label: st.label, darkText: st == .snow))
                }
                put(.road, [], pts)
                return
            }
            let base: String
            switch layer {
            case .aqi: base = "https://air-quality-api.open-meteo.com/v1/air-quality?current=us_aqi"
            case .waves: base = "https://marine-api.open-meteo.com/v1/marine?current=wave_height,wave_direction"
            default: base = "https://api.open-meteo.com/v1/forecast?current=temperature_2m,wind_speed_10m,wind_direction_10m"
                + (imperial ? "&temperature_unit=fahrenheit&wind_speed_unit=mph" : "")
            }
            guard let url = URL(string: "\(base)&latitude=\(lats)&longitude=\(lons)"), let j = await Self.json(url) else { return }
            let list: [[String: Any]] = (j as? [[String: Any]]) ?? ((j as? [String: Any]).map { [$0] } ?? [])
            var pts: [WxPoint] = []
            for (i, item) in list.enumerated() where i < grid.count {
                guard let c = item["current"] as? [String: Any] else { continue }
                let at = grid[i]
                switch layer {
                case .temps:
                    guard let t = Self.num(c["temperature_2m"]) else { continue }
                    let f = imperial ? t : t * 9 / 5 + 32
                    pts.append(WxPoint(at, title: "", subtitle: "", color: Self.tempColor(f), size: 0, layer: layer,
                                       label: "\(Int(t.rounded()))°", darkText: f > 20 && f < 100))
                case .winds:
                    guard let sp = Self.num(c["wind_speed_10m"]) else { continue }
                    let dir = Self.num(c["wind_direction_10m"]) ?? 0
                    let mph = imperial ? sp : sp / 1.609
                    let arrows = ["↓", "↙", "←", "↖", "↑", "↗", "→", "↘"]   // wind blows toward the arrow
                    let a = arrows[Int(((dir / 45).rounded())) % 8]
                    pts.append(WxPoint(at, title: "", subtitle: "", color: Self.windColor(mph), size: 0, layer: layer,
                                       label: "\(a) \(Int(sp.rounded()))"))
                case .aqi:
                    guard let v = Self.num(c["us_aqi"]) else { continue }
                    pts.append(WxPoint(at, title: "", subtitle: "", color: Self.aqiColor(v), size: 0, layer: layer,
                                       label: "\(Int(v.rounded())) AQI", darkText: v <= 150))
                case .waves:
                    guard let m = Self.num(c["wave_height"]) else { continue }
                    pts.append(WxPoint(at, title: "", subtitle: "", color: Self.waveColor(m), size: 0, layer: layer,
                                       label: imperial ? "\(Int((m * 3.28084).rounded()))'" : String(format: "%.1fm", m)))
                default: break
                }
            }
            put(layer, [], pts)
        }

        private static func grid(_ r: MKCoordinateRegion, cols: Int, rows: Int) -> [CLLocationCoordinate2D] {
            let s = max(-70, r.center.latitude - r.span.latitudeDelta / 2), n = min(72, r.center.latitude + r.span.latitudeDelta / 2)
            let w = r.center.longitude - r.span.longitudeDelta / 2, e = r.center.longitude + r.span.longitudeDelta / 2
            var out: [CLLocationCoordinate2D] = []
            for row in 0..<rows {
                for col in 0..<cols {
                    let lat = s + (n - s) * (Double(row) + 0.5) / Double(rows)
                    var lon = w + (e - w) * (Double(col) + 0.5) / Double(cols)
                    lon = (lon + 540).truncatingRemainder(dividingBy: 360) - 180
                    out.append(.init(latitude: lat, longitude: lon))
                }
            }
            return out
        }

        // MARK: colors
        static func tempColor(_ f: Double) -> PColor {
            let stops: [(Double, String)] = [(0, "#7c3aed"), (20, "#6366f1"), (32, "#3b82f6"), (45, "#06b6d4"), (55, "#10b981"),
                                             (65, "#84cc16"), (75, "#eab308"), (85, "#f97316"), (95, "#ef4444"), (105, "#991b1b")]
            return .hex((stops.last { f >= $0.0 } ?? stops[0]).1)
        }
        static func windColor(_ mph: Double) -> PColor {
            .hex(mph < 10 ? "#cbd5e1" : mph < 20 ? "#86efac" : mph < 30 ? "#fde047" : mph < 40 ? "#fb923c" : "#f87171")
        }
        static func aqiColor(_ v: Double) -> PColor {
            .hex(v <= 50 ? "#22c55e" : v <= 100 ? "#eab308" : v <= 150 ? "#f97316" : v <= 200 ? "#ef4444" : v <= 300 ? "#8b5cf6" : "#7f1d1d")
        }
        static func waveColor(_ m: Double?) -> PColor {
            guard let m else { return .hex("#64748b") }
            return .hex(m < 0.6 ? "#22c55e" : m < 1.2 ? "#84cc16" : m < 2 ? "#eab308" : m < 3 ? "#f97316" : "#ef4444")
        }

        // MARK: GeoJSON helpers
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

        private static func shape(_ layer: MapLayer, _ p: [String: Any]) -> GeoStyle {
            switch layer {
            case .warnings:
                let ev = str(p["event"])
                let warn = ev.contains("Warning") || ev.contains("Emergency")
                let c = alertColor(ev)
                return GeoStyle(stroke: c, fill: c, fillAlpha: warn ? 0.22 : 0.08, width: warn ? 2.5 : 1.5, dashed: !warn)
            case .spc, .hail:
                return GeoStyle(stroke: .hex(str(p["stroke"])), fill: .hex(str(p["fill"])), fillAlpha: layer == .hail ? 0.2 : 0.3, width: 1.5, dashed: layer == .hail)
            case .mcd:
                let c = PColor.hex("#22d3ee")
                return GeoStyle(stroke: c, fill: c, fillAlpha: 0.12, width: 2, dashed: true)
            case .drought:
                let colors = ["#ffff00", "#fcd37f", "#ffaa00", "#e60000", "#730000"]
                let i = Int(num(p["dm"]) ?? -1)
                let c = PColor.hex(colors.indices.contains(i) ? colors[i] : "#999999")
                return GeoStyle(stroke: c, fill: c, fillAlpha: 0.4, width: 0.5, dashed: false)
            case .outages:
                let n = num(p["metersaffected"]) ?? 0
                let c = PColor.hex(n < 50 ? "#fde68a" : n < 250 ? "#fbbf24" : n < 1000 ? "#f97316" : n < 5000 ? "#dc2626" : "#7f1d1d")
                return GeoStyle(stroke: .hex("#92400e"), fill: c, fillAlpha: 0.55, width: 0.6, dashed: false)
            case .sigmets, .airmets:
                let h = (str(p["hazard"]) + " " + str(p["airSigmetType"])).uppercased()
                let hex = h.contains("CONVECTIVE") ? "#ef4444" : h.contains("TURB") ? "#f59e0b" : h.contains("ICE") || h.contains("FZLVL") ? "#22d3ee"
                    : h.contains("IFR") ? "#a855f7" : h.contains("MT") || h.contains("MTN") ? "#a16207" : h.contains("ASH") ? "#9ca3af" : h.contains("WND") || h.contains("LLWS") ? "#84cc16" : "#f472b6"
                let c = PColor.hex(hex)
                return GeoStyle(stroke: c, fill: c, fillAlpha: layer == .sigmets ? 0.18 : 0.08, width: layer == .sigmets ? 2 : 1.5, dashed: layer == .airmets)
            case .tfrs:
                let c = PColor.hex("#ef4444")
                return GeoStyle(stroke: c, fill: c, fillAlpha: 0.15, width: 1.8, dashed: false)
            case .avalanche:
                let c = PColor.hex(str(p["color"]))
                return GeoStyle(stroke: c, fill: c, fillAlpha: 0.45, width: 1, dashed: false)
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
            case .hail:
                guard str(p["typetext"]).uppercased().contains("HAIL") else { return nil }
                let m = num(p["magnitude"]) ?? 0.75
                let color = m >= 2 ? "#dc2626" : m >= 1.5 ? "#f97316" : m >= 1 ? "#eab308" : "#22c55e"
                return WxPoint(c, title: String(format: "Hail %.2f in", m), subtitle: "\(str(p["city"])), \(str(p["st"]))",
                               color: .hex(color), size: CGFloat(min(22, 6 + m * 5)), layer: layer)
            case .quakes:
                let m = num(p["mag"]) ?? 0
                return WxPoint(c, title: String(format: "M%.1f earthquake", m), subtitle: str(p["place"]), color: .hex("#fb923c"), size: CGFloat(max(8, m * 4)), layer: layer)
            case .fires:
                var sub = ""
                if let a = num(p["IncidentSize"]) { sub = "\(Int(a).formatted()) acres" }
                if let pc = num(p["PercentContained"]) { sub += sub.isEmpty ? "\(Int(pc))% contained" : ", \(Int(pc))% contained" }
                return WxPoint(c, title: "\(str(p["IncidentName"])) Fire", subtitle: sub, color: .hex("#f97316"), size: 11, layer: layer)
            case .aviation:
                let cat = str(p["fltcat"]).uppercased()
                let color = cat == "VFR" ? "#22c55e" : cat == "MVFR" ? "#3b82f6" : cat == "IFR" ? "#ef4444" : cat == "LIFR" ? "#d946ef" : "#94a3b8"
                return WxPoint(c, title: "\(str(p["id"])) \(cat)", subtitle: str(p["rawOb"]), color: .hex(color), size: 10, layer: layer)
            default:
                return nil
            }
        }

        // MARK: lightning strikes
        @MainActor private func loadStrikes() async {
            struct R: Decodable { let f: [[Double]] }
            guard let url = URL(string: "/api/lightning", relativeTo: AppConfig.apiBase),
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
            recentStrikes = r.f.filter { $0.count >= 3 && now - $0[2] < 15 * 60_000 }
            scheduleFlashes(r.f, now: now)
            if flashTimer == nil {
                // keep the storms "alive": recent strikes in view re-flash at random, newer ones more often
                flashTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.flashTick() }
                }
            }
        }

        @MainActor private func flashTick() {
            guard let map, !recentStrikes.isEmpty else { return }
            let view = map.visibleMapRect
            let now = Date().timeIntervalSince1970 * 1000
            let inView = recentStrikes.filter { view.contains(MKMapPoint(CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]))) }
            guard !inView.isEmpty else { return }
            let count = min(3, max(1, inView.count / 120))
            for _ in 0..<count {
                // favour the newest strikes: pick the youngest of three random ones
                let s = (0..<3).map { _ in inView.randomElement()! }.max { $0[2] < $1[2] }!
                let ageMin = (now - s[2]) / 60_000
                if ageMin > 5 && Double.random(in: 0...1) < 0.6 { continue }
                let a = FlashAnnotation(CLLocationCoordinate2D(latitude: s[1], longitude: s[0]))
                map.addAnnotation(a)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak map] in map?.removeAnnotation(a) }
            }
        }

        /// Replays new strikes as flashes spread over the next minute, so the map looks live between updates.
        /// The first time, the last two minutes of strikes are replayed.
        @MainActor private func scheduleFlashes(_ f: [[Double]], now: Double) {
            guard let map else { return }
            let first = lastStrikeT == 0
            let since = first ? now - 600_000 : lastStrikeT
            let fresh = f.filter { $0.count >= 3 && $0[2] > since }
            lastStrikeT = max(lastStrikeT, f.compactMap { $0.count >= 3 ? $0[2] : nil }.max() ?? lastStrikeT)
            let view = map.visibleMapRect
            var shown = fresh.filter { view.contains(MKMapPoint(CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]))) }
            if shown.count > 150 { shown = Array(shown.shuffled().prefix(150)) }
            let gen = flashGen
            for s in shown {
                let c = CLLocationCoordinate2D(latitude: s[1], longitude: s[0])
                DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 0..<(first ? 20 : 58))) { [weak self] in
                    guard let self, self.flashGen == gen, let map = self.map else { return }
                    let a = FlashAnnotation(c)
                    map.addAnnotation(a)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak map] in map?.removeAnnotation(a) }
                }
            }
        }

        // MARK: delegate
        func mapView(_ m: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if overlay === radarOverlay {
                let r = RadarImageRenderer(overlay: overlay)
                r.alpha = CGFloat(parent.radar.opacity)
                radarRenderer = r
                shownFrame = -1
                showFrame(parent.radar.index)
                return r
            }
            if let t = overlay as? MKTileOverlay {
                let r = MKTileOverlayRenderer(tileOverlay: t)
                r.alpha = CGFloat(tileOpacity[ObjectIdentifier(t)] ?? 0.7)
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
            if overlay === USBorders.counties {
                countyRenderer = r
                countyShown = USBorders.countyAlpha(m.region.span.latitudeDelta)
                r.alpha = countyShown
            }
            if borderOverlays.contains(where: { $0 === overlay }) { r.lineJoin = .round; r.lineCap = .round }
            return r
        }

        func mapView(_ m: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is FlashAnnotation {
                let v = m.dequeueReusableAnnotationView(withIdentifier: "flash") ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "flash")
                v.annotation = annotation
                v.image = Self.glow
                v.canShowCallout = false
                v.isEnabled = false
                #if os(macOS)
                v.wantsLayer = true
                let layer = v.layer
                #else
                let layer: CALayer? = v.layer
                #endif
                // bloom quickly, then fade out
                let scale = CAKeyframeAnimation(keyPath: "transform.scale")
                scale.values = [0.2, 1.15, 1.0]; scale.keyTimes = [0, 0.25, 1]
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0, 1, 0.9, 0]; fade.keyTimes = [0, 0.12, 0.35, 1]
                let g = CAAnimationGroup()
                g.animations = [scale, fade]; g.duration = 1.1; g.isRemovedOnCompletion = false; g.fillMode = .forwards
                layer?.removeAllAnimations()
                layer?.add(g, forKey: "flash")
                return v
            }
            if let w = annotation as? WxPoint {
                let id = w.label == nil ? "wxpoint" : "wxlabel"
                let v = m.dequeueReusableAnnotationView(withIdentifier: id) ?? MKAnnotationView(annotation: w, reuseIdentifier: id)
                v.annotation = w
                if w.layer == .sites {
                    v.image = Self.dish(w.color, w.size)
                } else if let text = w.label {
                    v.image = Self.badge(text, w.color, dark: w.darkText)
                } else {
                    v.image = Self.dot(w.color, w.size)
                }
                v.canShowCallout = !(w.title ?? "").isEmpty && w.layer != .cams && w.layer != .sites
                return v
            }
            guard (annotation.title ?? nil) == "strike" else { return nil }
            let v = m.dequeueReusableAnnotationView(withIdentifier: "strike") ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "strike")
            v.annotation = annotation
            let age = Int((annotation.subtitle ?? nil) ?? "0") ?? 0
            v.image = Self.symbol(age < 5 ? "bolt.fill" : "plus", color: age < 5 ? .systemYellow : (age < 15 ? .systemOrange : PColor.systemRed.withAlphaComponent(0.7)), size: age < 5 ? 13 : 8)
            v.canShowCallout = false
            return v
        }

        func mapView(_ m: MKMapView, didSelect view: MKAnnotationView) {
            guard let w = view.annotation as? WxPoint else { return }
            if w.layer == .cams, let u = w.link {
                m.deselectAnnotation(w, animated: false)
                parent.onCamera?(w.title ?? "Buoy camera", u)
            } else if w.layer == .sites, let t = w.title, let id = t.components(separatedBy: " · ").first {
                m.deselectAnnotation(w, animated: false)
                let name = t.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
                parent.onSite?(RadarService.Site(id: id, name: name, lat: w.coordinate.latitude, lon: w.coordinate.longitude))
            }
        }

        func mapView(_ m: MKMapView, regionDidChangeAnimated animated: Bool) {
            parent.radar.viewport.rect = m.visibleMapRect
            parent.radar.viewport.size = m.bounds.size
            parent.radar.viewport.settled += 1
            parent.onCenterChange(m.centerCoordinate)
            // redraw the layers that depend on the area in view, once the map settles
            viewWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.loadRadarImages()
                for l in self.parent.radar.layers where l.followsView && !self.geoLoading.contains(l) {
                    self.geoLoading.insert(l)
                    Task { await self.load(l) }
                }
            }
            viewWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }

        // MARK: drawing helpers
        /// White bloom with a soft blue-white edge, like a lightning flash lighting up clouds.
        static let glow: PImage = {
            let size: CGFloat = 64
            let colors = [CGColor(red: 1, green: 1, blue: 1, alpha: 1), CGColor(red: 0.85, green: 0.9, blue: 1, alpha: 0.75),
                          CGColor(red: 0.7, green: 0.8, blue: 1, alpha: 0.25), CGColor(red: 0.7, green: 0.8, blue: 1, alpha: 0)] as CFArray
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.18, 0.55, 1])!
            let draw: (CGContext) -> Void = { ctx in
                let c = CGPoint(x: size / 2, y: size / 2)
                ctx.drawRadialGradient(grad, startCenter: c, startRadius: 0, endCenter: c, endRadius: size / 2, options: [])
            }
            #if os(macOS)
            return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
                if let ctx = NSGraphicsContext.current?.cgContext { draw(ctx) }
                return true
            }
            #else
            return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { draw($0.cgContext) }
            #endif
        }()

        #if os(macOS)
        static func symbol(_ name: String, color: NSColor, size: CGFloat) -> NSImage? {
            let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .bold).applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        }
        /// Doppler site: a NEXRAD radome on its tower, on a dark disc ringed in the layer color.
        static func dish(_ color: NSColor, _ size: CGFloat) -> NSImage? {
            let d = size * 1.7
            return NSImage(size: NSSize(width: d, height: d), flipped: false) { r in
                let disc = NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5))
                let current = size > 15   // the radar being shown: filled purple, white ring
                (current ? NSColor(red: 0.55, green: 0.36, blue: 0.96, alpha: 1) : NSColor(white: 0.06, alpha: 0.9)).setFill(); disc.fill()
                (current ? NSColor.white : color).setStroke(); disc.lineWidth = 1.6; disc.stroke()
                if let img = NSImage(named: "RadomeTower") {
                    let ir = r.insetBy(dx: d * 0.2, dy: d * 0.18)
                    let tinted = NSImage(size: ir.size, flipped: false) { tr in
                        img.draw(in: tr); NSColor.white.set(); tr.fill(using: .sourceAtop); return true
                    }
                    tinted.draw(in: ir)
                }
                return true
            }
        }
        static func dot(_ color: NSColor, _ size: CGFloat) -> NSImage {
            NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
                color.setFill(); NSColor.black.withAlphaComponent(0.7).setStroke()
                let p = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)); p.lineWidth = 1.2; p.fill(); p.stroke()
                return true
            }
        }
        static func badge(_ text: String, _ color: NSColor, dark: Bool) -> NSImage {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: dark ? NSColor.black : NSColor.white]
            let sz = (text as NSString).size(withAttributes: attrs)
            let w = ceil(sz.width) + 12, h = ceil(sz.height) + 4
            return NSImage(size: NSSize(width: w, height: h), flipped: true) { r in
                let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: h / 2, yRadius: h / 2)
                color.setFill(); path.fill()
                NSColor.black.withAlphaComponent(0.45).setStroke(); path.lineWidth = 1; path.stroke()
                (text as NSString).draw(at: NSPoint(x: 6, y: 2), withAttributes: attrs)
                return true
            }
        }
        #else
        static func symbol(_ name: String, color: UIColor, size: CGFloat) -> UIImage? {
            UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .bold))?
                .withTintColor(color, renderingMode: .alwaysOriginal)
        }
        /// Doppler site: a NEXRAD radome on its tower, on a dark disc ringed in the layer color.
        static func dish(_ color: UIColor, _ size: CGFloat) -> UIImage? {
            let d = size * 1.7
            return UIGraphicsImageRenderer(size: CGSize(width: d, height: d)).image { _ in
                let r = CGRect(x: 0, y: 0, width: d, height: d)
                let disc = UIBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5))
                let current = size > 15   // the radar being shown: filled purple, white ring
                (current ? UIColor(red: 0.55, green: 0.36, blue: 0.96, alpha: 1) : UIColor(white: 0.06, alpha: 0.9)).setFill(); disc.fill()
                (current ? UIColor.white : color).setStroke(); disc.lineWidth = 1.6; disc.stroke()
                UIImage(named: "RadomeTower")?.withTintColor(.white, renderingMode: .alwaysOriginal)
                    .draw(in: r.insetBy(dx: d * 0.2, dy: d * 0.18))
            }
        }
        static func dot(_ color: UIColor, _ size: CGFloat) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
                let r = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: 1, dy: 1)
                color.setFill(); UIColor.black.withAlphaComponent(0.7).setStroke()
                let p = UIBezierPath(ovalIn: r); p.lineWidth = 1.2; p.fill(); p.stroke()
            }
        }
        static func badge(_ text: String, _ color: UIColor, dark: Bool) -> UIImage {
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 12), .foregroundColor: dark ? UIColor.black : UIColor.white]
            let sz = (text as NSString).size(withAttributes: attrs)
            let w = ceil(sz.width) + 12, h = ceil(sz.height) + 4
            return UIGraphicsImageRenderer(size: CGSize(width: w, height: h)).image { _ in
                let path = UIBezierPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: w - 1, height: h - 1), cornerRadius: h / 2)
                color.setFill(); path.fill()
                UIColor.black.withAlphaComponent(0.45).setStroke(); path.lineWidth = 1; path.stroke()
                (text as NSString).draw(at: CGPoint(x: 6, y: 2), withAttributes: attrs)
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

#if os(iOS)
extension RadarMap.Coordinator: UIGestureRecognizerDelegate {
    /// Let the outage tap work alongside the map's own gestures.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif

/// Keeps split-screen maps looking at the same spot: moving one moves the others.
final class MapSync {
    /// Off = each map moves on its own.
    var linked = true
    private var maps: [WeakMap] = []
    private var applying = false
    private struct WeakMap { weak var map: MKMapView? }

    func add(_ m: MKMapView) {
        maps.removeAll { $0.map == nil }
        if let lead = maps.first?.map { m.setCamera(lead.camera, animated: false) }
        maps.append(WeakMap(map: m))
    }

    func moved(_ m: MKMapView) {
        guard linked, !applying else { return }
        applying = true
        for w in maps { if let o = w.map, o !== m { o.setCamera(m.camera, animated: false) } }
        applying = false
    }
}
