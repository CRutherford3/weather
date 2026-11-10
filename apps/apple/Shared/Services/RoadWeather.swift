import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Road conditions estimated from the last few hours of weather at a spot (same rules as the website):
/// freezing rain or rain below freezing = icy, recent snow = snow or slush, recent rain = wet.
enum RoadWeather: Equatable {
    case dry, wet, slush, snow, ice, frost

    var label: String {
        switch self {
        case .dry: return "Dry"
        case .wet: return "Wet"
        case .slush: return "Slushy"
        case .snow: return "Snow"
        case .ice: return "Icy"
        case .frost: return "Frost risk"
        }
    }
    var color: PColor {
        switch self {
        case .dry: return PColor(red: 0.09, green: 0.64, blue: 0.29, alpha: 1)
        case .wet: return PColor(red: 0.15, green: 0.39, blue: 0.92, alpha: 1)
        case .slush: return PColor(red: 0.49, green: 0.23, blue: 0.93, alpha: 1)
        case .snow: return PColor(red: 0.9, green: 0.91, blue: 0.92, alpha: 1)
        case .ice: return PColor(red: 0.86, green: 0.15, blue: 0.47, alpha: 1)
        case .frost: return PColor(red: 0.02, green: 0.71, blue: 0.83, alpha: 1)
        }
    }

    /// `hourly` from Open-Meteo with temperature_2m, dew_point_2m, precipitation, snowfall, weather_code
    /// (3 past hours plus the current hour, GMT times).
    static func state(_ h: [String: Any]) -> RoadWeather? {
        guard let times = h["time"] as? [String], !times.isEmpty else { return nil }
        let nums: (String) -> [Double] = { k in (h[k] as? [Any] ?? []).map { ($0 as? NSNumber)?.doubleValue ?? 0 } }
        let temp = nums("temperature_2m"), dew = nums("dew_point_2m"), pr = nums("precipitation"), sn = nums("snowfall"), code = nums("weather_code").map(Int.init)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm"; f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX")
        let now = Date()
        var i = (times.firstIndex { (f.date(from: $0) ?? .distantPast) > now } ?? times.count) - 1
        if i < 0 { i = times.count - 1 }
        guard temp.indices.contains(i) else { return nil }
        let lo = max(0, i - 3)
        let p3 = pr.indices.contains(i) ? pr[lo...i].reduce(0, +) : 0
        let s3 = sn.indices.contains(i) ? sn[lo...i].reduce(0, +) : 0
        let t = temp[i], c = code.indices.contains(i) ? code[i] : 0
        if [56, 57, 66, 67].contains(c) || (t <= 0 && p3 >= 0.2 && s3 < 0.1) { return .ice }
        if s3 >= 0.5 || [71, 73, 75, 77, 85, 86].contains(c) { return t > 1 ? .slush : .snow }
        if p3 >= 0.2 || (pr.indices.contains(i) && pr[i] > 0) { return t <= 1 ? .ice : .wet }
        if t <= 1, dew.indices.contains(i), dew[i] >= t - 1 { return .frost }
        return .dry
    }
}
