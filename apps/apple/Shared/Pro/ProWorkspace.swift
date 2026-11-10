import SwiftUI

/// iPad and Mac: the "pro" workspace. Sidebar of views on the left; the radar view shows the map
/// with a forecast and alerts panel beside it; map product sections open as full grids.
struct ProWorkspace: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var store: Store
    @State private var selection: Item? = .radar
    @State private var showSearch = false
    @State private var showPlans = false
    @AppStorage("panelWidth") private var panelWidth: Double = 380
    @AppStorage("panelOpen") private var panelOpen = true
    @State private var dragStart: Double?
    @AppStorage("sidebarMapsOpen") private var mapsOpen = false
    @AppStorage("sidebarProOpen") private var proOpen = false

    enum Item: Hashable { case radar, forecast, dashboard, allMaps, route, section(String), settings }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Weather") {
                    Label("Radar", systemImage: "dot.radiowaves.left.and.right").tag(Item.radar)
                    Label("Forecast", systemImage: "cloud.sun").tag(Item.forecast)
                    Label("Dashboard", systemImage: "square.grid.2x2").tag(Item.dashboard)
                    Label("Route Weather", systemImage: "car.fill").tag(Item.route)
                    Label("All maps", systemImage: "map").tag(Item.allMaps)
                }
                Section("Map collections", isExpanded: $mapsOpen) {
                    ForEach(Products.sections.filter { !isPro($0.id) }) { s in Label(s.id, systemImage: icon(s.id)).tag(Item.section(s.id)) }
                }
                // Pro map collections and Marine & Space, folded into one dropdown
                Section(isExpanded: $proOpen) {
                    ForEach(Products.sections.filter { isPro($0.id) }) { s in
                        HStack {
                            Label(s.id.replacingOccurrences(of: "Pro: ", with: ""), systemImage: icon(s.id))
                            if store.effectivePlan < .pro { Spacer(); Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                        }
                        .tag(Item.section(s.id))
                    }
                } header: {
                    Label("Professional Radar", systemImage: "dot.radiowaves.left.and.right")
                }
                Section("My places") {
                    ForEach(state.favorites) { p in
                        Button { state.select(p); selection = .radar } label: { Label(p.name, systemImage: "star.fill") }
                            .buttonStyle(.plain)
                    }
                    Button { showSearch = true } label: { Label("Find a place", systemImage: "magnifyingglass") }.buttonStyle(.plain)
                }
                Section {
                    Label("Settings", systemImage: "gearshape").tag(Item.settings)
                }
            }
            .navigationTitle(AppConfig.displayName)
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            #endif
        } detail: {
            detail
                .toolbar {
                    ToolbarItem { Button { showSearch = true } label: { Label("Search", systemImage: "magnifyingglass") } }
                    ToolbarItem { Button { Task { await state.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") } }
                }
        }
        .sheet(isPresented: $showSearch) { SearchView().environmentObject(state) }
        .sheet(isPresented: $showPlans) { PlansView().environmentObject(store) }
    }

    /// Drag left or right to resize the forecast panel. Double-click / double-tap resets it.
    private var resizeHandle: some View {
        ZStack {
            Rectangle().fill(.separator).frame(width: 1)
            Capsule().fill(.secondary).frame(width: 5, height: 44)
        }
        .frame(width: 12)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    if dragStart == nil { dragStart = panelWidth }
                    panelWidth = min(720, max(280, (dragStart ?? panelWidth) - v.translation.width))
                }
                .onEnded { _ in dragStart = nil }
        )
        .onTapGesture(count: 2) { withAnimation(.snappy) { panelWidth = 380 } }
        #if os(macOS)
        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
        #endif
        .help("Drag to resize")
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .radar {
        case .radar:
            if store.effectivePlan >= .pro {
                HStack(spacing: 0) {
                    RadarScreen(compact: false)
                        .overlay(alignment: .topTrailing) {
                            if !panelOpen {
                                Button { withAnimation(.snappy) { panelOpen = true } } label: { Label("Forecast", systemImage: "sidebar.right") }
                                    .buttonStyle(.borderedProminent).padding(12)
                            }
                        }
                    if panelOpen {
                        resizeHandle
                        NavigationStack { ForecastView(followMap: true) }
                            .frame(width: panelWidth)
                            .overlay(alignment: .topTrailing) {
                                Button { withAnimation(.snappy) { panelOpen = false } } label: {
                                    Image(systemName: "xmark.circle.fill").font(.title2).symbolRenderingMode(.hierarchical)
                                }
                                .buttonStyle(.plain).padding(10).help("Close the forecast panel")
                            }
                            .transition(.move(edge: .trailing))
                    }
                }
            } else {
                // Free and Plus get the map; the side-by-side workspace is a Pro feature
                RadarScreen(compact: false)
                    .overlay(alignment: .topTrailing) {
                        Button { showPlans = true } label: { Label("Pro workspace", systemImage: "rectangle.split.2x1") }
                            .buttonStyle(.borderedProminent).padding(12)
                    }
            }
        case .forecast: NavigationStack { ForecastView() }
        case .dashboard: NavigationStack { MyDashboard() }
        case .route: NavigationStack { RouteView() }
        case .allMaps: NavigationStack { DashboardView() }
        case .section(let s): NavigationStack { DashboardView(only: s) }
        case .settings: NavigationStack { SettingsView() }
        }
    }

    /// Sections that live under Professional Radar.
    private func isPro(_ id: String) -> Bool { id.hasPrefix("Pro: ") || id == "Marine & Space" }

    private func icon(_ s: String) -> String {
        switch s {
        case "Pro: Tropical Analysis": return "hurricane"
        case "Pro: Ocean": return "water.waves"
        case "Pro: Surface Analysis": return "map"
        case "Pro: Satellite": return "globe.americas.fill"
        case "Pro: Forecast Maps": return "calendar"
        case "Pro: Fire, Drought & UV": return "flame"
        case "Pro: Climatology": return "chart.line.uptrend.xyaxis"
        case "Tropics": return "hurricane"
        case "Severe Weather": return "cloud.bolt.rain"
        case "Rain, Snow & Fronts": return "cloud.snow"
        case "Marine & Space": return "water.waves"
        default: return "globe.americas"
        }
    }
}
