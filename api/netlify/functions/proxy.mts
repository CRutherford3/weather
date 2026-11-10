import type { Config } from "@netlify/functions";

// Fetches public weather feeds that browsers can't read directly (no CORS headers),
// e.g. NHC storm data and SPC outlook shapes. Only these hosts are allowed.
const ALLOWED = new Set([
  "api.weather.gov",
  "www.nhc.noaa.gov",
  "www.spc.noaa.gov",
  "www.wpc.ncep.noaa.gov",
  "mesonet.agron.iastate.edu",
  "earthquake.usgs.gov",
  "services3.arcgis.com",
  "api.rainviewer.com",
  "api.open-meteo.com",
  "air-quality-api.open-meteo.com",
  "geocoding-api.open-meteo.com",
  "mapservices.weather.noaa.gov",
  "services5.arcgis.com",
  "api.wheretheiss.at",
  "tiles.openfreemap.org",
  "router.project-osrm.org",
  "developer.nlr.gov",
  "www.ndbc.noaa.gov",
]);

export default async (req: Request) => {
  const target = new URL(req.url).searchParams.get("url");
  if (!target) return new Response("Missing url", { status: 400 });

  let url: URL;
  try { url = new URL(target); } catch { return new Response("Bad url", { status: 400 }); }
  if (url.protocol !== "https:" || !ALLOWED.has(url.hostname)) {
    return new Response("Host not allowed", { status: 403 });
  }

  try {
    const upstream = await fetch(url, {
      headers: {
        // NWS asks API users to identify their app
        "User-Agent": "DopplerIQWeather/1.0 (github.com/CRutherford3/weather)",
        Accept: req.headers.get("accept") || "application/json, application/geo+json, */*",
      },
      signal: AbortSignal.timeout(20000),
    });
    const body = await upstream.arrayBuffer();
    return new Response(body, {
      status: upstream.status,
      headers: {
        "Content-Type": upstream.headers.get("content-type") || "application/json",
        // map tiles change slowly; cache them at Netlify's edge so each tile only hits NOAA once
        "Cache-Control": /image/.test(upstream.headers.get("content-type") || "") ? "public, max-age=600" : "public, max-age=60",
        "Netlify-CDN-Cache-Control": /image/.test(upstream.headers.get("content-type") || "") ? "public, s-maxage=900, stale-while-revalidate=1800" : "public, s-maxage=60, stale-while-revalidate=120",
      },
    });
  } catch (e) {
    return new Response(`Upstream error: ${(e as Error).message}`, { status: 502 });
  }
};

export const config: Config = { path: "/api/proxy" };
