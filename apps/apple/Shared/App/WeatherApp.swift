import SwiftUI

@main
struct WeatherApp: App {
    @StateObject private var state = AppState()
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(store)
                .tint(Color("AccentColor"))
                .task { await state.refresh() }
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(state)
                .environmentObject(store)
                .frame(width: 460, height: 420)
        }
        #endif
    }
}
