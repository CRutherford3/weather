import { PROXY_PATH } from './config.js';

// ---------- storage ----------
export const store = {
  get(k, d) { try { const v = localStorage.getItem('wx_' + k); return v == null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem('wx_' + k, JSON.stringify(v)); } catch { /* private mode */ } },
};

// ---------- fetching ----------
const canProxy = location.protocol.startsWith('http') && !/^(localhost|127\.)/.test(location.hostname);
const memo = new Map();

async function rawFetch(url, { timeout = 15000, type = 'json', headers } = {}) {
  const c = new AbortController();
  const t = setTimeout(() => c.abort(), timeout);
  try {
    const r = await fetch(url, { signal: c.signal, headers });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    return type === 'text' ? await r.text() : await r.json();
  } finally { clearTimeout(t); }
}

// Try the source directly; if the browser blocks it (CORS) or it fails, retry through our Netlify proxy.
export async function getData(url, opts = {}) {
  const key = url + (opts.type || '');
  const ttl = opts.cache ?? 0;
  const hit = memo.get(key);
  if (ttl && hit && Date.now() - hit.t < ttl) return hit.v;
  let v;
  if (opts.proxyFirst && canProxy) {
    try { v = await rawFetch(`${PROXY_PATH}?url=${encodeURIComponent(url)}`, opts); }
    catch { v = await rawFetch(url, opts); }
  } else {
    try { v = await rawFetch(url, opts); }
    catch (e) {
      if (!canProxy || opts.noProxy) throw e;
      v = await rawFetch(`${PROXY_PATH}?url=${encodeURIComponent(url)}`, opts);
    }
  }
  if (ttl) memo.set(key, { t: Date.now(), v });
  return v;
}
export const NWS_HEADERS = { Accept: 'application/geo+json' };

// ---------- units (all source data is converted from metric) ----------
export const units = { system: store.get('units', 'imperial') };
const imp = () => units.system === 'imperial';
export const U = {
  temp: (c) => (c == null || isNaN(c) ? null : imp() ? c * 9 / 5 + 32 : c),
  wind: (kmh) => (kmh == null || isNaN(kmh) ? null : imp() ? kmh * 0.621371 : kmh),
  windU: () => (imp() ? 'mph' : 'km/h'),
  precip: (mm) => (mm == null ? null : imp() ? mm / 25.4 : mm),
  precipU: () => (imp() ? 'in' : 'mm'),
  vis: (m) => (m == null ? null : imp() ? m / 1609.34 : m / 1000),
  visU: () => (imp() ? 'mi' : 'km'),
  press: (hpa) => (hpa == null ? null : imp() ? hpa * 0.02953 : hpa),
  pressU: () => (imp() ? 'inHg' : 'hPa'),
};
export const fmtT = (c, d = 0) => { const v = U.temp(c); return v == null ? '--' : `${v.toFixed(d)}°`; };
export const fmtW = (k) => { const v = U.wind(k); return v == null ? '--' : `${Math.round(v)} ${U.windU()}`; };
export const fmtP = (mm) => { const v = U.precip(mm); return v == null ? '--' : `${v.toFixed(imp() ? 2 : 1)} ${U.precipU()}`; };

// ---------- weather codes (WMO) ----------
const WMO = {
  0: ['Clear', 'sun', 'moon'], 1: ['Mostly Clear', 'sun-cloud', 'moon-cloud'], 2: ['Partly Cloudy', 'sun-cloud', 'moon-cloud'],
  3: ['Cloudy', 'cloud'], 45: ['Fog', 'fog'], 48: ['Freezing Fog', 'fog'], 51: ['Light Drizzle', 'drizzle'],
  53: ['Drizzle', 'drizzle'], 55: ['Heavy Drizzle', 'rain'], 56: ['Freezing Drizzle', 'sleet'], 57: ['Freezing Drizzle', 'sleet'],
  61: ['Light Rain', 'drizzle'], 63: ['Rain', 'rain'], 65: ['Heavy Rain', 'rain'], 66: ['Freezing Rain', 'sleet'],
  67: ['Freezing Rain', 'sleet'], 71: ['Light Snow', 'snow'], 73: ['Snow', 'snow'], 75: ['Heavy Snow', 'snow'],
  77: ['Snow Grains', 'snow'], 80: ['Showers', 'drizzle'], 81: ['Showers', 'rain'], 82: ['Heavy Showers', 'rain'],
  85: ['Snow Showers', 'snow'], 86: ['Heavy Snow Showers', 'snow'], 95: ['Thunderstorms', 'storm'],
  96: ['Storms w/ Hail', 'storm'], 99: ['Severe Storms w/ Hail', 'storm'],
};
export function wx(code, isDay = 1) {
  const w = WMO[code] || ['--', 'cloud'];
  return { text: w[0], icon: (!isDay && w[2]) ? w[2] : w[1] };
}
// Map NWS shortForecast text to an icon key
export function nwsIcon(text = '', isDay = true) {
  const t = text.toLowerCase();
  if (/thunder|t-storm/.test(t)) return 'storm';
  if (/snow|flurr|blizzard/.test(t)) return 'snow';
  if (/sleet|freezing|ice/.test(t)) return 'sleet';
  if (/rain|shower/.test(t)) return /chance|slight|isolated|scattered/.test(t) ? 'drizzle' : 'rain';
  if (/drizzle/.test(t)) return 'drizzle';
  if (/fog|haze|smoke/.test(t)) return 'fog';
  if (/partly|mostly sunny|mostly clear/.test(t)) return isDay ? 'sun-cloud' : 'moon-cloud';
  if (/cloudy|overcast/.test(t)) return 'cloud';
  if (/sunny|clear|fair/.test(t)) return isDay ? 'sun' : 'moon';
  if (/wind|breezy/.test(t)) return 'wind';
  return isDay ? 'sun-cloud' : 'moon-cloud';
}

