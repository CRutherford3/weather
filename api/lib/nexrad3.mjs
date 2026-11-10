// NEXRAD Level III decoder and renderer (no browser code, runs in Netlify functions and Node).
// Reads the "digital radial" products (packet 16): super-res reflectivity (153), base velocity (99, 154),
// differential reflectivity (159), correlation coefficient (161), hydrometeor classification (165),
// digital VIL (134) and enhanced echo tops (135). Output: an indexed PNG in Web Mercator, so it lines up
// on MapLibre (image source) and Apple MapKit (overlay) with four corner coordinates.
import { deflateSync } from 'node:zlib';
import Bunzip from 'seek-bzip';

// Product families the apps offer. Tilt t (0-3) goes in place of "#".
export const FAMILIES = {
  ref: { name: 'Reflectivity', codes: ['N#B', 'N#Q'], tilts: 4 },
  vel: { name: 'Velocity', codes: ['N#G', 'N#U'], tilts: 4 },
  cc: { name: 'Correlation Coefficient', codes: ['N#C'], tilts: 4 },
  zdr: { name: 'Differential Reflectivity', codes: ['N#X'], tilts: 4 },
  hhc: { name: 'Precipitation Type', codes: ['N#H'], tilts: 4 },
  vil: { name: 'VIL', codes: ['DVL'], tilts: 1 },
  eet: { name: 'Echo Tops', codes: ['EET'], tilts: 1 },
};
// Gate size (km) and the range we draw (km) for each product code.
const GEOM = { 153: [0.25, 460], 94: [1, 460], 99: [0.25, 300], 154: [0.25, 300], 159: [0.25, 300], 161: [0.25, 300], 165: [0.25, 300], 134: [1, 460], 135: [1, 345] };
export const rangeKm = (family) => ({ ref: 460, vil: 460, eet: 345 }[family] || 300);
export const codesFor = (family, tilt = 0) => (FAMILIES[family]?.codes || []).map((c) => c.replace('#', String(Math.max(0, Math.min(3, tilt | 0)))));

// ---------- decode ----------
export function decode(buf) {
  const u8 = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  let dv = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
  // Skip the WMO/AWIPS text header: find the message header (product code, then the -1 divider of the description block)
  let s = -1;
  for (let i = 0; i < Math.min(200, u8.length - 140); i++) {
    const code = dv.getInt16(i);
    if (GEOM[code] && dv.getInt16(i + 18) === -1) { s = i; break; }
  }
  if (s < 0) throw new Error('Not a supported Level III product');
  const hw = (n) => dv.getInt16(s + (n - 1) * 2);
  const uhw = (n) => dv.getUint16(s + (n - 1) * 2);
  const code = hw(1);
  const lat = dv.getInt32(s + 20) / 1000, lon = dv.getInt32(s + 24) / 1000;
  const volDate = hw(21), volTime = dv.getInt32(s + 42);
  const time = new Date(((volDate - 1) * 86400 + volTime) * 1000);
  const elev = [153, 99, 154, 159, 161, 165, 94].includes(code) ? hw(30) / 10 : null;
  const thr = Array.from({ length: 16 }, (_, k) => uhw(31 + k));
  const symOff = dv.getInt32(s + 108) * 2; // bytes from the message header
  let body, bodyStart;
  if (hw(51) === 1 && u8[s + 120] === 0x42 && u8[s + 121] === 0x5a) { // "BZ": bzip2 after the description block
    body = new Uint8Array(Bunzip.decode(Buffer.from(u8.subarray(s + 120))));
    bodyStart = 120;
  } else { body = u8.subarray(s); bodyStart = 0; }
  const bdv = new DataView(body.buffer, body.byteOffset, body.byteLength);
  let p = symOff - bodyStart;
  if (bdv.getInt16(p) !== -1 || bdv.getInt16(p + 2) !== 1) { // be forgiving about the offset
    p = -1;
    for (let i = 0; i < Math.min(400, body.length - 4); i += 2) if (bdv.getInt16(i) === -1 && bdv.getInt16(i + 2) === 1) { p = i; break; }
    if (p < 0) throw new Error('Symbology block not found');
  }
  p += 10; // divider, block id, length, number of layers
  p += 6;  // layer divider, layer length
  const packet = bdv.getUint16(p);
  if (packet !== 16) throw new Error(`Unsupported packet ${packet}`);
  const firstBin = bdv.getInt16(p + 2), nBins = bdv.getInt16(p + 4), nRad = bdv.getInt16(p + 12);
  p += 14;
  const radials = [];
  for (let r = 0; r < nRad && p + 6 <= body.length; r++) {
    const nb = bdv.getInt16(p), start = bdv.getInt16(p + 2) / 10, delta = bdv.getInt16(p + 4) / 10;
    radials.push({ start, delta, data: body.subarray(p + 6, p + 6 + Math.min(nb, nBins)) });
    p += 6 + nb;
  }
  const [gate] = GEOM[code];
  return { code, lat, lon, time, elev, thr, firstBin, nBins, gate, radials };
}

