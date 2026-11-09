# DopplerIQ for iPhone, iPad and Mac

One universal SwiftUI app. iPhone gets the MyRadar-style tabs; iPad and Mac get the pro workspace
(sidebar, map with forecast panel, map collections). It ships as one App Store listing with
**Universal Purchase**, so one subscription works on all three.

- Bundle ID: `io.dialcheck.weather` (permanent, so it has no app name in it; the display name can change any time)
- Minimum: iOS 17, iPadOS 17, macOS 14
- Subscriptions: `io.dialcheck.weather.plus.monthly` ($2.99) and `io.dialcheck.weather.pro.monthly` ($9.99)

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

Testing paid features before App Store Connect is set up: **Settings > Preview plan** (debug builds only).

If Xcode shows a build error, copy the error text and send it to me.

## 2. App Store Connect (once, before submitting)

1. https://appstoreconnect.apple.com > **Apps** > **+** > New App. Platforms: **iOS** and **macOS**.
   Bundle ID: `io.dialcheck.weather`. Name: DopplerIQ.
2. **Subscriptions** > create a subscription group "DopplerIQ" with two auto-renewing products:
   - `io.dialcheck.weather.plus.monthly`, 1 month, $2.99
   - `io.dialcheck.weather.pro.monthly`, 1 month, $9.99 (Pro should be the higher level in the group)
3. App Privacy: the app collects **coarse location** (not linked to you, not used for tracking). Once ads are added,
   AdMob also needs its own privacy answers.
4. Archive in Xcode (**Product > Archive**) once for an iOS device and once for **My Mac**, then **Distribute App** to App Store Connect.

## What's in v1

- Radar loop (NEXRAD mosaic) on Apple Maps, infrared satellite, NWS warning polygons, lightning (Plus)
- Weather card that follows the crosshair, minimize to a pill, save places
- Forecast: alerts, now, 48 hours, 16 days, details
- Dashboard of live NOAA/NHC/SPC/WPC maps (Pro maps locked for Free/Plus)
- Free / Plus / Pro with StoreKit 2, restore purchases
- Ad slots showing a house ad (Google AdMob can be added once you have an AdMob account; AdMob has no Mac support)

Next: the rest of the website's layers (hail, marine, snow, tropics, outages, traffic), route weather, home-screen widgets,
severe-weather notifications, Apple TV.

**Note:** lightning strikes come from the website's `/api/lightning`. While the website is private behind the Netlify login,
that layer stays empty in the app. Everything else talks to NOAA and Open-Meteo directly.
