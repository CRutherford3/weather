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
    var compact = true   // phone layout (card on top, dock at the bottom)

    var body: some View {
        ZStack {
            RadarMap(radar: radar, center: state.place.coordinate, recenterToken: recenter,
                     onCenterChange: { c in Task { @MainActor in state.mapCentered(c) } },
                     onCamera: { name, url in camera = BuoyCamSheet(title: name, url: url) })
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
        .sheet(isPresented: $showLayers) { LayersSheet(radar: radar).environmentObject(store) }
        .sheet(item: $camera) { $0 }
        .sheet(isPresented: $showPlans) { PlansView().environmentObject(store) }
    }

    private var dock: some View {
        VStack(spacing: 8) {
            if !radar.frames.isEmpty {
                Slider(value: Binding(get: { Double(radar.index) }, set: { radar.index = Int($0.rounded()); radar.playing = false }),
                       in: 0...Double(max(1, radar.frames.count - 1)), step: 1)
            }
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                Text(radar.layers.contains(.radar) ? "Hi-Def Radar" : "Radar Off").font(.subheadline.weight(.semibold))
                if radar.mode != .recent { Text("· \(radar.mode.title)").font(.subheadline) }
                Spacer()
            }
            .foregroundStyle(.secondary)
            HStack {
                Button { radar.playing.toggle() } label: { Image(systemName: radar.playing ? "pause.fill" : "play.fill") }
                timeLabel
                Menu {
                    ForEach(RadarMode.allCases, id: \.self) { m in
                        Button {
                            if m != .recent && !proRadar { showPlans = true } else { radar.setMode(m) }
                        } label: {
                            if radar.mode == m { Label(m.title, systemImage: "checkmark") }
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
    private var proRadar: Bool { store.radarPack || store.effectivePlan >= .pro }

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
    @Environment(\.dismiss) private var dismiss
    @State private var showPlans = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Map") {
                    Picker("Map", selection: $radar.basemap) {
                        ForEach(Basemap.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                ForEach(LayerGroup.allCases) { g in
                    Section(g.rawValue) {
                        ForEach(MapLayer.allCases.filter { $0.group == g }) { l in toggle(l) }
                        if g == .radarSat {
                            Slider(value: $radar.opacity, in: 0.2...1) { Text("Radar opacity") }
                        }
                    }
                }
                if !store.radarPack && store.effectivePlan < .pro {
                    Section { Button { showPlans = true } label: { Label("Unlock every layer with the Pro Radar Pack", systemImage: "lock.open.fill") } }
                }
            }
            .navigationTitle("Layers")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showPlans) { PlansView().environmentObject(store) }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 420)
        #endif
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
