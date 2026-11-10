import Foundation
import SwiftUI
import CoreLocation

/// Everything the screens share: the chosen place, its forecast and alerts, units, saved places,
/// and the "crosshair" place the radar card follows when you pan the map.
@MainActor
final class AppState: ObservableObject {
    @Published var place: Place { didSet { save(place, "place") } }
    @Published var forecast: Forecast?
    @Published var alerts: [WeatherAlert] = []
    @Published var loading = false
    @Published var error: String?

    @Published var units: Units { didSet { UserDefaults.standard.set(units.rawValue, forKey: "units"); Task { await refresh() } } }
    @Published var favorites: [Place] { didSet { save(favorites, "favorites") } }

    /// Weather at the map crosshair (nil when the map is centered on `place`).
    @Published var center: Place?
    @Published var centerForecast: Forecast?
    @Published var centerAlerts: [WeatherAlert] = []
    @Published var cardCollapsed: Bool { didSet { UserDefaults.standard.set(cardCollapsed, forKey: "cardCollapsed") } }
    /// True when the home place should track the device location (until the user picks a different place).
    @Published var followMe: Bool { didSet { UserDefaults.standard.set(followMe, forKey: "followMe") } }
    /// Light, dark, or follow the device setting.
    @Published var appearance: Appearance { didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") } }

    let location = LocationManager()
    private var centerTask: Task<Void, Never>?

    init() {
        place = Self.load("place") ?? .atlanta
        favorites = Self.load("favorites") ?? []
        units = Units(rawValue: UserDefaults.standard.string(forKey: "units") ?? "") ?? .imperial
        cardCollapsed = UserDefaults.standard.bool(forKey: "cardCollapsed")
        followMe = UserDefaults.standard.object(forKey: "followMe") as? Bool ?? true
        appearance = Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system
    }

    func refresh() async {
        loading = true; error = nil
        let p = place
        do {
            async let f = WeatherService.shared.forecast(for: p, units: units)
            async let a = WeatherService.shared.alerts(for: p)
            let (ff, aa) = try await (f, a)
            guard p == place else { loading = false; return } // a newer place was picked while loading
            forecast = ff; alerts = aa
        } catch {
            self.error = "Couldn't load the forecast. Pull to try again."
        }
        loading = false
    }

    /// App launch: go to the current location when following it, otherwise the last place.
    func start() async {
        if followMe, await locate() { return }
        await refresh()
    }

    /// A place the user picked by hand (search or a saved place).
    func select(_ p: Place) {
        followMe = false
        show(p)
    }

    private func show(_ p: Place) {
        place = p; center = nil; centerForecast = nil
        forecast = nil; alerts = []
        Task { await refresh() }
    }

    func useMyLocation() async {
        followMe = true
        if !(await locate()) { error = "Location isn't available. Turn it on in Settings > Privacy & Security > Location Services." }
    }

    @discardableResult private func locate() async -> Bool {
        guard let loc = await location.current() else { return false }
        let name = await WeatherService.shared.placeName(loc.coordinate.latitude, loc.coordinate.longitude)
        show(Place(name: name, lat: loc.coordinate.latitude, lon: loc.coordinate.longitude))
        return true
    }

    /// Called when the map stops moving. Loads weather for the crosshair unless it's on the selected place.
    func mapCentered(_ c: CLLocationCoordinate2D) {
        centerTask?.cancel()
        if abs(c.latitude - place.lat) < 0.03 && abs(c.longitude - place.lon) < 0.03 {
            center = nil; centerForecast = nil; return
        }
        centerTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let name = await WeatherService.shared.placeName(c.latitude, c.longitude)
            let p = Place(name: name, lat: c.latitude, lon: c.longitude)
            guard let f = try? await WeatherService.shared.forecast(for: p, units: units), !Task.isCancelled else { return }
            let a = await WeatherService.shared.alerts(for: p)
            guard !Task.isCancelled else { return }
            center = p; centerForecast = f; centerAlerts = a
        }
    }

    func isFavorite(_ p: Place) -> Bool { favorites.contains { abs($0.lat - p.lat) < 0.02 && abs($0.lon - p.lon) < 0.02 } }
    func toggleFavorite(_ p: Place) {
        if isFavorite(p) { favorites.removeAll { abs($0.lat - p.lat) < 0.02 && abs($0.lon - p.lon) < 0.02 } }
        else { favorites.append(p) }
    }

    // MARK: persistence
    private func save<T: Encodable>(_ v: T, _ key: String) { UserDefaults.standard.set(try? JSONEncoder().encode(v), forKey: key) }
    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
}

/// App color scheme choice.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    /// nil means follow the device setting.
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
