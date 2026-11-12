import SwiftUI

/// The Layers sheet: three pill tabs.
/// - Weather Loops: picture cards for the radar and satellite loops (tap to switch, lock = needs an upgrade)
/// - Overlays: switches for everything drawn on top (alerts, storm reports, tropics, marine...)
/// - Radars: every NEXRAD radar by state, the three nearest first, with search and an A to Z index
struct LayersSheet: View {
    @ObservedObject var radar: RadarController
    @EnvironmentObject var store: Store
    @EnvironmentObject var state: AppState

    var body: some View {
        KitSheet {
            LayersHome(radar: radar)
        }
        .environmentObject(store)
        .environmentObject(state)
    }
}

private enum LayersTab: Hashable { case loops, overlays, radars }

private struct LayersHome: View {
    @ObservedObject var radar: RadarController
    @EnvironmentObject var store: Store
    @EnvironmentObject var state: AppState
    @Environment(\.kitClose) private var close
    @AppStorage("layersTab") private var tabRaw = "loops"
    @State private var showPlans = false

    private var tab: Binding<LayersTab> {
        Binding(get: { tabRaw == "radars" ? .radars : tabRaw == "overlays" ? .overlays : .loops },
                set: { tabRaw = $0 == .radars ? "radars" : $0 == .overlays ? "overlays" : "loops" })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                KitPills(options: [(LayersTab.loops, "Loops"), (.overlays, "Overlays"), (.radars, "Radars")], selection: tab)
                if let close { KitCircleButton(icon: "xmark", action: close) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            switch tab.wrappedValue {
            case .loops: LoopsTab(radar: radar, showPlans: $showPlans)
            case .overlays: OverlaysTab(radar: radar, showPlans: $showPlans)
            case .radars: RadarsTab(radar: radar, showPlans: $showPlans)
            }
        }
        .background(Kit.page.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .sheet(isPresented: $showPlans) { PlansView().environmentObject(store) }
    }
}

// MARK: - Weather Loops

private struct LoopsTab: View {
    @ObservedObject var radar: RadarController
    @Binding var showPlans: Bool
    @EnvironmentObject var store: Store

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 12) {
                    radarCard("Hi-Def Radar", "Smooth, high-resolution radar mosaic", mode: .recent, hiDef: true, symbol: nil)
                    radarCard("Standard Radar", "The radar mosaic without smoothing filters", mode: .recent, hiDef: false, symbol: nil)
                    radarCard("Past 48 Hours", "Replay the last two days of radar", mode: .history, hiDef: nil, symbol: "clock.arrow.circlepath")
                    radarCard("Future Radar", "Short-term radar forecast from the HRRR model", mode: .future, hiDef: nil, symbol: "wand.and.stars")
                    layerCard(.satColor, "True Color Satellite", "Clouds as your eyes would see them (daytime)")
                    layerCard(.satVis, "Visible Satellite", "Sharp daytime cloud detail")
                    layerCard(.satIR, "Infrared Satellite", "Cloud-top temperatures, day and night")
                    layerCard(.satWV, "Water Vapor", "Moisture in the middle and upper air")
                    layerCard(.tempMap, "Temperature Map", "Forecast temperatures, shaded")
                    layerCard(.rainRate, "Rain Rate", "How hard it's raining right now")
                    layerCard(.rain1h, "Past Hour Rain", "Rain that fell in the last hour")
                    layerCard(.rain, "Rain Totals (24 hr)", "Rain that fell in the last day")
                    layerCard(.rain72, "Rain Totals (3 days)", "Rain that fell in the last three days")
                    layerCard(.echoTops, "Echo Tops", "How tall the storms are")
                    layerCard(.lightning, "Lightning", "Live strikes and strike density")
                    noLoopCard
                    if store.effectivePlan == .free && !store.radarPack {
                        NavigationLink { RadarPackPage() } label: { RadarPackCard() }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 96)
            }
            NavigationLink { RadarSettingsPage(radar: radar, showPlans: $showPlans) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape.fill").font(.title3)
                    Text("Settings for \(radar.hiDef ? "Hi-Def" : "Standard") Radar").font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(.regularMaterial, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private var radarOn: Bool { radar.layers.contains(.radar) }

    /// The radar loops: only one is selected at a time.
    private func radarCard(_ title: String, _ sub: String, mode: RadarMode, hiDef: Bool?, symbol: String?) -> some View {
        let locked = mode != .recent && !store.hasDoppler
        let on = radarOn && radar.site == nil && radar.mode == mode && (hiDef == nil || radar.hiDef == hiDef)
        return KitCard(title: title, subtitle: sub, selected: on, locked: locked, action: {
            if locked { showPlans = true; return }
            radar.layers.insert(.radar)
            if let hiDef { radar.hiDef = hiDef }
            if radar.mode != mode || radar.site != nil { radar.setMode(mode) }
        }) {
            LayerThumb(overlay: LayerThumb.radarTile, symbol: symbol)
        }
    }

    /// Satellite and rain loops switch on and off; only one satellite view at a time.
    private func layerCard(_ l: MapLayer, _ title: String, _ sub: String) -> some View {
        let locked = !store.canUse(l)
        let on = radar.layers.contains(l)
        return KitCard(title: title, subtitle: sub, selected: on, locked: locked, action: {
            if locked { showPlans = true; return }
            if on { radar.layers.remove(l); return }
            if l.isSatellite { radar.layers.subtract(MapLayer.allCases.filter(\.isSatellite)) }
            radar.layers.insert(l)
        }) {
            LayerThumb(overlay: LayerThumb.tile(l.tiles?.template), symbol: l == .lightning ? "bolt.fill" : nil)
        }
    }

    private var noLoopCard: some View {
        let on = !radarOn && !radar.layers.contains { $0.isSatellite }
        return KitCard(title: "No Loop", subtitle: "Hide the radar and satellite", selected: on, action: {
            radar.layers.remove(.radar)
            radar.layers.subtract(MapLayer.allCases.filter(\.isSatellite))
            if radar.site != nil { radar.setSite(nil); radar.layers.remove(.radar) }
        }) {
            ZStack {
                Color.black.opacity(0.85)
                Image(systemName: "eye.slash").font(.system(size: 30, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            }
        }
    }
}

/// A small live map of the Southeast with the layer drawn on it.
struct LayerThumb: View {
    var overlay: URL?
    var symbol: String?

    /// Zoom 4 tile over the Southeast US (Gulf Coast to the Carolinas).
    static let base = URL(string: "https://services.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Base/MapServer/tile/4/6/4")
    static let radarTile = URL(string: "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/nexrad-n0q-900913/4/4/6.png")
    static func tile(_ template: String?) -> URL? {
        guard let t = template, t.contains("{z}") else { return nil }
        return URL(string: t.replacingOccurrences(of: "{z}", with: "4").replacingOccurrences(of: "{x}", with: "4").replacingOccurrences(of: "{y}", with: "6"))
    }

    var body: some View {
        ZStack {
            AsyncImage(url: Self.base) { $0.resizable().scaledToFill() } placeholder: { Color(white: 0.15) }
            if let overlay {
                AsyncImage(url: overlay) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
            }
            if let symbol {
                Image(systemName: symbol).font(.system(size: 26, weight: .semibold)).foregroundStyle(.white).shadow(radius: 4)
            }
        }
    }
}

// MARK: - Radar settings (from "Settings for Hi-Def Radar")

struct RadarSettingsPage: View {
    @ObservedObject var radar: RadarController
    @Binding var showPlans: Bool
    @EnvironmentObject var store: Store
    @AppStorage("mapBorders") private var borders = true
    @AppStorage("mapCounties") private var counties = true

    var body: some View {
        KitPage(title: "Radar Settings") {
            KitSectionHeader(text: "Radar style")
            KitCheckRow(title: "Hi-Def", subtitle: "Speckle removed and edges smoothed", selected: radar.hiDef) { radar.hiDef = true }
            KitCheckRow(title: "Standard", subtitle: "Raw radar, every pixel", selected: !radar.hiDef) { radar.hiDef = false }

            KitSectionHeader(text: "Radar opacity")
            HStack(spacing: 12) {
                Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary)
                Slider(value: $radar.opacity, in: 0.2...1).tint(Kit.purple)
                Text("\(Int((radar.opacity * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
            }
            .kitRow()

            KitSectionHeader(text: "Time")
            ForEach(RadarMode.allCases, id: \.self) { m in
                let locked = m != .recent && !store.hasDoppler
                KitCheckRow(title: m.title, badge: locked ? .pro : nil, selected: radar.site == nil && radar.mode == m) {
                    if locked { showPlans = true } else { radar.setMode(m) }
                }
            }

            KitSectionHeader(text: "Map")
            KitNavRow(title: "Map Options", value: radar.basemap.title, icon: "map") { MapOptionsPage(radar: radar) }

            KitSectionHeader(text: "Borders")
            KitToggleRow(title: "State and US borders", isOn: $borders)
            KitToggleRow(title: "County lines", subtitle: "Shown when zoomed in to about one state", isOn: $counties)
        }
    }
}

// MARK: - Overlays

private struct OverlaysTab: View {
    @ObservedObject var radar: RadarController
    @Binding var showPlans: Bool
    @EnvironmentObject var store: Store

    @State private var showPro = false

    /// Loops live on the first tab and radar sites on the third; everything else is here.
    private static let loops: Set<MapLayer> = [.radar, .sites, .satIR, .satVis, .satWV, .satColor, .rainRate, .rain1h, .tempMap, .rain, .rain72, .echoTops, .lightning]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(LayerGroup.allCases.filter { g in g != .radarSat && layers(g).count > 0 }) { g in
                    KitSectionHeader(text: g.rawValue)
                    ForEach(layers(g)) { l in row(l) }
                }
                if store.effectivePlan < .pro {
                    KitSectionHeader(text: "Upgrade")
                    KitButtonRow(title: "Unlock every layer with Pro", icon: "lock.open.fill") { showPro = true }
                }
            }
            .padding(.bottom, 28)
        }
        .sheet(isPresented: $showPro) { PlansView(start: .pro).environmentObject(store) }
    }

    private func layers(_ g: LayerGroup) -> [MapLayer] {
        MapLayer.allCases.filter { $0.group == g && !Self.loops.contains($0) && !(AviationPage.layers.contains($0) && $0 != .aviation) }
    }

    @ViewBuilder private func row(_ l: MapLayer) -> some View {
        let locked = !store.canUse(l)
        if l == .windFlow || l == .road || l == .aviation {
            KitNavToggleRow(title: l == .aviation ? "Aviation" : l.title, badge: locked ? l.tier : nil, isOn: Binding(
                get: { radar.layers.contains(l) && !locked },
                set: { on in
                    if locked { showPlans = true; return }
                    if on { radar.layers.insert(l) } else { radar.layers.remove(l) }
                })) {
                switch l {
                case .road: RoadWeatherPage(radar: radar)
                case .aviation: AviationPage(radar: radar, showPlans: $showPlans)
                default: WindSettingsPage()
                }
            }
        } else {
            KitToggleRow(title: l.title, badge: locked ? l.tier : nil, isOn: Binding(
            get: { radar.layers.contains(l) && !locked },
            set: { on in
                if locked { showPlans = true; return }
                if on { radar.layers.insert(l) } else { radar.layers.remove(l) }
            }))
        }
    }
}

// MARK: - Radars

/// NEXRAD site -> state, built into the app (the NWS list has no state).
enum RadarSiteStates {
    static let map: [String: String] = {
        guard let d = NSDataAsset(name: "RadarSiteStates")?.data,
              let m = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return [:] }
        return m
    }()
    static let outside = "Outside the US"
    static func state(_ id: String) -> String { map[id] ?? outside }
}