// Inline SVG weather icons (no external images needed)
const SVG = {
  sun: '<circle cx="32" cy="32" r="11" fill="#fbbf24"/><g stroke="#fbbf24" stroke-width="4" stroke-linecap="round"><path d="M32 8v6M32 50v6M8 32h6M50 32h6M15 15l4 4M45 45l4 4M15 49l4-4M45 19l4-4"/></g>',
  moon: '<path d="M40 10a22 22 0 1 0 14 34A18 18 0 0 1 40 10z" fill="#c7d2fe"/>',
  cloud: '<path d="M20 48h26a11 11 0 0 0 0-22 15 15 0 0 0-28 4 9 9 0 0 0 2 18z" fill="#94a3b8"/>',
  'sun-cloud': '<circle cx="24" cy="22" r="9" fill="#fbbf24"/><g stroke="#fbbf24" stroke-width="3" stroke-linecap="round"><path d="M24 5v4M7 22h4M12 10l3 3M36 10l-3 3"/></g><path d="M22 52h24a10 10 0 0 0 0-20 13 13 0 0 0-25 4 8 8 0 0 0 1 16z" fill="#cbd5e1"/>',
  'moon-cloud': '<path d="M30 6a15 15 0 1 0 12 24A12 12 0 0 1 30 6z" fill="#c7d2fe"/><path d="M22 54h24a10 10 0 0 0 0-20 13 13 0 0 0-25 4 8 8 0 0 0 1 16z" fill="#94a3b8"/>',
  rain: '<path d="M18 38h28a10 10 0 0 0 0-20 14 14 0 0 0-27 4 8 8 0 0 0-1 16z" fill="#94a3b8"/><g stroke="#38bdf8" stroke-width="3.5" stroke-linecap="round"><path d="M22 44l-3 8M32 44l-3 8M42 44l-3 8"/></g>',
  drizzle: '<path d="M18 38h28a10 10 0 0 0 0-20 14 14 0 0 0-27 4 8 8 0 0 0-1 16z" fill="#a8b4c4"/><g stroke="#7dd3fc" stroke-width="3" stroke-linecap="round"><path d="M24 45l-2 5M38 45l-2 5"/></g>',
  storm: '<path d="M18 36h28a10 10 0 0 0 0-20 14 14 0 0 0-27 4 8 8 0 0 0-1 16z" fill="#64748b"/><path d="M34 36l-8 12h7l-4 10 11-14h-7l4-8z" fill="#facc15"/>',
  snow: '<path d="M18 38h28a10 10 0 0 0 0-20 14 14 0 0 0-27 4 8 8 0 0 0-1 16z" fill="#cbd5e1"/><g fill="#e0f2fe"><circle cx="22" cy="48" r="3"/><circle cx="32" cy="53" r="3"/><circle cx="42" cy="48" r="3"/></g>',
  sleet: '<path d="M18 38h28a10 10 0 0 0 0-20 14 14 0 0 0-27 4 8 8 0 0 0-1 16z" fill="#a8b4c4"/><g stroke="#7dd3fc" stroke-width="3" stroke-linecap="round"><path d="M22 44l-2 6"/></g><g fill="#e0f2fe"><circle cx="34" cy="49" r="3"/><circle cx="44" cy="46" r="2.5"/></g>',
  fog: '<g stroke="#94a3b8" stroke-width="4" stroke-linecap="round"><path d="M12 24h40M8 34h44M14 44h36"/></g>',
  wind: '<g stroke="#94a3b8" stroke-width="4" stroke-linecap="round" fill="none"><path d="M8 26h30a7 7 0 1 0-7-7M8 36h40a7 7 0 1 1-7 7M8 46h20"/></g>',
};
export const icon = (key, size = 40) => `<svg class="wxi" width="${size}" height="${size}" viewBox="0 0 64 64" aria-hidden="true">${SVG[key] || SVG.cloud}</svg>`;

