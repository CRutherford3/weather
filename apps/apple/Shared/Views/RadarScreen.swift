import SwiftUI

/// The main radar screen: map, crosshair, weather card, and a dock with the loop controls.
struct RadarScreen: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var store: Store
    @StateObject private var radar = RadarController()
    @State private var recenter = 0
    @State private var showLayers = false
    var compact = true   // phone layout (card on top, dock at the bottom)

    var body: some View {
        ZStack {
            RadarMap(radar: radar, center: state.place.coordinate, recenterToken: recenter) { c in
                Task { @MainActor in state.mapCentered(c) }
            }
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
    }

    private var dock: some View {
        VStack(spacing: 8) {
            if !radar.frames.isEmpty {
                Slider(value: Binding(get: { Double(radar.index) }, set: { radar.index = Int($0.rounded()); radar.playing = false }),
                       in: 0...Double(max(1, radar.frames.count - 1)), step: 1)
            }
            HStack {
                Button { radar.playing.toggle() } label: { Image(systemName: radar.playing ? "pause.fill" : "play.fill") }
                Text(radar.currentTime.map { $0.formatted(date: .omitted, time: .shortened) } ?? "--").monospacedDigit()
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
}

struct LayersSheet: View {
    @ObservedObject var radar: RadarController
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var showPlans = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Map layers") {
                    ForEach(MapLayer.allCases) { l in
                        let locked = store.effectivePlan < l.tier
                        Toggle(isOn: Binding(
                            get: { radar.layers.contains(l) },
                            set: { on in
                                if locked { showPlans = true; return }
                                if on { radar.layers.insert(l) } else { radar.layers.remove(l) }
                            })) {
                            HStack { Text(l.title); if l.tier > .free { TierBadge(plan: l.tier) } }
                        }
                    }
                }
                Section("Radar") {
                    Slider(value: $radar.opacity, in: 0.2...1) { Text("Opacity") }
                }
                Section { Text("More layers (hail, marine, snow, tropics, outages, traffic) are on the website today and coming to the app next.").font(.footnote).foregroundStyle(.secondary) }
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

struct TierBadge: View {
    var plan: Plan
    var body: some View {
        Text(plan.name.uppercased()).font(.caption2.bold())
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background((plan == .pro ? Color.purple : Color.blue).opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(plan == .pro ? Color.purple : Color.blue)
    }
}