private struct RadarsTab: View {
    @ObservedObject var radar: RadarController
    @Binding var showPlans: Bool
    @EnvironmentObject var store: Store
    @EnvironmentObject var state: AppState
    @State private var sites: [RadarService.Site] = []
    @State private var loading = true
    @State private var query = ""
    @AppStorage("radarTipHidden") private var tipHidden = false

    private var nearby: [RadarService.Site] {
        let p = state.place
        return Array(sites.sorted { dist($0, p) < dist($1, p) }.prefix(3))
    }
    private func dist(_ s: RadarService.Site, _ p: Place) -> Double {
        pow(s.lat - p.lat, 2) + pow((s.lon - p.lon) * cos(p.lat * .pi / 180), 2)
    }

    private var filtered: [RadarService.Site] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return sites }
        return sites.filter { $0.id.lowercased().contains(q) || $0.name.lowercased().contains(q) || RadarSiteStates.state($0.id).lowercased().contains(q) }
    }

    struct SiteGroup: Identifiable {
        let state: String
        let sites: [RadarService.Site]
        var id: String { state }
    }

    /// States A to Z, with sites outside the US last.
    private var groups: [SiteGroup] {
        let byState = Dictionary(grouping: filtered) { RadarSiteStates.state($0.id) }
        return byState.keys.sorted { a, b in
            if a == RadarSiteStates.outside { return false }
            if b == RadarSiteStates.outside { return true }
            return a < b
        }
        .map { st in SiteGroup(state: st, sites: (byState[st] ?? []).sorted { $0.name < $1.name }) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    if !store.hasDoppler {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Single-radar Doppler", image: "Radome").font(.headline)
                            Text("Pick any NEXRAD radar for velocity, 4 tilt angles, hail and debris (dual-pol), VIL and echo tops. Part of Pro, or the one-time Radar Pack.")
                                .font(.subheadline).foregroundStyle(.secondary)
                            KitBigButton(title: "Unlock Doppler Radar") { showPlans = true }
                        }
                        .padding(16)
                        .background(Kit.row, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    if let s = radar.site {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Showing \(s.id)").font(.headline)
                                Text("\(s.name) · \(s.productName)").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Back to Hi-Def") { radar.setSite(nil) }
                                .buttonStyle(.borderedProminent).tint(Kit.purple)
                        }
                        .padding(16)
                        .background(Kit.row, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    if loading {
                        ProgressView().padding(30)
                    } else if sites.isEmpty {
                        Text("Couldn't load the radar list. Check your connection and try again.")
                            .font(.subheadline).foregroundStyle(.secondary).padding(30)
                    } else {
                        if query.isEmpty {
                            VStack(spacing: 0) {
                                ForEach(nearby, id: \.id) { s in siteRow(s, divider: s.id != nearby.last?.id) }
                            }
                            .background(Kit.row, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            if !tipHidden {
                                KitTip(text: "You can also tap a radar dish on the map.") { tipHidden = true }
                            }
                        }
                        KitSearchField(prompt: "Search by station ID or location", text: $query)
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(groups) { g in
                                Text(g.state).font(.title3.bold())
                                    .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 6)
                                    .id(g.state)
                                ForEach(g.sites, id: \.id) { s in siteRow(s, divider: true) }
                            }
                        }
                        .padding(.trailing, 18)   // room for the A to Z index
                        .background(Kit.row, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .overlay(alignment: .trailing) {
                if !loading && !groups.isEmpty { index(proxy) }
            }
        }
        .task {
            sites = await LiveData.radarSites()
            loading = false
        }
    }

    /// A to Z down the right side; tap a letter to jump to the first state starting with it.
    private func index(_ proxy: ScrollViewProxy) -> some View {
        let letters = Array(Set(groups.map { String($0.state.prefix(1)) })).sorted()
        return VStack(spacing: 2) {
            ForEach(letters, id: \.self) { l in
                Button {
                    if let first = groups.first(where: { $0.state.hasPrefix(l) }) {
                        withAnimation { proxy.scrollTo(first.state, anchor: .top) }
                    }
                } label: {
                    Text(l).font(.caption.bold()).frame(width: 22, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .padding(.trailing, 18)
    }

    private func siteRow(_ s: RadarService.Site, divider: Bool) -> some View {
        NavigationLink { SitePage(radar: radar, site: s, showPlans: $showPlans) } label: {
            HStack(spacing: 14) {
                Image("RadomeTower").resizable().scaledToFit().frame(width: 22, height: 22)
                    .padding(9).background(Color.white.opacity(0.9), in: Circle()).foregroundStyle(.black)
                Text(s.id).font(.title3)
                Spacer(minLength: 8)
                Text(s.name).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                if divider { Rectangle().fill(Kit.line).frame(height: 0.5).padding(.leading, 20) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One radar: pick what to show from it.
private struct SitePage: View {
    @ObservedObject var radar: RadarController
    let site: RadarService.Site
    @Binding var showPlans: Bool
    @EnvironmentObject var store: Store
    @Environment(\.kitClose) private var close
    @State private var tilt = 0

    var body: some View {
        KitPage(title: "\(site.id) · \(site.name)") {
            KitSectionHeader(text: "Product")
            ForEach(RadarService.SiteProduct.allCases) { p in
                KitCheckRow(title: p.title, subtitle: p.detail, selected: current?.kind == p) { show(p) }
            }
            KitSectionHeader(text: "Tilt (beam angle)")
            KitPills(options: (0..<4).map { (value: $0, title: RadarService.SiteProduct.tiltNames[$0]) }, selection: $tilt)
                .padding(.horizontal, 16)
            KitFooter(text: "The lowest tilt sees closest to the ground. Higher tilts look up into the storm. Tilts apply to Reflectivity, Velocity, Correlation Coefficient, Differential Reflectivity and Precipitation Type.")
        }
        .onAppear { tilt = current?.tilt ?? 0 }
        .onChange(of: tilt) { _, t in
            if let c = current, c.kind.hasTilts, c.tilt != t { show(c.kind) }
        }
    }

    /// This radar, if it's the one on the map.
    private var current: RadarService.Site? { radar.site?.id == site.id ? radar.site : nil }

    private func show(_ p: RadarService.SiteProduct) {
        guard store.hasDoppler else { showPlans = true; return }
        var s = site
        s.product = p.rawValue
        s.tilt = p.hasTilts ? tilt : 0
        radar.layers.insert(.sites)
        radar.setSite(s)
        close?()
    }
}
