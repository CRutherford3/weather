import Foundation

/// App-wide settings. Change the name here (and PRODUCT_NAME in project.yml) if you rename the app.
enum AppConfig {
    static let displayName = "DopplerIQ"
    /// App revision shown at the bottom of Settings. Bumped with every change (last number = revision).
    static let version = "1.0.31"
    /// The website, used for links and for a few shared services (lightning, proxy).
    static let webBase = URL(string: "https://weather.dialcheck.io")!
    /// Public data API (lightning strikes, feed proxy). Its own Netlify site, so the website can stay private.
    static let apiBase = URL(string: "https://doppleriq-api.netlify.app")!
    /// NWS asks every app to identify itself.
    static let userAgent = "DopplerIQWeather/1.0 (github.com/CRutherford3/weather)"

    /// Auto-renewing subscriptions. Create these exact IDs in App Store Connect (one subscription group).
    static let plusMonthly = "io.dialcheck.weather.plus.monthly"
    static let plusYearly = "io.dialcheck.weather.plus.yearly"
    static let proMonthly = "io.dialcheck.weather.pro.monthly"
    static let proYearly = "io.dialcheck.weather.pro.yearly"
    static let plusIDs: Set<String> = [plusMonthly, plusYearly]
    static let proIDs: Set<String> = [proMonthly, proYearly]
    /// One-time purchase (non-consumable): Doppler radar features forever (single sites, tilts, velocity,
    /// dual-pol, VIL, echo tops, past and future radar). Not every layer, so it never undercuts a subscription.
    static let radarPack = "io.dialcheck.weather.radarpack"

    /// Public pages (GitHub Pages from the repo's docs folder). Use these same links in App Store Connect.
    static let privacyURL = URL(string: "https://crutherford3.github.io/weather/privacy.html")!
    static let supportURL = URL(string: "https://crutherford3.github.io/weather/support.html")!
}
