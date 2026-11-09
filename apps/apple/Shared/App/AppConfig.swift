import Foundation

/// App-wide settings. Change the name here (and PRODUCT_NAME in project.yml) if you rename the app.
enum AppConfig {
    static let displayName = "DopplerIQ"
    /// The website, used for links and for a few shared services (lightning, proxy).
    static let webBase = URL(string: "https://weather.dialcheck.io")!
    /// NWS asks every app to identify itself.
    static let userAgent = "DopplerIQWeather/1.0 (github.com/CRutherford3/weather)"

    /// Auto-renewing subscriptions. Create these exact IDs in App Store Connect (one subscription group).
    static let plusMonthly = "io.dialcheck.weather.plus.monthly"
    static let proMonthly = "io.dialcheck.weather.pro.monthly"

    static let privacyURL = URL(string: "https://weather.dialcheck.io/#settings")!
}
