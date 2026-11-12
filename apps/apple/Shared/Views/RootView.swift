import SwiftUI

/// Picks the layout: tabs on iPhone (and narrow iPad split screen), the pro workspace on iPad and Mac.
struct RootView: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    #endif
    var body: some View {
        Group {
            #if os(macOS)
            ProWorkspace()
            #else
            if hSize == .regular { ProWorkspace() } else { PhoneTabs() }
            #endif
        }
        .launchPromo()   // free plan: support page at launch, at most once a day
    }
}

/// iPhone: MyRadar-style tabs, plus a split-screen button (Pro) that stays on the Radar tab.
struct PhoneTabs: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var store: Store
    @State private var showSearch = false
    @State private var showPlans = false
    @State private var tab = 0
    private static let splitTag = 99

    /// Picking the Split tab toggles split screen (linked, independent, off) and stays on Radar.
    private var selection: Binding<Int> {
        Binding(get: { tab }, set: { new in
            guard new == Self.splitTag else { tab = new; return }
            tab = 0
            if store.effectivePlan < .pro { showPlans = true; return }
            withAnimation(.snappy) { state.splitMode = (state.splitMode + 1) % 3 }
        })
    }
    private var locked: Bool { store.effectivePlan < .pro }

    var body: some View {
        TabView(selection: selection) {
            RadarScreen(compact: true)
                .tabItem { Label("Radar", image: "Radome") }
                .tag(0)
            NavigationStack {
                MyDashboard().toolbar { searchButton }
            }
            .tabItem { Label("Dashboard", systemImage: "square.grid.2x2") }
            .tag(2)
            Color.clear
                .tabItem {
                    Label(state.splitMode == 0 ? "Split" : state.splitMode == 1 ? "Linked" : "Unlinked",
                          systemImage: state.splitMode == 0 ? "rectangle.split.1x2" : state.splitMode == 1 ? "rectangle.split.1x2.fill" : "rectangle.split.1x2")
                }
                .badge(locked ? Text("PRO") : nil)
                .tag(Self.splitTag)
            NavigationStack { RouteView() }
                .tabItem { Label("Route", systemImage: "car.fill") }
                .badge(locked ? Text("PRO") : nil)
                .tag(3)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(4)
        }
        .onAppear {
            #if os(iOS)
            UITabBarItem.appearance().badgeColor = UIColor(red: 0.54, green: 0.24, blue: 0.86, alpha: 1)
            #endif
        }
        .sheet(isPresented: $showSearch) { SearchView().environmentObject(state) }
        .sheet(isPresented: $showPlans) { PlansView(start: .pro).environmentObject(store) }
        .onOpenURL { url in   // tapping a widget opens the Dashboard
            if url.scheme == "doppleriq", url.host == "dashboard" { tab = 2 }
        }
    }

    private var searchButton: some ToolbarContent {
        ToolbarItem { Button { showSearch = true } label: { Image(systemName: "magnifyingglass") } }
    }
}
