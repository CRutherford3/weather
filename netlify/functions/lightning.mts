// Lightning strikes from NOAA's GOES-19 Geostationary Lightning Mapper (GLM).
// NOAA posts a new file every 20 seconds to a public bucket. On request, this function reads any files
// it hasn't seen yet, keeps the last 30 minutes of flashes in Netlify Blobs, and returns them as compact JSON:
//   { t: <server time ms>, f: [[lon, lat, timeMs], ...] }
// The CDN caches the answer for 60 seconds, so NOAA is read at most about once a minute no matter how many people look.
import type { Config } from "@netlify/functions";
import { getStore } from "@netlify/blobs";
import h5wasm from "h5wasm/node";
import { writeFile, unlink } from "node:fs/promises";

const BUCKET = "https://noaa-goes19.s3.amazonaws.com";
const KEEP_MS = 30 * 60e3;   // keep 30 minutes of flashes
const MAX_FILES = 15;        // read at most 5 minutes of new files per request

// s20263131448000 -> Date (year, day-of-year, hh mm ss, tenths)
function startTime(key: string): number {
  const m = key.match(/_s(\d{4})(\d{3})(\d{2})(\d{2})(\d{2})(\d)/);
  if (!m) return 0;
  const [, y, doy, hh, mm, ss] = m;
  return Date.UTC(+y, 0, +doy, +hh, +mm, +ss);
}

async function listHour(d: Date): Promise<string[]> {
  const doy = Math.floor((d.getTime() - Date.UTC(d.getUTCFullYear(), 0, 0)) / 864e5);
  const prefix = `GLM-L2-LCFA/${d.getUTCFullYear()}/${String(doy).padStart(3, "0")}/${String(d.getUTCHours()).padStart(2, "0")}/`;
  const r = await fetch(`${BUCKET}/?list-type=2&prefix=${prefix}`, { signal: AbortSignal.timeout(8000) });
  if (!r.ok) return [];
  return [...(await r.text()).matchAll(/<Key>([^<]+\.nc)<\/Key>/g)].map((m) => m[1]);
}

async function readFlashes(key: string, n: number): Promise<number[][]> {
  const r = await fetch(`${BUCKET}/${key}`, { signal: AbortSignal.timeout(10000) });
  if (!r.ok) return [];
  const path = `/tmp/glm_${n}.nc`;
  await writeFile(path, new Uint8Array(await r.arrayBuffer()));
  const f = new h5wasm.File(path, "r");
  try {
    const lat = f.get("flash_lat")?.value as Float32Array | undefined;
    const lon = f.get("flash_lon")?.value as Float32Array | undefined;
    if (!lat || !lon) return [];
    const t = startTime(key);
    const out: number[][] = [];
    for (let i = 0; i < lat.length; i++) out.push([Math.round(lon[i] * 1000) / 1000, Math.round(lat[i] * 1000) / 1000, t]);
    return out;
  } finally {
    f.close();
    unlink(path).catch(() => {});
  }
}

export default async () => {
  await h5wasm.ready;
  const store = getStore("lightning");
  const now = Date.now();
  let state: { seen: string[]; f: number[][] } = { seen: [], f: [] };
  try { state = (await store.get("state", { type: "json" })) || state; } catch { /* first run */ }

  try {
    const keys = [...(await listHour(new Date(now - 36e5))), ...(await listHour(new Date(now)))]
      .filter((k) => startTime(k) > now - KEEP_MS && !state.seen.includes(k));
    const todo = keys.slice(-MAX_FILES);
    const results = await Promise.all(todo.map((k, i) => readFlashes(k, i).catch(() => [])));
    results.forEach((r) => state.f.push(...r));
    state.seen.push(...todo);
  } catch (e) {
    console.error("glm ingest", e);
  }
  state.f = state.f.filter((x) => x[2] > now - KEEP_MS);
  state.seen = state.seen.filter((k) => startTime(k) > now - KEEP_MS - 60e3);
  try { await store.setJSON("state", state); } catch (e) { console.error("blob save", e); }

  return new Response(JSON.stringify({ t: now, f: state.f }), {
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "public, max-age=30",
      "Netlify-CDN-Cache-Control": "public, s-maxage=60, stale-while-revalidate=60",
    },
  });
};

export const config: Config = { path: "/api/lightning" };