// ---------- misc helpers ----------
export const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
export const $ = (s, el = document) => el.querySelector(s);
export const $$ = (s, el = document) => [...el.querySelectorAll(s)];
export const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
export const compass = (deg) => (deg == null ? '--' : ['N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE', 'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW'][Math.round(deg / 22.5) % 16]);
export const debounce = (fn, ms) => { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; };

// Open-Meteo local time strings look like "2026-11-08T14:00" (already local to the place).
export const hourLabel = (s) => { const h = +s.slice(11, 13); return `${h % 12 || 12}${h < 12 ? 'a' : 'p'}`; };
export const clockLabel = (s) => { const h = +s.slice(11, 13), m = s.slice(14, 16); return `${h % 12 || 12}:${m} ${h < 12 ? 'AM' : 'PM'}`; };
export const dayName = (s, short = true) => {
  const [y, m, d] = s.slice(0, 10).split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d)).toLocaleDateString('en-US', { weekday: short ? 'short' : 'long', timeZone: 'UTC' });
};
export const dateLabel = (s) => { const [y, m, d] = s.slice(0, 10).split('-').map(Number); return new Date(Date.UTC(y, m - 1, d)).toLocaleDateString('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' }); };
export const timeAgo = (ms) => { const m = Math.round((Date.now() - ms) / 60000); return m < 1 ? 'just now' : m < 60 ? `${m} min ago` : `${Math.round(m / 60)} hr ago`; };
export const localTime = (d) => new Date(d).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });

// Temperature color scale (Celsius in, CSS color out)
export function tempColor(c) {
  const stops = [[-30, '#7c3aed'], [-15, '#3b82f6'], [0, '#22d3ee'], [10, '#22c55e'], [20, '#eab308'], [28, '#f97316'], [35, '#ef4444'], [42, '#9f1239']];
  if (c <= stops[0][0]) return stops[0][1];
  for (let i = 1; i < stops.length; i++) if (c <= stops[i][0]) return stops[i][1];
  return stops.at(-1)[1];
}

// Moon phase (good to within a few hours)
export function moonPhase(date = new Date()) {
  const syn = 29.530588853, ref = Date.UTC(2000, 0, 6, 18, 14);
  const age = (((date - ref) / 86400000) % syn + syn) % syn;
  const p = age / syn;
  const names = ['New Moon', 'Waxing Crescent', 'First Quarter', 'Waxing Gibbous', 'Full Moon', 'Waning Gibbous', 'Last Quarter', 'Waning Crescent'];
  const illum = Math.round((1 - Math.cos(2 * Math.PI * p)) / 2 * 100);
  return { name: names[Math.round(p * 8) % 8], illum, age: age.toFixed(1) };
}

export function aqiInfo(v) {
  if (v == null) return { label: '--', color: '#64748b' };
  if (v <= 50) return { label: 'Good', color: '#22c55e' };
  if (v <= 100) return { label: 'Moderate', color: '#eab308' };
  if (v <= 150) return { label: 'Unhealthy for Sensitive Groups', color: '#f97316' };
  if (v <= 200) return { label: 'Unhealthy', color: '#ef4444' };
  if (v <= 300) return { label: 'Very Unhealthy', color: '#a855f7' };
  return { label: 'Hazardous', color: '#7f1d1d' };
}
export function uvInfo(v) {
  if (v == null) return { label: '--', color: '#64748b' };
  if (v < 3) return { label: 'Low', color: '#22c55e' };
  if (v < 6) return { label: 'Moderate', color: '#eab308' };
  if (v < 8) return { label: 'High', color: '#f97316' };
  if (v < 11) return { label: 'Very High', color: '#ef4444' };
  return { label: 'Extreme', color: '#a855f7' };
}

// ---------- toast ----------
export function toast(msg, ms = 3500) {
  let el = $('#toast');
  if (!el) { el = document.createElement('div'); el.id = 'toast'; document.body.appendChild(el); }
  el.textContent = msg; el.classList.add('show');
  clearTimeout(el._t); el._t = setTimeout(() => el.classList.remove('show'), ms);
}
