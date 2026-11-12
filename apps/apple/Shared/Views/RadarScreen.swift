import SwiftUI
import MapKit

/// The main radar screen: map, crosshair, weather card, and a dock with the loop controls.
struct RadarScreen: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var store: Store
    @StateObject private var radar = RadarController()
    @State private var recenter = 0
    @State private var showLayers = false
    @State private var camera: BuoyCamSheet?
    @State private var showPlans = false
    @State private var tappedSite: RadarService.Site?
    @State private var outage: OutageArea?
    @State private var snap: SnapItem?
    // Map border settings (Radar Settings and Advanced Settings); reading them here redraws the map when they change.
    @AppStorage("mapBorders") private var borders = true
    @AppStorage("mapCounties") private var counties = true
    var compact = true   // phone layout (card on top, dock at the bottom)
    // Split screen (Pro): a second radar under the first, panning and zooming together
    /// Split screen: off, linked (both maps move together), or independent. Each tap of the button steps through.
    private var splitMode: Int { state.splitMode }
    private var split: Bool { splitMode > 0 }
    @State private var showMapOptions = false
    /// Split screen: share of the height for the top radar (drag the divider), and where a drag started.
    @State private var splitFraction: CGFloat = 0.5
    @State private var dragStart: CGFloat?
    @AppStorage("mapLabels") private var mapLabels = true
    @AppStorage("mapRoads") private var mapRoads = false
    @State private var sync = MapSync()
    @StateObject private var radar2 = RadarController(raw: false)

    var body: some View {
        maps
        .overlay(alignment: compact ? .top : .topLeading) { cardOverlay }
        .onChange(of: state.splitMode) { old, m in
            sync.linked = m != 2
            radar2.follower = true
            if old == 0 && m > 0 { openSplitDefaults() }
            if old > 0 && m == 0 { saveSplit() }
            radar2.show(time: radar.currentTime)
        }
        .overlay(alignment: .bottom) { dockOverlay }
        .task { await radar.load() }
        .onChange(of: state.place) { _, _ in recenter += 1 }
        .sheet(isPresented: $showLayers) { LayersSheet(radar: radar).environmentObject(store).environmentObject(state) }
        .sheet(item: $camera) { $0 }
        .sheet(item: $outage) { OutageSheet(area: $0) }
        .sheet(item: $snap) { SnapshotSheet(item: $0) }
        .sheet(isPresented: $showMapOptions) { MapOptionsSheet(radar: radar).environmentObject(store) }
        .sheet(isPresented: $showPlans) { PlansView().environmentObject(store) }
        .confirmationDialog(
            siteDialogTitle,
            isPresented: siteDialogPresented,
            titleVisibility: .visible
        ) {
            siteDialogActions
        }
    }

    /// The radar map, plus the second radar below it in split screen.
    private var maps: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ZStack {
                    let _ = (borders, counties, mapLabels, mapRoads)   // redraw the map when a map setting changes
                    RadarMap(radar: radar, center: state.place.coordinate, recenterToken: recenter,
                             onCenterChange: { c in Task { @MainActor in state.mapCentered(c) } },
                             onCamera: { name, url in camera = BuoyCamSheet(title: name, url: url) },
                             onSite: { s in tappedSite = s },
                             onOutage: { o in outage = o },
                             sync: sync)
                    .ignoresSafeArea(edges: split ? [.top, .horizontal] : .all)
                    if radar.layers.contains(.windFlow) {
                        WindFlowView(viewport: radar.viewport).ignoresSafeArea()
                    }
                    Crosshair()
                }
                .overlay(alignment: .bottom) {
                    if split { PaneBar(radar: radar) { loopMenu }.padding(10) }
                }
                .frame(height: split ? max(120, geo.size.height * splitFraction) : nil)
                if split {
                    splitDivider(geo.size.height)
                    SplitPane(radar: radar2, sync: sync, center: state.place.coordinate, driver: radar,
                              onLayers: { showLayers = true },
                              onSnap: { if let cg = radar2.snapshot?() { snap = SnapItem(image: cg, place: (state.center ?? state.place).name) } })
                        .transition(.move(edge: .bottom))
                }
            }
        }
        .onChange(of: radar.index) { _, _ in if split { radar2.show(time: radar.currentTime) } }
        .onChange(of: radar2.frames.count) { _, _ in radar2.show(time: radar.currentTime); if split { saveSplit() } }
        .onChange(of: radar2.layers) { _, _ in if split { saveSplit() } }
        .onChange(of: radar.hiDef) { _, _ in if split { saveSplit() } }
        .onChange(of: radar2.hiDef) { _, _ in if split { saveSplit() } }
        .onChange(of: radar.mode) { _, _ in if split { saveSplit() } }
        .onChange(of: radar.site) { _, _ in if split { saveSplit() } }
        .onChange(of: radar2.mode) { _, _ in if split { saveSplit() } }
        .onChange(of: radar2.site) { _, _ in if split { saveSplit() } }
    }

    /// Opening split screen: the top keeps whatever you were already looking at; the bottom opens
    /// the way you last left it (infrared satellite the first time).
    private func openSplitDefaults() {
        let saved = UserDefaults.standard.dictionary(forKey: "splitLast")
        // bottom
        if let s = Self.site(saved?["bottomSite"]) {
            radar2.layers = [.radar, .sites]; radar2.setSite(s)
        } else if let sat = MapLayer(rawValue: saved?["bottomSat"] as? String ?? ""), sat.isSatellite {
            if radar2.site != nil { radar2.setSite(nil) }
            radar2.layers = [sat]
        } else if saved != nil {
            radar2.layers = [.radar]
            radar2.hiDef = saved?["bottomHiDef"] as? Bool ?? true
            radar2.setMode(RadarMode(rawValue: saved?["bottomMode"] as? String ?? "") ?? .recent)
        } else {
            if radar2.site != nil { radar2.setSite(nil) }
            radar2.layers = [.satIR]
        }
    }

    /// Remember both halves for next time split screen opens.
    private func saveSplit() {
        var v: [String: Any] = ["topHiDef": radar.hiDef, "topMode": radar.mode.rawValue,
                                "bottomHiDef": radar2.hiDef, "bottomMode": radar2.mode.rawValue]
        if let s = radar.site { v["topSite"] = Self.pack(s) }
        if let s = radar2.site { v["bottomSite"] = Self.pack(s) }
        else if !radar2.layers.contains(.radar), let sat = radar2.layers.first(where: { $0.isSatellite }) { v["bottomSat"] = sat.rawValue }
        UserDefaults.standard.set(v, forKey: "splitLast")
    }

    private static func pack(_ s: RadarService.Site) -> [String: Any] {
        ["id": s.id, "name": s.name, "lat": s.lat, "lon": s.lon, "product": s.product, "tilt": s.tilt]
    }
    private static func site(_ any: Any?) -> RadarService.Site? {
        guard let d = any as? [String: Any], let id = d["id"] as? String, let lat = d["lat"] as? Double, let lon = d["lon"] as? Double else { return nil }
        var s = RadarService.Site(id: id, name: d["name"] as? String ?? id, lat: lat, lon: lon)
        s.product = d["product"] as? String ?? "ref"
        s.tilt = d["tilt"] as? Int ?? 0
        return s
    }

    /// The line between the two radars: drag it to resize, tap the tag to link or unlink, X to close.
    private func splitDivider(_ total: CGFloat) -> some View {
        Rectangle().fill(Kit.purple).frame(height: 3)
            .contentShape(Rectangle().inset(by: -14))
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        if dragStart == nil { dragStart = splitFraction }
                        splitFraction = min(0.8, max(0.2, (dragStart ?? 0.5) + v.translation.height / max(1, total)))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            #if os(macOS)
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            #endif
            .overlay {
                HStack(spacing: 8) {
                    Capsule().fill(.white.opacity(0.8)).frame(width: 28, height: 4)
                    Button { withAnimation(.snappy) { state.splitMode = splitMode == 1 ? 2 : 1 } } label: {
                        Label(splitMode == 1 ? "Linked" : "Independent",
                              systemImage: splitMode == 1 ? "link" : "arrow.up.and.down.and.arrow.left.and.right")
                    }
                    Button { withAnimation(.snappy) { state.splitMode = 0 } } label: { Image(systemName: "xmark") }
                        .help("Close split screen")
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Kit.purple, in: Capsule())
                .foregroundStyle(.white)
            }
            .zIndex(1)
    }

    /// Conditions card (hidden in split screen, so it's just the two radars).
    @ViewBuilder private var cardOverlay: some View {
        if !split {
            WeatherCard(onHome: { state.center = nil; state.centerForecast = nil; recenter += 1 }, tools: nil)
                .frame(maxWidth: compact ? .infinity : 420)
                .padding(12)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Ad and dock (hidden in split screen; each radar has its own bar).
    @ViewBuilder private var dockOverlay: some View {
        if !split {
            VStack(spacing: 8) {
                if store.effectivePlan == .free { AdBanner(kind: .banner) }
                dock
            }
            .padding(12)
            .frame(maxWidth: 640)
        }
    }

    // MARK: - Radar Site Dialog

    private var siteDialogTitle: String {
        tappedSite.map { "\($0.id) · \($0.name)" } ?? "Radar"
    }

    private var siteDialogPresented: Binding<Bool> {
        Binding(
            get: { tappedSite != nil },
            set: { if !$0 { tappedSite = nil } }
        )
    }

    @ViewBuilder
    private var siteDialogActions: some View {
        if let s = tappedSite {
            ForEach(RadarService.SiteProduct.allCases) { p in
                Button("\(p.title) (\(p.detail.lowercased()))") {
                    var x = s
                    x.product = p.rawValue
                    x.tilt = (radar.site?.id == s.id && p.hasTilts)
                        ? radar.site?.tilt ?? 0 : 0
                    radar.setSite(x)
                }
            }

            if radar.site != nil {
                Button("Back to Hi-Def Radar") {
                    radar.setSite(nil)
                }
            }

            Button("Cancel", role: .cancel) {}
        }
    }

    private var dock: some View {
        VStack(spacing: 8) {
            if radar.layers.contains(.radar) && radar.site == nil { RadarLegend() }
            if !radar.frames.isEmpty {
                Slider(value: Binding(get: { Double(radar.index) }, set: { radar.index = Int($0.rounded()); radar.playing = false }),
                       in: 0...Double(max(1, radar.frames.count - 1)), step: 1)
            }
            HStack(spacing: 6) {
                Image("Radome")
                if let s = radar.site {
                    Text("\(s.id) \(s.productName)").font(.subheadline.weight(.semibold))
                    Text("· \(s.name)").font(.subheadline).lineLimit(1)
                } else {
                    loopMenu
                }
                Spacer()
            }
            .foregroundStyle(.secondary)
            HStack {
                Button { radar.playing.toggle() } label: { Image(systemName: radar.playing ? "pause.fill" : "play.fill") }
                timeLabel
                Menu {
                    if let s = radar.site {
                        Button("Back to Hi-Def Radar") { radar.setSite(nil) }
                        Menu("Product") {
                            ForEach(RadarService.SiteProduct.allCases) { p in
                                Button { var x = s; x.product = p.rawValue; if !p.hasTilts { x.tilt = 0 }; radar.setSite(x) } label: {
                                    if s.kind == p { Label(p.title, systemImage: "checkmark") } else { Text(p.title) }
                                }
                            }
                        }
                        if s.kind.hasTilts {
                            Menu("Tilt (beam angle)") {
                                ForEach(0..<4, id: \.self) { t in
                                    Button { var x = s; x.tilt = t; radar.setSite(x) } label: {
                                        let name = RadarService.SiteProduct.tiltNames[t] + (t == 0 ? " (lowest)" : "")
                                        if s.tilt == t { Label(name, systemImage: "checkmark") } else { Text(name) }
                                    }
                                }
                            }
                        }
                        Divider()
                    }
                    Button {
                        if proRadar { radar.layers.insert(.sites) } else { showPlans = true }
                    } label: { Label("Doppler radar sites\(proRadar ? "" : " (Pro)")", image: "Radome") }
                    Divider()
                    ForEach(RadarMode.allCases, id: \.self) { m in
                        Button {
                            if m != .recent && !proRadar { showPlans = true } else { radar.setMode(m) }
                        } label: {
                            if radar.mode == m && radar.site == nil { Label(m.title, systemImage: "checkmark") }
                            else { Text(m == .recent ? m.title : "\(m.title)\(proRadar ? "" : " (Pro)")") }
                        }
                    }
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title3)
                }
                .fixedSize()
                .help("Past 48 hours and future radar")
                Spacer()
                tools
            }
            .buttonStyle(.borderless)
            #if os(iOS)
            .labelStyle(.iconOnly)   // room for every button on a phone
            #else
            .labelStyle(.titleAndIcon)
            #endif
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }


    /// Home, map options, layers, split screen and snapshot. In the dock on iPad and Mac;
    /// a bottom bar of their own on iPhone.
    @ViewBuilder private var tools: some View {
            Button {
                if let cg = radar.snapshot?() { snap = SnapItem(image: cg, place: (state.center ?? state.place).name) }
            } label: { Image(systemName: "camera") }
            .help("Radar snapshot")
            if !compact { splitButton }
            Button { showMapOptions = true } label: { Image(systemName: "map") }
            .help("Map options")
            Button { showLayers = true } label: { Label("Layers", systemImage: "square.3.layers.3d") }
            Button { recenter += 1; state.center = nil } label: { Label("Home", systemImage: "location") }
    }

    /// iPad and Mac: split screen button in the dock (iPhone has it in the tab bar).
    private var splitButton: some View {
            Button {
                guard store.effectivePlan >= .pro else { showPlans = true; return }
                withAnimation(.snappy) { state.splitMode = (state.splitMode + 1) % 3 }
            } label: {
                Image(systemName: splitMode == 0 ? "rectangle.split.1x2" : splitMode == 1 ? "rectangle.split.1x2.fill" : "rectangle")
                    .overlay(alignment: .topTrailing) {
                        if store.effectivePlan < .pro {
                            Text("PRO").font(.system(size: 7, weight: .heavy))
                                .padding(.horizontal, 3).padding(.vertical, 1)
                                .background(Color.purple, in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(.white)
                                .offset(x: 10, y: -7)
                        }
                    }
            }
            .help(splitMode == 0 ? "Split screen: two radars at once (Pro)" : splitMode == 1 ? "Tap again to move each map on its own" : "Close split screen")
    }

    /// iPhone: the tools in an evenly spaced row inside the conditions card.
    private var cardTools: some View {
        HStack {
            Group { tools }.frame(maxWidth: .infinity)   // Group spreads the frame to each button
        }
        .font(.title3)
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
    }

    /// Past 48 hours and future radar come with Pro or the Radar Pack.
    private var proRadar: Bool { store.hasDoppler }

    /// Tap the radar name to switch loops without opening Layers.
    private var loopMenu: some View {
        let on = radar.layers.contains(.radar)
        return Menu {
            loopButton("Hi-Def Radar", .recent, hiDef: true)
            loopButton("Standard Radar", .recent, hiDef: false)
            loopButton("Past 48 Hours", .history, hiDef: nil)
            loopButton("Future Radar", .future, hiDef: nil)
            Divider()
            Button("Radar Off") { radar.layers.remove(.radar) }
            Button { showLayers = true } label: { Label("More Loops", systemImage: "square.3.layers.3d") }
        } label: {
            HStack(spacing: 4) {
                Text(on ? (radar.mode == .recent ? (radar.hiDef ? "Hi-Def Radar" : "Standard Radar") : radar.mode.title) : "Radar Off")
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
        }
        .fixedSize()
    }

    @ViewBuilder private func loopButton(_ title: String, _ m: RadarMode, hiDef: Bool?) -> some View {
        let locked = m != .recent && !proRadar
        let current = radar.layers.contains(.radar) && radar.mode == m && (hiDef == nil || radar.hiDef == hiDef)
        Button {
            if locked { showPlans = true; return }
            radar.layers.insert(.radar)
            if let hiDef { radar.hiDef = hiDef }
            if radar.mode != m || radar.site != nil { radar.setMode(m) }
        } label: {
            if current { Label(title, systemImage: "checkmark") }
            else if locked { Label("\(title) (Pro)", systemImage: "lock.fill") }
            else { Text(title) }
        }
    }

    @ViewBuilder private var timeLabel: some View {
        if let t = radar.currentTime {
            HStack(spacing: 6) {
                if radar.currentIsFuture {
                    Text("FUTURE").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.purple.opacity(0.25), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.purple)
                }
                Text(radar.mode == .history ? t.formatted(.dateTime.weekday(.abbreviated).hour().minute()) : t.formatted(date: .omitted, time: .shortened))
                    .monospacedDigit()
            }
        } else {
            Text("--")
        }
    }
}

/// PLUS / PRO label. Hidden when the current plan already includes the feature.
struct TierBadge: View {
    var plan: Plan
    @EnvironmentObject var store: Store
    var body: some View {
        if store.effectivePlan < plan { label }
    }
    private var label: some View {
        Text(plan.name.uppercased()).font(.caption2.bold())
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background((plan == .pro ? Color.purple : Color.blue).opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(plan == .pro ? Color.purple : Color.blue)
    }
}

// MARK: - Split screen

/// The second radar in split screen, with its own loop picker. Moves with the radar above it.
struct SplitPane: View {
    @ObservedObject var radar: RadarController
    let sync: MapSync
    let center: CLLocationCoordinate2D
    /// The top radar; its play/pause and time run both halves.
    var driver: RadarController? = nil
    var onLayers: () -> Void = {}
    var onSnap: () -> Void = {}
    @EnvironmentObject var state: AppState

    var body: some View {
        RadarMap(radar: radar, center: center, recenterToken: 0, onCenterChange: { _ in }, sync: sync)
            .ignoresSafeArea(edges: [.bottom, .horizontal])
            .overlay(alignment: .bottom) { PaneBar(radar: radar, driver: driver) { PaneLoopMenu(radar: radar, bare: true) }.padding(10) }
            .overlay(alignment: .topTrailing) {
                // the conditions card (with these tools) is hidden in split screen
                HStack(spacing: 14) {
                    Button(action: onSnap) { Image(systemName: "camera") }
                    Button(action: onLayers) { Image(systemName: "square.3.layers.3d") }
                }
                .font(.headline)
                .buttonStyle(.borderless)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .padding(10)
            }
            .task { radar.follower = true; if radar.frames.isEmpty { await radar.load() } }
    }
}

/// Pick what the second radar shows: a mosaic loop, satellite, or a product from the nearest radar.
struct PaneLoopMenu: View {
    @ObservedObject var radar: RadarController
    /// Inside a PaneBar: no capsule of its own.
    var bare = false
    @EnvironmentObject var state: AppState

    private var name: String {
        if let s = radar.site { return "\(s.id) \(s.productName)" }
        if let sat = radar.layers.first(where: { $0.isSatellite }) { return sat.title.replacingOccurrences(of: "Clouds: ", with: "") }
        if !radar.layers.contains(.radar) { return "Off" }
        return radar.mode == .recent ? (radar.hiDef ? "Hi-Def Radar" : "Standard Radar") : radar.mode.title
    }

    var body: some View {
        Menu {
            Section("Radar") {
                Button("Hi-Def Radar") { mosaic(.recent, hiDef: true) }
                Button("Standard Radar") { mosaic(.recent, hiDef: false) }
                Button("Past 48 Hours") { mosaic(.history, hiDef: nil) }
                Button("Future Radar") { mosaic(.future, hiDef: nil) }
            }
            Section("Satellite") {
                ForEach([MapLayer.satColor, .satVis, .satIR, .satWV]) { l in
                    Button(l.title.replacingOccurrences(of: "Clouds: ", with: "")) { satellite(l) }
                }
            }
            Section("Nearest radar") {
                ForEach(RadarService.SiteProduct.allCases) { p in Button(p.title) { nearest(p) } }
            }
        } label: {
            HStack(spacing: 6) {
                Image("Radome").resizable().scaledToFit().frame(width: 16, height: 16)
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .padding(.horizontal, bare ? 0 : 12).padding(.vertical, bare ? 0 : 8)
            .background(bare ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.regularMaterial), in: Capsule())
        }
        .fixedSize()
    }

    private func mosaic(_ m: RadarMode, hiDef: Bool?) {
        radar.layers = [.radar]
        if let hiDef { radar.hiDef = hiDef }
        radar.setMode(m)
    }
    private func satellite(_ l: MapLayer) {
        if radar.site != nil { radar.setSite(nil) }
        radar.layers = [l]
    }
    private func nearest(_ p: RadarService.SiteProduct) {
        Task {
            guard var s = await LiveData.nearestSite(state.center ?? state.place) else { return }
            s.product = p.rawValue
            s.tilt = 0
            await MainActor.run {
                radar.layers = [.radar, .sites]
                radar.setSite(s)
            }
        }
    }
}

/// Split screen: each radar's own slim bar (picture, loop picker, time, play/pause), like the main dock but compact.
struct PaneBar<Menu2: View>: View {
    @ObservedObject var radar: RadarController
    /// When set, play/pause controls this radar (split screen's bottom half follows the top one).
    var driver: RadarController? = nil
    @ViewBuilder var picker: () -> Menu2

    private var timeText: String {
        if !radar.layers.contains(.radar) && radar.layers.contains(where: { $0.isSatellite }) { return "Latest" }
        return radar.currentTime.map { $0.formatted(date: .omitted, time: .shortened) } ?? "Loading…"
    }

    private var thumb: URL? {
        if let sat = radar.layers.first(where: { $0.isSatellite }) { return LayerThumb.tile(sat.tiles?.template) }
        return LayerThumb.radarTile
    }

    var body: some View {
        HStack(spacing: 10) {
            LayerThumb(overlay: thumb)
                .frame(width: 46, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Kit.line, lineWidth: 1))
            picker()
            Spacer(minLength: 6)
            Text(timeText)
                .font(.subheadline.monospacedDigit())
                .padding(.horizontal, 10).padding(.vertical, 5)
                .overlay(Capsule().stroke(Kit.line, lineWidth: 1))
            Button { (driver ?? radar).playing.toggle() } label: {
                Image(systemName: (driver ?? radar).playing ? "pause.fill" : "play.fill").font(.headline)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
