import SwiftUI

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
    var compact = true   // phone layout (card on top, dock at the bottom)

    var body: some View {
        ZStack {
            RadarMap(radar: radar, center: state.place.coordinate, recenterToken: recenter,
                     onCenterChange: { c in Task { @MainActor in state.mapCentered(c) } },
                     onCamera: { name, url in camera = BuoyCamSheet(title: name, url: url) },
                     onSite: { s in tappedSite = s })
            .ignoresSafeArea()
            Crosshair()
        }
        .overlay(alignment: compact ? .top : .topLeading) {
            WeatherCard(onHome: { state.center = nil; state.centerForecast = nil; recenter += 1 })
                .frame(maxWidth: compact ? .infinity : 420)
                .padding(12)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if store.effectivePlan == .free { AdBanner(kind: .banner) }
                dock
            }
            .padding(12)
            .frame(maxWidth: 640)
        }
        .task { await radar.load() }
        .onChange(of: state.place) { _, _ in recenter += 1 }
        .sheet(isPresented: $showLayers) { LayersSheet(radar: radar).environmentObject(store).environmentObject(state) }
        .sheet(item: $camera) { $0 }
        .sheet(isPresented: $showPlans) { PlansView().environmentObject(store) }
        .confirmationDialog(tappedSite.map { "\($0.id) · \($0.name)" } ?? "Radar", isPresented: Binding(get: { tappedSite != nil }, set: { if !$0 { tappedSite = nil } }), titleVisibility: .visible) {
            if let s = tappedSite {
                ForEach(RadarService.SiteProduct.allCases) { p in
                    Button("\(p.title) (\(p.detail.lowercased()))") {
                        var x = s; x.product = p.rawValue
                        x.tilt = (radar.site?.id == s.id && p.hasTilts) ? radar.site?.tilt ?? 0 : 0
                        radar.setSite(x)
                    }
                }
                if radar.site != nil { Button("Back to Hi-Def Radar") { radar.setSite(nil) } }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var dock: some View {
        VStack(spacing: 8) {
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
                    Text(radar.layers.contains(.radar) ? (radar.hiDef ? "Hi-Def Radar" : "Standard Radar") : "Radar Off").font(.subheadline.weight(.semibold))
                    if radar.mode != .recent { Text("· \(radar.mode.title)").font(.subheadline) }
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
                Button { showLayers = true } label: { Label("Layers", systemImage: "square.3.layers.3d") }
                Button { recenter += 1; state.center = nil } label: { Label("Home", systemImage: "location") }
            }
            .buttonStyle(.borderless)
            .labelStyle(.titleAndIcon)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// Past 48 hours and future radar come with Pro or the Radar Pack.
    private var proRadar: Bool { store.hasDoppler }

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

struct LayersSheet: View {
    @ObservedObject var radar: RadarController
    @EnvironmentObject var store: Store
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showPlans = false
    /// Which groups are expanded (saved). Radar & Satellite starts open; the rest start collapsed.
    @AppStorage("layerGroupsOpen") private var openRaw = "pro,Radar & Satellite"
    private var open: Set<String> { Set(openRaw.split(separator: ",").map(String.init)) }
    private func expanded(_ id: String) -> Binding<Bool> {
        Binding(get: { open.contains(id) }, set: { on in
            var s = open; if on { s.insert(id) } else { s.remove(id) }
            openRaw = s.sorted().joined(separator: ",")
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Map") {
                    Picker("Map", selection: $radar.basemap) {
                        ForEach(Basemap.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section { professionalRadar }
                ForEach(LayerGroup.allCases.filter { g in MapLayer.allCases.contains { $0.group == g && !$0.isProRadar } }) { g in
                    Section {
                        DisclosureGroup(isExpanded: expanded(g.rawValue)) {
                            ForEach(MapLayer.allCases.filter { $0.group == g && !$0.isProRadar }) { l in toggle(l) }
                            if g == .radarSat {
                                Picker("Radar style", selection: $radar.hiDef) {
                                    Text("Hi-Def (smooth)").tag(true)
                                    Text("Standard (raw)").tag(false)
                                }
                                Slider(value: $radar.opacity, in: 0.2...1) { Text("Radar opacity") }
                            }
                        } label: {
                            HStack {
                                Text(g.rawValue).font(.headline)
                                Spacer()
                                let n = radar.layers.filter { $0.group == g && !$0.isProRadar }.count
                                if n > 0 { Text("\(n) on").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                if store.effectivePlan < .plus {
                    Section { Button { showPlans = true } label: { Label("Unlock every layer with Plus", systemImage: "lock.open.fill") } }
                }
            }
            .formStyle(.grouped)   // scrollable list on Mac (the default Mac form style doesn't scroll)
            .navigationTitle("Layers")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showPlans) { PlansView().environmentObject(store) }
        }
        #if os(macOS)
        .frame(width: 480, height: 640)   // fixed size so the layer list scrolls on Mac
        #endif
    }

    /// Pro: single radar sites, Doppler products, tilts, past and future radar (also in the Radar Pack),
    /// then the marine and space layers.
    @ViewBuilder private var professionalRadar: some View {
        DisclosureGroup(isExpanded: expanded("pro")) {
            if !store.hasDoppler {
                Text("Pick any NEXRAD radar and see velocity, 4 tilt angles, hail and debris (dual-pol), VIL and echo tops, plus past 48 hours and future radar.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button { showPlans = true } label: { Label("Get it with Pro or the $6.99 Radar Pack", systemImage: "lock.open.fill") }
            } else {
                toggle(.sites)
                if let s = radar.site {
                    LabeledContent("Showing", value: "\(s.id) · \(s.name)")
                } else {
                    Text("Tap a radar dish on the map, or pick a product below to use the radar nearest you.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Picker("Product", selection: Binding(get: { radar.site?.kind }, set: { p in if let p { choose(p, tilt: nil) } })) {
                    if radar.site == nil { Text("Hi-Def mosaic").tag(RadarService.SiteProduct?.none) }
                    ForEach(RadarService.SiteProduct.allCases) { p in Text(p.title).tag(Optional(p)) }
                }
                if let s = radar.site, s.kind.hasTilts {
                    Picker("Tilt (beam angle)", selection: Binding(get: { s.tilt }, set: { t in choose(s.kind, tilt: t) })) {
                        ForEach(0..<4, id: \.self) { t in Text(RadarService.SiteProduct.tiltNames[t]).tag(t) }
                    }
                    .pickerStyle(.segmented)
                }
                if let s = radar.site { Text(s.kind.detail).font(.footnote).foregroundStyle(.secondary) }
                Picker("Time", selection: Binding(get: { radar.site == nil ? radar.mode : .recent }, set: { radar.setMode($0) })) {
                    ForEach(RadarMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if radar.site != nil { Button("Back to Hi-Def mosaic") { radar.setSite(nil) } }
            }
            Text("MARINE & SPACE").font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 6)
            ForEach(MapLayer.allCases.filter(\.isMarineSpace)) { l in toggle(l) }
        } label: {
            HStack {
                Label("Pro: Radar, Marine & Space", image: "Radome").font(.headline)
                Spacer()
                if store.hasDoppler { if let s = radar.site { Text(s.id).font(.caption).foregroundStyle(.secondary) } }
                else { TierBadge(plan: .pro) }
            }
        }
    }

    /// Switch product or tilt on the current radar, or start with the radar nearest the selected place.
    private func choose(_ p: RadarService.SiteProduct, tilt: Int?) {
        if var s = radar.site {
            s.product = p.rawValue
            s.tilt = p.hasTilts ? (tilt ?? s.tilt) : 0
            radar.setSite(s)
            return
        }
        Task {
            guard var s = await LiveData.nearestSite(state.place) else { return }
            s.product = p.rawValue; s.tilt = p.hasTilts ? (tilt ?? 0) : 0
            radar.layers.insert(.sites)
            radar.setSite(s)
        }
    }
}

extension LayersSheet {
    @ViewBuilder func toggle(_ l: MapLayer) -> some View {
        let locked = !store.canUse(l)
        Toggle(isOn: Binding(
            get: { radar.layers.contains(l) },
            set: { on in
                if locked { showPlans = true; return }
                if on {
                    if l.isSatellite { radar.layers.subtract(MapLayer.allCases.filter(\.isSatellite)) }
                    radar.layers.insert(l)
                } else {
                    radar.layers.remove(l)
                    if l == .sites, radar.site != nil { radar.setSite(nil) }
                }
            })) {
            HStack { Text(l.title); if locked { TierBadge(plan: l.tier) } }
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
