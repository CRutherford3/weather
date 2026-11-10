import SwiftUI

/// Picks the layout: tabs on iPhone (and narrow iPad split screen), the pro workspace on iPad and Mac.
struct RootView: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    #endif
    var body: some View {
        #if os(macOS)
        ProWorkspace()
        #else
        if hSize == .regular { ProWorkspace() } else { PhoneTabs() }
        #endif
    }
}

/// iPhone: MyRadar-style tabs.
struct PhoneTabs: View {
    @EnvironmentObject var state: AppState
    @State private var showSearch = false

    var body: some View {
        TabView {
            RadarScreen(compact: true)
                .tabItem { Label("Radar", systemImage: "dot.radiowaves.left.and.right") }
            NavigationStack {
                ForecastView().toolbar { searchButton }
            }
            .tabItem { Label("Forecast", systemImage: "cloud.sun") }
            NavigationStack {
                MyDashboard().toolbar { searchButton }
            }
            .tabItem { Label("Dashboard", systemImage: "square.grid.2x2") }
            NavigationStack { RouteView() }
                .tabItem { Label("Route", systemImage: "car.fill") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .sheet(isPresented: $showSearch) { SearchView().environmentObject(state) }
    }

    private var searchButton: some ToolbarContent {
        ToolbarItem { Button { showSearch = true } label: { Image(systemName: "magnifyingglass") } }
    }
}
