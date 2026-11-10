import type { Config } from "@netlify/functions";
// @ts-ignore plain JS module
import { FAMILIES, recentKeys, fetchKey, decode, render, bounds, rangeKm, keyTime } from "../../lib/nexrad3.mjs";

// Single-site Doppler radar from NOAA's public Level III archive (unidata-nexrad-level3 on AWS):
// reflectivity and velocity at 4 tilts, dual-pol (correlation coefficient, differential reflectivity,
// precipitation type), digital VIL and echo tops.
//
//   /api/radar?site=MLB&family=ref&tilt=1&lat=28.11&lon=-80.65
//      -> { frames: [{ t, url }], bounds: [w,s,e,n], code, family, tilt }
//   /api/radar?key=MLB_N1B_2026_11_10_14_58_23&family=ref&lat=28.11&lon=-80.65
//      -> image/png (Web Mercator, covers bounds)
const json = (o: unknown, maxAge = 60) => new Response(JSON.stringify(o), {
  headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*", "Cache-Control": `public, max-age=${maxAge}`, "Netlify-CDN-Cache-Control": `public, s-maxage=${maxAge}` },
});

export default async (req: Request) => {
  const q = new URL(req.url).searchParams;
  const family = q.get("family") || "ref";
  if (!FAMILIES[family]) return json({ error: "Unknown product" }, 3600);
  const lat = Number(q.get("lat")), lon = Number(q.get("lon"));
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return json({ error: "lat and lon required" }, 3600);
  const km = rangeKm(family);
  const key = q.get("key");

  try {
    if (key) {
      if (!/^[A-Z0-9]{3}_[A-Z0-9]{3}_\d{4}(_\d\d){5}$/.test(key)) return new Response("Bad key", { status: 400 });
      const size = Math.min(1600, Math.max(256, Number(q.get("size")) || 1024));
      const d = decode(await fetchKey(key));
      const out = render(d, { lat, lon, km, size });
      return new Response(out.png, {
        headers: {
          "Content-Type": "image/png",
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Expose-Headers": "X-Radar-Time, X-Radar-Elevation",
          "X-Radar-Time": d.time.toISOString(),
          "X-Radar-Elevation": d.elev == null ? "" : String(d.elev),
          // a scan never changes once written
          "Cache-Control": "public, max-age=86400, immutable",
          "Netlify-CDN-Cache-Control": "public, s-maxage=604800, immutable",
        },
      });
    }

    const site = (q.get("site") || "").toUpperCase().replace(/^K/, "");
    if (!/^[A-Z0-9]{3}$/.test(site)) return json({ error: "site required, e.g. MLB" }, 3600);
    const tilt = Math.max(0, Math.min(3, Number(q.get("tilt")) || 0));
    const count = Math.max(1, Math.min(20, Number(q.get("frames")) || 12));
    const { code, keys } = await recentKeys(site, family, FAMILIES[family].tilts > 1 ? tilt : 0, count);
    const base = new URL(req.url);
    const frames = keys.map((k: string) => {
      const u = new URL(base.pathname, base.origin);
      u.searchParams.set("key", k); u.searchParams.set("family", family);
      u.searchParams.set("lat", lat.toFixed(3)); u.searchParams.set("lon", lon.toFixed(3));
      return { t: keyTime(k), url: u.toString() };
    });
    return json({ site, family, tilt, code, bounds: bounds(Number(lat.toFixed(3)), Number(lon.toFixed(3)), km), frames }, 60);
  } catch (e) {
    return json({ error: (e as Error).message }, 30);
  }
};

export const config: Config = { path: "/api/radar" };
