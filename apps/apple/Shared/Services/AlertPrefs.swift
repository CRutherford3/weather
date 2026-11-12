import Foundation
import Combine

/// Which NWS alerts to send, quiet hours and the rain heads-up. Saved in UserDefaults so the
/// background check (AlertMonitor) can read them without the app's UI running.
enum AlertCategory: String, CaseIterable, Identifiable {
    case storms, flood, tropical, winter, air, marine, special
    var id: String { rawValue }

    var title: String {
        switch self {
        case .storms: return "Thunderstorm & Tornado"
        case .flood: return "Flood & Coastal"
        case .tropical: return "Hurricane & Tropical"
        case .winter: return "Winter, Snow, Freeze"
        case .air: return "Air, Dust, Smoke"
        case .marine: return "Marine"
        case .special: return "Special"
        }
    }

    /// NWS event names, exactly as api.weather.gov sends them.
    var events: [String] {
        switch self {
        case .storms: return ["Tornado Warning", "Tornado Watch", "Severe Thunderstorm Warning", "Severe Thunderstorm Watch",
                              "Extreme Wind Warning", "Severe Weather Statement"]
        case .flood: return ["Flash Flood Warning", "Flash Flood Watch", "Flood Warning", "Flood Watch", "Flood Advisory",
                             "Coastal Flood Warning", "Coastal Flood Watch", "Coastal Flood Advisory", "Lakeshore Flood Warning",
                             "High Surf Warning", "High Surf Advisory", "Rip Current Statement"]
        case .tropical: return ["Hurricane Warning", "Hurricane Watch", "Tropical Storm Warning", "Tropical Storm Watch",
                                "Storm Surge Warning", "Storm Surge Watch", "Typhoon Warning", "Hurricane Local Statement"]
        case .winter: return ["Blizzard Warning", "Winter Storm Warning", "Winter Storm Watch", "Ice Storm Warning",
                              "Snow Squall Warning", "Lake Effect Snow Warning", "Winter Weather Advisory",
                              "Extreme Cold Warning", "Extreme Cold Watch", "Cold Weather Advisory",
                              "Freeze Warning", "Freeze Watch", "Frost Advisory"]
        case .air: return ["Air Quality Alert", "Dense Smoke Advisory", "Dust Storm Warning", "Blowing Dust Advisory", "Ashfall Advisory"]
        case .marine: return ["Special Marine Warning", "Hurricane Force Wind Warning", "Storm Warning", "Gale Warning",
                              "Hazardous Seas Warning", "Small Craft Advisory", "Marine Weather Statement"]
        case .special: return ["Dense Fog Advisory", "Freezing Fog Advisory", "Extreme Heat Warning", "Extreme Heat Watch",
                               "Heat Advisory", "High Wind Warning", "High Wind Watch", "Wind Advisory", "Red Flag Warning",
                               "Fire Weather Watch", "Fire Warning", "Special Weather Statement", "Hazardous Weather Outlook",
                               "Tsunami Warning", "Tsunami Watch", "Earthquake Warning", "Volcano Warning", "Avalanche Warning",
                               "Evacuation Immediate", "Shelter In Place Warning", "Civil Emergency Message"]
        }
    }
}

enum RainLevel: Int, CaseIterable, Identifiable {
    case off, light, moderate, heavy
    var id: Int { rawValue }
    var title: String { ["Off", "Light", "Moderate", "Heavy"][rawValue] }
    var detail: String {
        switch self {
        case .off: return "No rain heads-ups"
        case .light: return "Any rain, even a sprinkle"
        case .moderate: return "Steady rain"
        case .heavy: return "Downpours only"
        }
    }
    /// Millimeters per 15 minutes that counts as "rain starting".
    var threshold: Double { [0, 0.1, 0.5, 2.0][rawValue] }
}

enum AlertPrefs {
    private static let d = UserDefaults.standard

