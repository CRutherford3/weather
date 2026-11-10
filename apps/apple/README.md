# DopplerIQ for iPhone, iPad and Mac

One universal SwiftUI app. iPhone gets the MyRadar-style tabs; iPad and Mac get the pro workspace
(sidebar, map with forecast panel, map collections). It ships as one App Store listing with
**Universal Purchase**, so one subscription works on all three.

- Bundle ID: `io.dialcheck.weather` (permanent, so it has no app name in it; the display name can change any time)
- Minimum: iOS 17, iPadOS 17, macOS 14
- Subscriptions: Plus $2.99/mo or $24.99/yr, Pro $9.99/mo or $59.99/yr (yearly plans start with a 7-day free trial)
- One-time Pro Radar Pack: $6.99 (Doppler radar tools only)
- Home Screen / desktop widgets (target `DopplerIQWidget`, bundle ID `io.dialcheck.weather.widget`)

## 1. Build and run (about 10 minutes)

1. Install **Xcode** from the Mac App Store and open it once to finish setup.
2. Open Terminal and install the project generator:
   ```
   brew install xcodegen
   ```
   No Homebrew yet? Install it first from https://brew.sh
3. Get the code and generate the Xcode project:
   ```
   git clone https://github.com/CRutherford3/weather.git
   cd weather/apps/apple
   xcodegen generate
   open Weather.xcodeproj
   ```
4. In Xcode, click the **Weather** project, then the **Weather** target, then **Signing & Capabilities**,
   and pick your team. (Or paste your Team ID into `DEVELOPMENT_TEAM` in `project.yml` and run `xcodegen generate` again.)
5. Pick a destination at the top (an iPhone simulator, your own iPhone, an iPad, or **My Mac**) and press **Run** (Cmd+R).

Builds run from Xcode start on **Pro** so you can test everything. Switch plans any time in **Settings > Preview plan**. App Store and TestFlight builds ignore this and use real purchases.

If Xcode shows a build error, copy the error text and send it to me.

## 2. App Store Connect (once, before submitting)

0. Turn on the public privacy and support pages: on GitHub open the **weather** repo > **Settings** > **Pages**.
   Under Build and deployment pick **Deploy from a branch**, branch **main**, folder **/docs**, and Save.
   In a minute or two these work (use them in App Store Connect):
   - Privacy Policy URL: https://crutherford3.github.io/weather/privacy.html
   - Support URL: https://crutherford3.github.io/weather/support.html

1. https://appstoreconnect.apple.com > **Apps** > **+** > New App. Platforms: **iOS** and **macOS**.
   Bundle ID: `io.dialcheck.weather`. Name: DopplerIQ.
2. **Subscriptions** > create a subscription group "DopplerIQ" with four auto-renewing products:
   - `io.dialcheck.weather.plus.monthly`, 1 month, $2.99
   - `io.dialcheck.weather.plus.yearly`, 1 year, $24.99
   - `io.dialcheck.weather.pro.monthly`, 1 month, $9.99
   - `io.dialcheck.weather.pro.yearly`, 1 year, $59.99
   In the group's level order put both Pro products above both Plus products.
   On each **yearly** product open **Subscription Prices > Introductory Offers**, add a **Free** offer for **1 week**
   (all countries). The app reads the offer from the App Store and shows "Start 7-day free trial" automatically.
   Then under **In-App Purchases** add a **Non-Consumable**: `io.dialcheck.weather.radarpack`, $6.99, name "Pro Radar Pack"
   (Doppler radar forever: any radar site, 4 tilts, velocity, dual-pol, VIL, echo tops, past and future radar).
   If you already created it at $9.99, just change its price; the ID stays the same.
3. App Privacy: the app collects **coarse location** (not linked to you, not used for tracking). Once ads are added,
   AdMob also needs its own privacy answers.
4. Archive in Xcode (**Product > Archive**) once for an iOS device and once for **My Mac**, then **Distribute App** to App Store Connect.

## Alerts and widgets

- **Weather alerts (Plus):** Settings > Alerts. New NWS warnings for your location and saved places, plus a heads-up
  before rain starts. Checked while the app is open and in the background on iPhone and iPad (iOS picks the exact
  times, usually every 15 to 30 minutes). The Background Modes and task ID are already in `Support/Info.plist`.
- **Widgets (free):** small, medium and large on the Home Screen and Mac desktop, plus Lock Screen widgets on iPhone.
  Long-press a widget > Edit Widget to type a city, or leave it empty to follow your location.

## What's in v1

- Radar loop (NEXRAD mosaic) on Apple Maps, infrared satellite, NWS warning polygons, lightning (Plus)
- Weather card that follows the crosshair, minimize to a pill, save places
- Forecast: alerts, now, 48 hours, 16 days, details
- Customizable dashboard: pages of widgets (forecast, alerts, live radar, any map product, custom images and links), add, remove, resize, reorder. Pages: Free 1, Plus 5, Pro unlimited
- Route Weather (Pro): Apple Maps driving route with the forecast at each checkpoint for your arrival time, plus alerts along the way
- All Maps: grid of live NOAA/NHC/SPC/WPC maps (Pro maps locked for Free/Plus)
- Free / Plus / Pro with StoreKit 2, restore purchases
- Ad slots showing a house ad (Google AdMob can be added once you have an AdMob account; AdMob has no Mac support)

Next: the rest of the website's layers (hail, marine, snow, tropics, outages, traffic), home-screen widgets,
severe-weather notifications, Apple TV.

**Note:** lightning strikes come from the public API site (https://doppleriq-api.netlify.app/api/lightning). Everything else talks to NOAA, IEM and Open-Meteo directly.
