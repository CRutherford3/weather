import Foundation
import UserNotifications
#if os(iOS)
import BackgroundTasks
#endif

/// Plus: notifications for your location and saved places.
/// - New NWS warnings (tornado, severe thunderstorm, flash flood, hurricane, winter storm...)
/// - "Rain starting soon" at your location, from the 15-minute forecast
/// Checks run when the app opens, every few minutes while it's open, and in the background on iPhone and iPad
/// (iOS decides exactly when, usually every 15 to 30 minutes).
enum AlertMonitor {
    static let taskID = "io.dialcheck.weather.alerts"
    private static let d = UserDefaults.standard

    /// The user's switch in Settings.
    static var isOn: Bool {
        get { d.bool(forKey: "alertsOn") }
        set { d.set(newValue, forKey: "alertsOn") }
    }
    /// Written by Store whenever the plan changes, so background checks know without StoreKit.
    static var planAllows: Bool { d.integer(forKey: "planLevel") >= Plan.plus.rawValue }
    static var active: Bool { isOn && planAllows }

    /// Ask for permission and turn alerts on. Returns false if the user said no.
    static func enable() async -> Bool {
        let c = UNUserNotificationCenter.current()
        let ok = (try? await c.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        isOn = ok
        if ok { schedule(); await check() }
        return ok
    }
    static func disable() { isOn = false }

    // MARK: background refresh (iPhone / iPad)

    /// Call once at launch, before the app finishes launching.
    static func register() {
        #if os(iOS)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            schedule()   // queue the next one
            let work = Task { await check(); task.setTaskCompleted(success: true) }
            task.expirationHandler = { work.cancel() }
        }
        #endif
    }

    static func schedule() {
        #if os(iOS)
        guard active else { return }
        let r = BGAppRefreshTaskRequest(identifier: taskID)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
        #endif
    }

    // MARK: the check

    private static let severe = try! NSRegularExpression(pattern: "Tornado|Severe Thunderstorm|Flash Flood|Hurricane|Tropical Storm|Storm Surge|Extreme Wind|Blizzard|Ice Storm|Winter Storm Warning|Extreme Heat Warning|Extreme Cold Warning|Special Marine")

    private static func places() -> [Place] {
        func load<T: Decodable>(_ k: String) -> T? { d.data(forKey: k).flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
        var out: [Place] = []
        if let home: Place = load("place") { out.append(home) }
        for p in (load("favorites") as [Place]? ?? []) where !out.contains(where: { abs($0.lat - p.lat) < 0.02 && abs($0.lon - p.lon) < 0.02 }) { out.append(p) }
        return Array(out.prefix(10))
    }

    static func check() async {
        guard active else { return }
        let all = places()
        var seen = Set(d.stringArray(forKey: "alertsSeen") ?? [])
        for p in all {
            guard let url = URL(string: String(format: "https://api.weather.gov/alerts/active?point=%.4f,%.4f", p.lat, p.lon)) else { continue }
            var req = URLRequest(url: url)
            req.setValue(AppConfig.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("application/geo+json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 20
            guard let data = try? await URLSession.shared.data(for: req).0,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let feats = j["features"] as? [[String: Any]] else { continue }
            for f in feats {
                guard let pr = f["properties"] as? [String: Any], let id = pr["id"] as? String, let ev = pr["event"] as? String,
                      !seen.contains(id), severe.firstMatch(in: ev, range: NSRange(ev.startIndex..., in: ev)) != nil else { continue }
                seen.insert(id)
                let body = (pr["headline"] as? String) ?? String(((pr["description"] as? String) ?? "").prefix(160))
                await post(id: id, title: "\(ev) · \(p.name)", body: body, critical: ev.contains("Tornado") || ev.contains("Flash Flood Emergency"))
            }
        }
        d.set(Array(seen.suffix(300)), forKey: "alertsSeen")
        if let home = all.first { await rainSoon(home) }
    }

    /// One heads-up per dry spell when rain is expected within 45 minutes.
    private static func rainSoon(_ p: Place) async {
        guard let url = URL(string: String(format: "https://api.open-meteo.com/v1/forecast?latitude=%.3f&longitude=%.3f&minutely_15=precipitation&forecast_minutely_15=4&past_minutely_15=1", p.lat, p.lon)),
              let data = try? await URLSession.shared.data(from: url).0,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let m = j["minutely_15"] as? [String: Any], let pr = (m["precipitation"] as? [Any])?.map({ ($0 as? NSNumber)?.doubleValue ?? 0 }),
              !pr.isEmpty else { return }
        let now = pr[0], soon = pr.dropFirst().firstIndex { $0 >= 0.1 }
        let warned = d.bool(forKey: "rainWarned")
        if now < 0.1, let soon, !warned {
            await post(id: "rain", title: "Rain starting soon · \(p.name)", body: "Rain is expected within about \(soon * 15) minutes.", critical: false)
            d.set(true, forKey: "rainWarned")
        } else if now < 0.1, soon == nil {
            d.set(false, forKey: "rainWarned")
        }
    }

    private static func post(id: String, title: String, body: String, critical: Bool) async {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        c.sound = .default
        #if os(iOS)
        if critical { c.interruptionLevel = .timeSensitive }
        #endif
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }
}