// ---------- data levels to values ----------
const f32 = (hi, lo) => { const b = new DataView(new ArrayBuffer(4)); b.setUint16(0, hi); b.setUint16(2, lo); return b.getFloat32(0); };
const f16 = (v) => { const frac = v & 0x3ff, exp = (v >> 10) & 0x1f, sign = v >> 15; let x = exp ? 2 ** (exp - 16) * (1 + frac / 1024) : frac / 512; return sign ? -x : x; };
const s16 = (v) => (v > 32767 ? v - 65536 : v);
/** Value for each of the 256 data levels (null = no data). */
export function levelValues(d) {
  const t = d.thr, out = new Array(256).fill(null);
  switch (d.code) {
    case 153: case 94: case 99: case 154: { // min, increment (tenths)
      const min = s16(t[0]) / 10, inc = t[1] / 10;
      for (let i = 2; i < 256; i++) out[i] = min + (i - 2) * inc;
      if (d.code !== 153 && d.code !== 94) out[1] = 'RF'; // range folded
      break;
    }
    case 159: case 161: { // float scale and offset
      const scale = f32(t[0], t[1]), off = f32(t[2], t[3]);
      for (let i = 2; i < 256; i++) out[i] = (i - off) / scale;
      break;
    }
    case 165: for (let i = 10; i < 256; i++) out[i] = Math.floor(i / 10); break; // category 1-14
    case 134: { // digital VIL: linear then logarithmic
      const ls = f16(t[0]), lo = f16(t[1]), logStart = t[2], gs = f16(t[3]), go = f16(t[4]);
      for (let i = 2; i < 255; i++) out[i] = i < logStart ? (i - lo) / ls : Math.exp((i - go) / gs);
      break;
    }
    case 135: { // echo tops, kft
      const mask = t[0], scale = t[1], off = t[2];
      for (let i = 2; i < 256; i++) out[i] = (i & mask) / scale - off;
      break;
    }
  }
  return out;
}

