import Foundation
import CoreLocation

/// One-shot "where am I" lookups.
@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    private var authContinuation: CheckedContinuation<Void, Never>?
    @Published var authorized = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    private static func allowed(_ s: CLAuthorizationStatus) -> Bool {
        #if os(macOS)
        return s == .authorizedAlways || s == .authorized
        #else
        return s == .authorizedWhenInUse || s == .authorizedAlways
        #endif
    }

    /// Asks for permission the first time (and waits for the answer), then gets one location fix.
    func current() async -> CLLocation? {
        if manager.authorizationStatus == .notDetermined {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                authContinuation?.resume()
                authContinuation = c
                manager.requestWhenInUseAuthorization()
            }
        }
        guard Self.allowed(manager.authorizationStatus) else { return nil }
        if let recent = manager.location, recent.timestamp.timeIntervalSinceNow > -300 { return recent }
        return await withCheckedContinuation { c in
            continuation?.resume(returning: nil)
            continuation = c
            manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        Task { @MainActor in continuation?.resume(returning: locs.last); continuation = nil }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in continuation?.resume(returning: nil); continuation = nil }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let s = m.authorizationStatus
        Task { @MainActor in
            authorized = Self.allowed(s)
            if s != .notDetermined { authContinuation?.resume(); authContinuation = nil }
        }
    }
}
