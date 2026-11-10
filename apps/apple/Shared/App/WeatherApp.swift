import SwiftUI
import UserNotifications

@main
struct WeatherApp: App {
    @StateObject private var state = AppState()
    @StateObject private var store = Store()
    @Environment(\.scenePhase) private var phase
    private static let notes = NotificationPresenter()   // kept alive for the whole run (the delegate is weak)

    init() {
        AlertMonitor.register()   // background alert checks (iPhone, iPad)
        UNUserNotificationCenter.current().delegate = Self.notes
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(store)
                .tint(Color("AccentColor"))
                .preferredColorScheme(state.appearance.scheme)
                .task { await state.start() }
                .task {   // weather alerts while the app is open
                    while !Task.isCancelled {
                        await AlertMonitor.check()
                        try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                    }
                }
                .onChange(of: phase) { _, p in if p == .background { AlertMonitor.schedule() } }
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(state)
                .environmentObject(store)
                .preferredColorScheme(state.appearance.scheme)
                .frame(width: 460, height: 480)
        }
        #endif
    }
}

/// Show alert banners even while the app is open.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