// ---------- colors ----------
const hex = (h, a = 255) => [parseInt(h.slice(1, 3), 16), parseInt(h.slice(3, 5), 16), parseInt(h.slice(5, 7), 16), a];
// Piecewise color ramp: [[value, '#rrggbb'], ...]
const ramp = (stops) => (v) => {
  if (v < stops[0][0]) return null;
  for (let i = stops.length - 1; i >= 0; i--) if (v >= stops[i][0]) return stops[i][1];
  return null;
};
const REF = ramp([[5, '#04e9e7'], [10, '#019ff4'], [15, '#0300f4'], [20, '#02fd02'], [25, '#01c501'], [30, '#008e00'], [35, '#fdf802'], [40, '#e5bc00'], [45, '#fd9500'], [50, '#fd0000'], [55, '#d40000'], [60, '#bc0000'], [65, '#f800fd'], [70, '#9854c6'], [75, '#fdfdfd']]);
// Velocity in knots: green toward the radar, red away
const VEL = (kt) => {
  const a = Math.abs(kt);
  if (a < 3) return '#8a8a8a';
  const g = ['#9ff59f', '#4be04b', '#00c000', '#008a00', '#005c00', '#023a02'], r = ['#f5b8b8', '#ef7070', '#e01f1f', '#b30000', '#7d0000', '#4d0000'];
  const k = a < 10 ? 0 : a < 20 ? 1 : a < 30 ? 2 : a < 45 ? 3 : a < 64 ? 4 : 5;
  return kt < 0 ? g[k] : r[k];
};
const CC = ramp([[0.2, '#130c5a'], [0.45, '#2c26c9'], [0.6, '#6b6bf0'], [0.7, '#5ad2f0'], [0.75, '#26b04a'], [0.8, '#8ae234'], [0.85, '#f6e93f'], [0.9, '#f5a623'], [0.93, '#f26c22'], [0.95, '#e5281c'], [0.97, '#a8101c'], [0.99, '#d63ad6'], [1.02, '#f2c8f2']]);
const ZDR = ramp([[-8, '#3a3a3a'], [-2, '#6f6f6f'], [-0.5, '#b0b0b0'], [0, '#1e3cff'], [0.5, '#2fa3ff'], [1, '#2fd56b'], [1.5, '#9be22d'], [2, '#f6e93f'], [2.5, '#f5a623'], [3, '#f26c22'], [4, '#e5281c'], [5, '#b0103c'], [6, '#f0b0f0']]);
// Hydrometeor classes 1-14: BI GC IC DS WS RA HR BD GR HA LH GH UK RF
const HHC = [null, '#9c9c9c', '#6b4b2b', '#e8a5ff', '#8fd3ff', '#3e70ff', '#2fd56b', '#0a8a2a', '#f6e93f', '#f5a623', '#e5281c', '#a8101c', '#ff2ee0', '#5c5c5c', '#6a2d8f'];
export const HHC_LABELS = ['', 'Biological', 'Ground clutter', 'Ice crystals', 'Dry snow', 'Wet snow', 'Rain', 'Heavy rain', 'Big drops', 'Graupel', 'Hail and rain', 'Large hail', 'Giant hail', 'Unknown', 'Range folded'];
const VIL = ramp([[0.5, '#5ad2f0'], [5, '#2c8fd6'], [10, '#26b04a'], [15, '#8ae234'], [20, '#f6e93f'], [25, '#f5a623'], [30, '#f26c22'], [40, '#e5281c'], [50, '#a8101c'], [60, '#d63ad6'], [70, '#fdfdfd']]);
const EET = ramp([[5, '#5ad2f0'], [10, '#2c8fd6'], [15, '#26b04a'], [20, '#8ae234'], [25, '#f6e93f'], [30, '#f5c823'], [35, '#f5a623'], [40, '#f26c22'], [45, '#e5281c'], [50, '#a8101c'], [55, '#d63ad6'], [60, '#fdfdfd']]);

/** RGBA for each of the 256 data levels. */
export function palette(d) {
  const vals = levelValues(d);
  return vals.map((v) => {
    if (v == null) return [0, 0, 0, 0];
    if (v === 'RF') return hex('#7b3fa8', 200);
    let c = null;
    switch (d.code) {
      case 153: case 94: c = REF(v); break;
      case 99: case 154: c = VEL(v * 1.94384); break;
      case 161: c = CC(v); break;
      case 159: c = ZDR(v); break;
      case 165: c = HHC[v] || null; break;
      case 134: c = VIL(v); break;
      case 135: c = v > 0 ? EET(v) : null; break;
    }
    return c ? hex(c) : [0, 0, 0, 0];
  });
}

// ---------- render ----------
const R = 6378137;
const mercY = (lat) => R * Math.log(Math.tan(Math.PI / 4 + (lat * Math.PI) / 360));
const latFromY = (y) => (2 * Math.atan(Math.exp(y / R)) - Math.PI / 2) * 180 / Math.PI;
/** [west, south, east, north] of the image for a radar centered at lat/lon. */
export function bounds(lat, lon, km) {
  const dLat = km / 110.574, dLon = km / (111.32 * Math.cos((lat * Math.PI) / 180));
  return [+(lon - dLon).toFixed(4), +(lat - dLat).toFixed(4), +(lon + dLon).toFixed(4), +(lat + dLat).toFixed(4)];
}