    /// Noisy or follow-up products start off; everything else starts on.
    static let offByDefault: Set<String> = ["Hazardous Weather Outlook", "Special Weather Statement", "Severe Weather Statement",
                                            "Hurricane Local Statement", "Rip Current Statement", "Marine Weather Statement",
                                            "Small Craft Advisory", "Frost Advisory", "Flood Advisory", "High Surf Advisory"]
    /// Life-threatening warnings come through even during quiet hours.
    static let breakThrough: Set<String> = ["Tornado Warning", "Extreme Wind Warning", "Flash Flood Warning", "Hurricane Warning",
                                            "Storm Surge Warning", "Typhoon Warning", "Tsunami Warning", "Earthquake Warning",
                                            "Evacuation Immediate", "Shelter In Place Warning", "Civil Emergency Message",
                                            "Snow Squall Warning", "Dust Storm Warning"]

    static func categoryOn(_ c: AlertCategory) -> Bool { !(d.stringArray(forKey: "alertCatsOff") ?? []).contains(c.rawValue) }
    static func setCategory(_ c: AlertCategory, _ on: Bool) {
        var off = Set(d.stringArray(forKey: "alertCatsOff") ?? [])
        if on { off.remove(c.rawValue) } else { off.insert(c.rawValue) }
        d.set(Array(off), forKey: "alertCatsOff")
    }

    static func eventOn(_ e: String) -> Bool {
        if let on = (d.dictionary(forKey: "alertEvents") as? [String: Bool])?[e] { return on }
        return !offByDefault.contains(e)
    }
    static func setEvent(_ e: String, _ on: Bool) {
        var m = (d.dictionary(forKey: "alertEvents") as? [String: Bool]) ?? [:]
        m[e] = on
        d.set(m, forKey: "alertEvents")
    }

    /// Should this NWS event send a notification?
    static func wants(_ event: String) -> Bool {
        guard let c = AlertCategory.allCases.first(where: { $0.events.contains(event) }) else { return false }
        return categoryOn(c) && eventOn(event)
    }

    // Quiet hours (minutes after midnight)
    static var quietOn: Bool {
        get { d.bool(forKey: "quietOn") }
        set { d.set(newValue, forKey: "quietOn") }
    }
    static var quietFrom: Int {
        get { d.object(forKey: "quietFrom") as? Int ?? 22 * 60 }
        set { d.set(newValue, forKey: "quietFrom") }
    }
    static var quietTo: Int {
        get { d.object(forKey: "quietTo") as? Int ?? 7 * 60 }
        set { d.set(newValue, forKey: "quietTo") }
    }
    static func isQuiet(_ date: Date = .now) -> Bool {
        guard quietOn else { return false }
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return quietFrom <= quietTo ? (m >= quietFrom && m < quietTo) : (m >= quietFrom || m < quietTo)
    }

    static var rainLevel: RainLevel {
        get { RainLevel(rawValue: d.object(forKey: "rainLevel") as? Int ?? RainLevel.light.rawValue) ?? .light }
        set { d.set(newValue.rawValue, forKey: "rainLevel") }
    }
}

/// SwiftUI front end for AlertPrefs: changes redraw every page that shows them.
final class AlertSettings: ObservableObject {
    static let shared = AlertSettings()

    func category(_ c: AlertCategory) -> Bool { AlertPrefs.categoryOn(c) }
    func setCategory(_ c: AlertCategory, _ on: Bool) { objectWillChange.send(); AlertPrefs.setCategory(c, on) }
    func event(_ e: String) -> Bool { AlertPrefs.eventOn(e) }
    func setEvent(_ e: String, _ on: Bool) { objectWillChange.send(); AlertPrefs.setEvent(e, on) }

    /// "All", "Some" or "None" for a category's events.
    func summary(_ c: AlertCategory) -> String {
        let n = c.events.filter { AlertPrefs.eventOn($0) }.count
        return n == c.events.count ? "All" : n == 0 ? "None" : "Some"
    }

    var quietOn: Bool {
        get { AlertPrefs.quietOn }
        set { objectWillChange.send(); AlertPrefs.quietOn = newValue }
    }
    var quietFrom: Int {
        get { AlertPrefs.quietFrom }
        set { objectWillChange.send(); AlertPrefs.quietFrom = newValue }
    }
    var quietTo: Int {
        get { AlertPrefs.quietTo }
        set { objectWillChange.send(); AlertPrefs.quietTo = newValue }
    }
    var rainLevel: RainLevel {
        get { AlertPrefs.rainLevel }
        set { objectWillChange.send(); AlertPrefs.rainLevel = newValue }
    }
}
