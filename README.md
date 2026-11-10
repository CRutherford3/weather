# DopplerIQ

Live radar, severe weather alerts, official forecasts, and a customizable weather dashboard. Works on desktop and phones, and installs to a phone's home screen like an app.

## What's in it

**Radar tab**
- Animated NEXRAD radar (11 frames, 5 minute steps), with a worldwide radar option
- Live NWS warnings and watches drawn as polygons in official NWS colors. Tap one for the full text.
- Satellite (true color, infrared, visible, air mass), temperature and wind across the map, 24 hour rain totals
- Doppler radar at any NEXRAD site (Pro or the Radar Pack): reflectivity and velocity at the 4 lowest tilts, storm-relative velocity, dual-pol correlation coefficient, differential reflectivity and precipitation type, VIL and echo tops
- Rain rate (MRMS), echo tops mosaic, and estimated road weather (dry, wet, slushy, snow, icy, frost risk)
- SPC severe outlook, local storm reports, active hurricanes, earthquakes, wildfires
- Dark, light, roads and satellite base maps. Tap anywhere for that spot's forecast.

**Forecast tab**
- Current conditions measured at the nearest NWS weather station (not a model guess)
- Official NWS hourly and 7-day forecast, extended to 16 days with model guidance
- Next 3 hours of rain in 15 minute steps, air quality, UV, storm energy (CAPE), sun and moon
- Model comparison (NWS Blend, HRRR, GFS, European, German, Canadian) so you can see how confident the forecast is
- The NWS forecasters' own discussion

**Dashboard tab**
- Grid of widgets you can add, remove, resize and drag around (saved per browser)
- Local widgets plus NHC tropical outlooks and storm cones, SPC outlooks and watches, WPC rain forecasts and fronts, CPC long range, GOES satellite loops, NWS radar loops, link list, and custom image or link widgets

## Plans

Free with ads. Plus $2.99/mo or $24.99/yr. Pro $9.99/mo or $59.99/yr. Yearly plans start with a 7-day free trial. One-time Pro Radar Pack $6.99 (Doppler radar tools only). Plus includes severe weather and rain alerts for saved places.

## Data sources

All free, no API keys. Single-site Doppler products come from NOAA's public NEXRAD Level III archive on AWS (`unidata-nexrad-level3`), decoded by `api/lib/nexrad3.mjs` in the `/api/radar` function. Also: National Weather Service (api.weather.gov), Open-Meteo, Iowa Environmental Mesonet, NASA GIBS, NOAA NESDIS, NHC, SPC, WPC, CPC, USGS, NIFC, RainViewer, CARTO and Esri base maps, BigDataCloud reverse geocoding.

## How it's built

Plain HTML, CSS and JavaScript modules in `public/` (no build step), Leaflet for the map, SortableJS for dashboard dragging. Netlify functions live in `api/netlify/functions`: `proxy.mts` fetches feeds that browsers can't read directly (limited to an allow list of weather hosts) and `lightning.mts` serves GOES lightning strikes. The website uses them, and they are also deployed on their own public site (`api/`, Netlify site doppleriq-api) for the iPhone, iPad and Mac apps, so the website itself can stay private.

Rename the app: change `APP_NAME` in `public/js/config.js`, plus the name in `public/manifest.webmanifest` and the `<title>` in `public/index.html`.

## Run locally

```
npx netlify-cli dev
```

## Deploy

Netlify builds from this repo automatically: publish directory `public`, functions in `api/netlify/functions`.

The public API site (doppleriq-api) builds from the same repo with base directory `api`.

### Cloudflare Pages (free)

Connect this repo in Cloudflare: Workers & Pages, Create, Pages, Connect to Git. Use no build command and set the build output directory to `public`. The proxy runs from `functions/api/proxy.js` automatically.