/** Draws the decoded product as an indexed PNG covering bounds(lat, lon, km). */
export function render(d, { lat = d.lat, lon = d.lon, km, size = 1024 } = {}) {
  const [w, s, e, n] = bounds(lat, lon, km || GEOM[d.code][1]);
  const W = size, H = size;
  // azimuth (0.1 degree) -> radial index
  const azIdx = new Int32Array(3600).fill(-1);
  d.radials.forEach((r, k) => {
    const a0 = Math.round(r.start * 10), span = Math.max(1, Math.round((r.delta || 1) * 10));
    for (let j = 0; j < span; j++) azIdx[(((a0 + j) % 3600) + 3600) % 3600] = k;
  });
  const cosEl = Math.cos(((d.elev || 0) * Math.PI) / 180);
  const kmLat = 110.574, kmLon = 111.32 * Math.cos((d.lat * Math.PI) / 180);
  const y0 = mercY(n), y1 = mercY(s);
  const px = new Uint8Array((W + 1) * H); // one filter byte per row
  const gateKm = d.gate * cosEl, first = d.firstBin;
  for (let row = 0; row < H; row++) {
    const plat = latFromY(y0 + ((row + 0.5) / H) * (y1 - y0));
    const dy = (plat - d.lat) * kmLat;
    const o = row * (W + 1) + 1;
    for (let col = 0; col < W; col++) {
      const plon = w + ((col + 0.5) / W) * (e - w);
      const dx = (plon - d.lon) * kmLon;
      const rng = Math.sqrt(dx * dx + dy * dy);
      const bin = Math.floor(rng / gateKm) - first;
      if (bin < 0 || bin >= d.nBins) continue;
      let az = Math.atan2(dx, dy) * 1800 / Math.PI; if (az < 0) az += 3600;
      const k = azIdx[Math.floor(az) % 3600];
      if (k < 0) continue;
      const data = d.radials[k].data;
      if (bin < data.length) px[o + col] = data[bin];
    }
  }
  return { png: png(W, H, px, palette(d)), bounds: [w, s, e, n] };
}

// ---------- minimal indexed PNG writer ----------
const CRC = new Int32Array(256).map((_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c; });
const crc32 = (b) => { let c = -1; for (let i = 0; i < b.length; i++) c = CRC[(c ^ b[i]) & 255] ^ (c >>> 8); return (c ^ -1) >>> 0; };
function chunk(type, data) {
  const out = Buffer.alloc(12 + data.length);
  out.writeUInt32BE(data.length, 0); out.write(type, 4, 'ascii'); Buffer.from(data).copy(out, 8);
  out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
  return out;
}
function png(W, H, rows, pal) {
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(W, 0); ihdr.writeUInt32BE(H, 4); ihdr[8] = 8; ihdr[9] = 3;
  const plte = Buffer.alloc(768), trns = Buffer.alloc(256);
  pal.forEach((c, i) => { plte[i * 3] = c[0]; plte[i * 3 + 1] = c[1]; plte[i * 3 + 2] = c[2]; trns[i] = c[3]; });
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('PLTE', plte), chunk('tRNS', trns), chunk('IDAT', deflateSync(Buffer.from(rows), { level: 6 })), chunk('IEND', Buffer.alloc(0))]);
}

// ---------- S3 archive (unidata-nexrad-level3, public) ----------
const BUCKET = 'https://unidata-nexrad-level3.s3.amazonaws.com';
const pad = (x) => String(x).padStart(2, '0');
const hourPrefix = (site, code, d) => `${site}_${code}_${d.getUTCFullYear()}_${pad(d.getUTCMonth() + 1)}_${pad(d.getUTCDate())}_${pad(d.getUTCHours())}`;
async function listPrefix(prefix) {
  const r = await fetch(`${BUCKET}/?list-type=2&prefix=${encodeURIComponent(prefix)}`, { signal: AbortSignal.timeout(10000) });
  if (!r.ok) return [];
  const xml = await r.text();
  return [...xml.matchAll(/<Key>([^<]+)<\/Key>/g)].map((m) => m[1]);
}
export const keyTime = (k) => { const m = k.match(/_(\d{4})_(\d\d)_(\d\d)_(\d\d)_(\d\d)_(\d\d)$/); return m ? Date.UTC(+m[1], m[2] - 1, +m[3], +m[4], +m[5], +m[6]) : 0; };
/** Newest keys (oldest first) for a site and family/tilt, trying each product code in turn. */
export async function recentKeys(site, family, tilt, count = 12, now = Date.now()) {
  for (const code of codesFor(family, tilt)) {
    const hours = [0, 1, 2].map((h) => hourPrefix(site, code, new Date(now - h * 3600e3)));
    const lists = await Promise.all(hours.map(listPrefix));
    const keys = lists.flat().sort();
    if (keys.length) return { code, keys: keys.slice(-count) };
  }
  return { code: null, keys: [] };
}
export async function fetchKey(key) {
  const r = await fetch(`${BUCKET}/${encodeURIComponent(key)}`, { signal: AbortSignal.timeout(15000) });
  if (!r.ok) throw new Error(`S3 ${r.status}`);
  return new Uint8Array(await r.arrayBuffer());
}
