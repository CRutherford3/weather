// Radar map built on MapLibre GL (vector maps, globe view when zoomed out).
// Layers: radar loop, satellite, warnings, fronts, lightning, winds, temps, air quality, rain totals,
// SPC outlook, mesoscale discussions, storm reports, hurricanes, drought, earthquakes, wildfires, ISS.
import { alertColor, DBZ_LEGEND } from './config.js';
import { store, getData, $, $$, esc, U, fmtT, fmtW, compass, toast, tempColor, wx, icon, localTime, aqiInfo, openSheet, closeSheet } from './util.js';
import { feeds, gridPoints, quickPoint, aqGrid, radarSites, nearestSite, siteScans } from './api.js';
import { KEYS } from './config.js';
import { buoys as buoyList, buoyNames } from './marine.js';
import { canLayer, tierOf, badge, gate } from './plan.js';

const ml = window.maplibregl;
const ESRI = 'https://services.arcgisonline.com/ArcGIS/rest/services';
const IEM = 'https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0';

// Map backgrounds: the same list as the app. Place names sit in a separate layer drawn above the radar.
const GLYPHS = 'https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf';
const zxy = (t) => t.replace('{z}', '4').replace('{x}', '4').replace('{y}', '6');
function rasterStyle(name, blurb, base, labels, maxzoom = 16, attribution = 'Tiles &copy; Esri') {
  return {
    name, blurb, thumb: zxy(base),
    url: {
      version: 8, glyphs: GLYPHS,
      sources: {
        img: { type: 'raster', tiles: [base], tileSize: 256, maxzoom, attribution },
        ...(labels ? { ref: { type: 'raster', tiles: [labels], tileSize: 256, maxzoom } } : {}),
      },
      layers: [{ id: 'img', type: 'raster', source: 'img' }, ...(labels ? [{ id: 'ref', type: 'raster', source: 'ref' }] : [])],
    },
  };
}
export const STYLES = {
  dark: rasterStyle('Grayscale', 'Dark gray, radar pops', `${ESRI}/Canvas/World_Dark_Gray_Base/MapServer/tile/{z}/{y}/{x}`, `${ESRI}/Canvas/World_Dark_Gray_Reference/MapServer/tile/{z}/{y}/{x}`),
  light: rasterStyle('Daylight', 'Light gray', `${ESRI}/Canvas/World_Light_Gray_Base/MapServer/tile/{z}/{y}/{x}`, `${ESRI}/Canvas/World_Light_Gray_Reference/MapServer/tile/{z}/{y}/{x}`),
  roads: rasterStyle('Roads', 'Street map', `${ESRI}/World_Street_Map/MapServer/tile/{z}/{y}/{x}`, null, 18),
  aerial: rasterStyle('Aerial', 'Satellite photos', `${ESRI}/World_Imagery/MapServer/tile/{z}/{y}/{x}`, `${ESRI}/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}`, 18),
  topo: rasterStyle('Topography', 'Terrain and elevation', `${ESRI}/World_Topo_Map/MapServer/tile/{z}/{y}/{x}`, null, 18),
  // OpenFreeMap vector styles (CARTO's raster tiles need a key on the web)
  proDark: { name: 'Pro Dark', blurb: 'Black, minimal', url: 'https://tiles.openfreemap.org/styles/dark' },
  proLight: { name: 'Pro Light', blurb: 'White, minimal', url: 'https://tiles.openfreemap.org/styles/positron' },
  vfr: rasterStyle('VFR Sectional', 'FAA aviation chart', 'https://tiles.arcgis.com/tiles/ssFJjBXIUyZDrSYZ/arcgis/rest/services/VFR_Sectional/MapServer/tile/{z}/{y}/{x}', null, 12, 'FAA'),
};
// Older saved choices
const LEGACY_STYLE = { streets: 'roads', satellite: 'aerial' };

const DEFAULT_LAYERS = { radar: true, alerts: true, places: true, fronts: true, sat: false, lightning: false, winds: false, temps: false, aqi: false, rain: false, spc: false, mcd: false, lsr: false, sites: false, twoutlook: false, windprob: false, surgerisk: false, snowdepth: false, snowprob: false, snowcover: false, buoys: false, outages: false, waves: false, sst: false, charts: false, rigs: false, cams: false, hail: false, rainrate: false, echotops: false, road: false, traffic: false, tropics: true, drought: false, quakes: false, fires: false, iss: false };
export const S = {
  style: ((v) => LEGACY_STYLE[v] || v)(store.get('mapStyle', 'auto')),
  radarSrc: store.get('radarSrc', 'us'),
  hiDef: store.get('radarHiDef', true), // US mosaic: Hi-Def (cleaned and smoothed) or Standard (raw) // 'site' only while the Doppler layer is on (see buildRadar)
  opacity: store.get('opacity', 0.75),
  speed: store.get('speed', 450),
  sat: store.get('satType', 'ir'),
  rain: store.get('rainType', '24h'),
  hail: store.get('hailHours', '72'),
  surgeCat: store.get('surgeCat', '3'),
  snowDay: store.get('snowDay', '1'), snowAmt: store.get('snowAmt', '4'),
  site: store.get('radarSite', null),     // e.g. 'MLB' for KMLB
  siteProd: store.get('siteProd', 'N0B') === 'N0S' || store.get('siteProd', 'N0B') === 'N0U' ? 'N0S' : 'N0B', // legacy
  // Doppler product: ref, vel, srv (storm relative), cc, zdr, hhc, vil, eet. Tilt 0-3 (lowest four scans).
  siteFam: store.get('siteFam', store.get('siteProd', 'N0B') === 'N0S' ? 'srv' : 'ref'),
  tilt: +store.get('siteTilt', 0) || 0,
  layers: Object.assign({}, DEFAULT_LAYERS, store.get('layers2', {})),
};
const save = () => { store.set('layers2', S.layers); store.set('mapStyle', S.style); store.set('radarSrc', S.radarSrc); store.set('radarHiDef', S.hiDef); store.set('opacity', S.opacity); store.set('speed', S.speed); store.set('satType', S.sat); store.set('rainType', S.rain); store.set('hailHours', S.hail); store.set('surgeCat', S.surgeCat); store.set('snowDay', S.snowDay); store.set('snowAmt', S.snowAmt); store.set('radarSite', S.site); store.set('siteProd', S.siteProd); store.set('siteFam', S.siteFam); store.set('siteTilt', S.tilt); };

export const LAYER_GROUPS = [
  // Pro group: single-site Doppler radar (also in the Radar Pack), then marine and space layers
  ['Pro: Radar, Marine & Space', [
    ['sites', 'Doppler Radar (tap a site)', 'dopplerOpts'],
    ['buoys', 'Buoys & Seas (live)'], ['waves', 'Wave Height Forecast'], ['cams', 'Buoy Cameras'], ['sst', 'Sea Surface Temperature'], ['charts', 'Nautical Charts (NOAA)'], ['rigs', 'Offshore Oil & Gas Platforms'],
    ['iss', 'ISS Orbital Tracking'],
  ], 'pro'],
  ['Radar & Satellite', [
    ['radar', 'Radar', 'radarOpts'], ['sat', 'Satellite Clouds', 'satOpts'], ['lightning', 'Lightning'], ['rainrate', 'Rain Rate (now)'], ['rain', 'Rain Totals', 'rainOpts'], ['echotops', 'Echo Tops (storm height)'],
  ]],
  ['Severe Weather', [
    ['alerts', 'Warnings & Watches'], ['spc', 'SPC Severe Outlook'], ['mcd', 'Mesoscale Discussions'], ['lsr', 'Storm Reports (Hail, Wind, Tornado)'],
    ['hail', 'Hail Map', 'hailOpts'],
  ]],
  ['Conditions', [
    ['fronts', 'Fronts & Pressure'], ['winds', 'Winds (animated)'], ['temps', 'Temperatures'], ['road', 'Road Weather (estimated)'], ['aqi', 'Air Quality'],
  ]],
  ['Tropics', [['tropics', 'Hurricane Tracker'], ['twoutlook', 'Development Areas (2 & 7 day)'], ['windprob', 'Tropical Storm Wind Chances'], ['surgerisk', 'Storm Surge Risk', 'surgeOpts']]],
  ['Snow & Ice', [['snowdepth', 'Snow Depth Now'], ['snowprob', 'Snow & Ice Chances', 'snowOpts'], ['snowcover', 'Snow & Sea Ice Cover']]],
  ['More', [
    ['places', 'My Places'], ['outages', 'Power Outages (partial US)'], ['traffic', 'Traffic (US roads)'], ['drought', 'Droughts'], ['quakes', 'Earthquakes'], ['fires', 'Wildfires'],
  ]],
];

let map, themeFn, H = {}, styleReady = false;
const active = {};
const clickers = []; // [layerId, handler]

// ================= init =================
// ================= Hi-Def radar =================
// Same recipe as the app: drop the light-blue returns (drizzle, clutter, speckle), clear isolated specks,
// then blur and firm up the edges so storms become smooth rounded shapes instead of pixel blocks.
function hiDefPixels(d, w, h) {
  const n = w * h;
  for (let k = 0; k < n; k++) { const i = k * 4; if (d[i + 3] > 0 && d[i] < 90 && d[i + 2] > 130 && d[i + 2] > d[i + 1] - 40) d[i + 3] = 0; }
  const filled = new Uint8Array(n);
  for (let pass = 0; pass < 2; pass++) {
    for (let k = 0; k < n; k++) filled[k] = d[k * 4 + 3] > 0 ? 1 : 0;
    for (let y = 1; y < h - 1; y++) for (let x = 1; x < w - 1; x++) {
      const k = y * w + x; if (!filled[k]) continue;
      const c = filled[k - w - 1] + filled[k - w] + filled[k - w + 1] + filled[k - 1] + filled[k + 1] + filled[k + w - 1] + filled[k + w] + filled[k + w + 1];
      if (c < 3) d[k * 4 + 3] = 0;
    }
  }
  // Premultiply, blur (three box passes ~ Gaussian sigma 2.6), then firm up the alpha
  const f = new Float32Array(n * 4);
  for (let k = 0; k < n; k++) { const i = k * 4, a = d[i + 3] / 255; f[i] = d[i] * a; f[i + 1] = d[i + 1] * a; f[i + 2] = d[i + 2] * a; f[i + 3] = d[i + 3]; }
  const tmp = new Float32Array(n * 4), r = 2, div = 1 / (2 * r + 1);
  // Box blur along rows (step 4) or columns (step w*4), edges clamped so tiles join without seams
  const box = (src, dst, horiz) => {
    const len = horiz ? w : h, lines = horiz ? h : w, step = horiz ? 4 : w * 4;
    for (let l = 0; l < lines; l++) {
      const start = horiz ? l * w * 4 : l * 4, last = start + (len - 1) * step;
      for (let ch = 0; ch < 4; ch++) {
        const s0 = start + ch, sl = last + ch;
        let sum = src[s0] * (r + 1);
        for (let j = 1; j <= r; j++) sum += src[s0 + Math.min(j, len - 1) * step];
        for (let j = 0, o = s0; j < len; j++, o += step) {
          dst[o] = sum * div;
          const add = j + r + 1 < len ? s0 + (j + r + 1) * step : sl;
          const sub = j - r > 0 ? s0 + (j - r) * step : s0;
          sum += src[add] - src[sub];
        }
      }
    }
  };
  for (let pass = 0; pass < 3; pass++) { box(f, tmp, true); box(tmp, f, false); }
  for (let k = 0; k < n; k++) {
    const i = k * 4, a = f[i + 3];
    const na = Math.max(0, Math.min(255, a * 1.9 - 0.32 * 255));
    if (a < 1 || na <= 0) { d[i + 3] = 0; continue; }
    d[i] = Math.min(255, f[i] / (a / 255)); d[i + 1] = Math.min(255, f[i + 1] / (a / 255)); d[i + 2] = Math.min(255, f[i + 2] / (a / 255)); d[i + 3] = na;
  }
}
async function hiDefTile(params, abort) {
  const res = await fetch(`https://${params.url.slice('hidef://'.length)}`, { signal: abort?.signal });
  if (!res.ok) throw new Error(`radar tile ${res.status}`);
  const bmp = await createImageBitmap(await res.blob());
  const w = bmp.width, h = bmp.height;
  const cv = typeof OffscreenCanvas !== 'undefined' ? new OffscreenCanvas(w, h) : Object.assign(document.createElement('canvas'), { width: w, height: h });
  const cx = cv.getContext('2d', { willReadFrequently: true });
  cx.drawImage(bmp, 0, 0);
  const img = cx.getImageData(0, 0, w, h);
  hiDefPixels(img.data, w, h);
  cx.putImageData(img, 0, 0);
  const blob = cv.convertToBlob ? await cv.convertToBlob({ type: 'image/png' }) : await new Promise((ok) => cv.toBlob(ok, 'image/png'));
  return { data: await blob.arrayBuffer() };
}
let hiDefReady = false;

export function initMap(el, loc, getTheme, handlers) {
  if (!hiDefReady) { try { ml.addProtocol('hidef', hiDefTile); hiDefReady = true; } catch (e) { console.warn('hidef', e); } }
  themeFn = getTheme; H = handlers || {};
  map = new ml.Map({
    container: el, style: styleUrl(), center: [loc.lon, loc.lat], zoom: 6.5, maxZoom: 16, minZoom: 1,
    attributionControl: { compact: true }, dragRotate: false, pitchWithRotate: false,
  });
  map.touchZoomRotate.disableRotation();
  map.on('style.load', onStyleLoad);
  map.on('click', onClick);
  map.on('moveend', (e) => H.onCenter?.(map.getCenter(), !!e.originalEvent || !!e.userMove));
  map.on('contextmenu', (e) => quickForecast(e.lngLat));
  let pressT; // long press on touch
  map.on('touchstart', (e) => { if (e.originalEvent.touches.length !== 1) return; pressT = setTimeout(() => quickForecast(e.lngLat), 550); });
  ['touchend', 'touchmove', 'movestart'].forEach((ev) => map.on(ev, () => clearTimeout(pressT)));
  map.on('error', (e) => console.warn('map', e?.error?.message || e));
  map.once('load', () => document.querySelector('.maplibregl-ctrl-attrib')?.classList.remove('maplibregl-compact-show'));
  buildDock();
  setInterval(() => { if (S.layers.radar && active.radar) reloadRadar(); }, 5 * 60e3);
  setInterval(() => { if (S.layers.alerts && active.alerts) refresh('alerts'); }, 2 * 60e3);
  return map;
}
export const getMap = () => map;
const styleUrl = () => STYLES[S.style === 'auto' ? themeFn() : S.style]?.url || STYLES.dark.url;

function onStyleLoad() {
  styleReady = true;
  try { map.setProjection({ type: 'globe' }); } catch { /* older engine */ }
  // Style switch wipes custom layers; markers survive, so remove everything and re-add
  for (const id of Object.keys(active)) { try { active[id]?.remove?.(); } catch { /* gone */ } delete active[id]; }
  addFrontImages();
  if (routeData) setTimeout(() => drawRoute(...routeData, true), 0);
  if (S.style === 'proDark') brightenDark();
  // Let the base map paint first, then bring in radar and the other layers
  let started = false;
  const go = () => { if (started) return; started = true; applyLayers(); };
  map.once('idle', go); setTimeout(go, 2500);
}
// OpenFreeMap's dark style is very dim; lift borders, water and labels so it reads like a radar app
function brightenDark() {
  const set = (id, prop, val) => { try { map.setPaintProperty(id, prop, val); } catch { /* prop not on layer */ } };
  for (const l of map.getStyle().layers) {
    const id = l.id;
    if (l.type === 'background') set(id, 'background-color', '#0d1016');
    else if (/^water/.test(id) && l.type === 'fill') set(id, 'fill-color', '#1a2233');
    else if (/boundary/.test(id) && l.type === 'line') { set(id, 'line-color', /2|country/.test(id) ? '#c3cad6' : '#8e97a6'); set(id, 'line-opacity', 0.85); }
    else if (/road|highway|transportation/.test(id) && l.type === 'line') set(id, 'line-opacity', 0.45);
    else if (l.type === 'symbol' && l.layout?.['text-field']) { set(id, 'text-color', /place_(city|capital|state|country)|state|country/.test(id) ? '#e7ecf5' : '#aab3c2'); set(id, 'text-halo-color', 'rgba(0,0,0,.9)'); set(id, 'text-halo-width', 1.4); }
  }
}
export function setTheme() { if (S.style === 'auto') setStyle('auto'); }
export function setStyle(v) {
  S.style = v; save(); styleReady = false;
  stopAnim();
  map.setStyle(styleUrl(), { diff: false });
}

export function flyTo(loc, z = 7) { map?.flyTo({ center: [loc.lon, loc.lat], zoom: Math.max(z, map.getZoom() < 4 ? z : map.getZoom()), duration: 1200 }); }
let homeMarker;
export function setHome(loc) {
  if (!map) return;
  homeMarker?.remove();
  const el = document.createElement('div'); el.className = 'home-dot';
  homeMarker = new ml.Marker({ element: el }).setLngLat([loc.lon, loc.lat]).addTo(map);
}
export function invalidate() { map?.resize(); }
export function closePopups() { $$('.maplibregl-popup').forEach((p) => p.remove()); }

// ================= layer engine =================
const ADD = {};
export function applyLayers() {
  if (!styleReady) return;
  for (const id of Object.keys(DEFAULT_LAYERS)) {
    const on = S.layers[id] && canLayer(id);
    if (on && !active[id]) enable(id);
    else if (!on && active[id]) disable(id);
  }
  updateDock(); save();
}
async function enable(id) {
  if (!ADD[id]) return;
  const tok = {};
  active[id] = { pending: tok, remove() {} };
  try {
    const h = await ADD[id]();
    if (!S.layers[id] || active[id]?.pending !== tok) { h?.remove?.(); return; }
    active[id] = h || { remove() {} };
  } catch (e) {
    console.warn(id, e); delete active[id];
    toast(`${layerName(id)} is unavailable right now`);
  }
}
function disable(id) { try { active[id]?.remove?.(); } catch { /* ignore */ } delete active[id]; }
function refresh(id) { disable(id); enable(id); }
export function toggleLayer(id, on) {
  S.layers[id] = on;
  if (id === 'sites') {
    if (on) toast('Tap a radar site to view its Doppler radar');
    else if (S.radarSrc === 'site') { S.radarSrc = 'us'; disable('radar'); } // back to Hi-Def
  }
  applyLayers();
}
const layerName = (id) => LAYER_GROUPS.flatMap((g) => g[1]).find((r) => r[0] === id)?.[1] || id;

// helpers
function beforeId() {
  const ls = map.getStyle().layers || [];
  const sym = ls.find((l) => l.type === 'symbol');
  return sym ? sym.id : (map.getLayer('ref') ? 'ref' : undefined);
}
function rm(layers = [], sources = []) {
  for (const l of layers) if (map.getLayer(l)) map.removeLayer(l);
  for (const s of sources) if (map.getSource(s)) map.removeSource(s);
}
function raster(id, url, { opacity = 0.75, maxzoom = 12, before = beforeId() } = {}) {
  map.addSource(id, { type: 'raster', tiles: [url], tileSize: 256, maxzoom });
  map.addLayer({ id, type: 'raster', source: id, paint: { 'raster-opacity': opacity, 'raster-fade-duration': 0 } }, before);
  return { remove: () => rm([id], [id]) };
}
function geo(id, data, specs, onClickFn) {
  map.addSource(id, { type: 'geojson', data });
  const b = beforeId();
  const ids = specs.map((s, i) => { const lid = `${id}-${i}`; map.addLayer({ ...s, id: lid, source: id }, s.top ? undefined : b); return lid; });
  if (onClickFn) ids.forEach((lid) => clickers.push([lid, onClickFn]));
  return { remove: () => { rm(ids, [id]); for (let i = clickers.length - 1; i >= 0; i--) if (ids.includes(clickers[i][0])) clickers.splice(i, 1); }, ids };
}
function markersHandle(list, extra) { return { remove: () => { list.forEach((m) => m.remove()); extra?.(); } }; }
function pin(lngLat, html, cls, onTap) {
  const el = document.createElement('div'); el.className = cls; el.innerHTML = html;
  if (onTap) el.addEventListener('click', (e) => { e.stopPropagation(); onTap(); });
  return new ml.Marker({ element: el }).setLngLat(lngLat).addTo(map);
}
// Popups hide the crosshair so it never sits on top of the text
function popup(lngLat, html) {
  closePopups();
  const p = new ml.Popup({ maxWidth: '300px', className: 'wx-pop' }).setLngLat(lngLat).setHTML(html);
  p.on('open', () => document.body.classList.add('popup-open'));
  p.on('close', () => { if (!document.querySelector('.maplibregl-popup')) document.body.classList.remove('popup-open'); });
  return p.addTo(map);
}
function viewGrid(cols, rows) {
  const b = map.getBounds();
  let s = Math.max(-70, b.getSouth()), n = Math.min(72, b.getNorth()), w = b.getWest(), e = b.getEast();
  if (e - w > 120 || map.getZoom() < 3) { const c = map.getCenter(); w = c.lng - 40; e = c.lng + 40; s = Math.max(-70, c.lat - 22); n = Math.min(72, c.lat + 22); }
  const lats = [], lons = [];
  for (let r = 0; r < rows; r++) for (let c = 0; c < cols; c++) {
    lats.push((s + (n - s) * (r + 0.5) / rows).toFixed(3));
    lons.push((((w + (e - w) * (c + 0.5) / cols) + 540) % 360 - 180).toFixed(3));
  }
  return { lats, lons, s, n, w, e };
}

function onClick(e) {
  const ids = clickers.map((c) => c[0]).filter((id) => map.getLayer(id));
  const f = ids.length ? map.queryRenderedFeatures(e.point, { layers: ids })[0] : null;
  if (f) { clickers.find((c) => c[0] === f.layer.id)?.[1](f, e.lngLat); return; }
  quickForecast(e.lngLat);
}

// ================= Radar loop =================
const R = { frames: [], idx: 0, playing: true, timer: null, hold: 0 };
ADD.radar = async () => { await buildRadar(); return { remove: clearRadar }; };
async function buildRadar() {
  const frames = [];
  if (S.radarSrc === 'site' && !(S.layers.sites && canLayer('sites'))) S.radarSrc = 'us'; // Doppler layer off: back to Hi-Def
  if (S.radarSrc === 'site') {
    if (!S.site) { const c = map.getCenter(); S.site = nearestSite(await radarSites(), c.lat, c.lng)?.code || 'MLB'; save(); }
    const ridge = S.siteFam === 'srv' ? 'N0S' : S.siteFam === 'ref' && !S.tilt ? 'N0B' : null; // IEM tiles for the lowest scan
    if (ridge) {
      let scans = [];
      try { scans = (await siteScans(S.site, ridge)).slice(-12); } catch { /* fall back to latest */ }
      if (!scans.length) frames.push({ t: Date.now(), url: `${IEM}/ridge::${S.site}-${ridge}-0/{z}/{x}/{y}.png?_=${Math.floor(Date.now() / 120e3)}`, maxzoom: 12, site: true });
      for (const ts of scans) frames.push({ t: new Date(ts).getTime(), url: `${IEM}/ridge::${S.site}-${ridge}-${ts.replace(/[-:TZ]/g, '').slice(0, 12)}/{z}/{x}/{y}.png`, maxzoom: 12 });
    } else {
      // Tilts, velocity, dual-pol, VIL and echo tops: decoded from NOAA Level III by /api/radar
      const st = (await radarSites()).find((x) => x.code === S.site);
      if (st) {
        const j = await getData(`/api/radar?site=${S.site}&family=${S.siteFam}&tilt=${S.tilt}&lat=${st.lat.toFixed(3)}&lon=${st.lon.toFixed(3)}`, { cache: 60e3 });
        const [w, s, e, n] = j.bounds || [];
        for (const f of j.frames || []) frames.push({ t: f.t, image: f.url, coords: [[w, n], [e, n], [e, s], [w, s]] });
        if (!frames.length) toast(`${SITE_PRODUCTS[S.siteFam]?.[0] || 'That product'} isn't available from K${S.site} right now`);
      }
    }
  } else if (S.radarSrc === 'us') {
    let base = Math.floor(Date.now() / 300e3) * 300e3 - 300e3;
    try { const j = await feeds.iemTms(); const s = (j.services || []).find((x) => /n0q/i.test(x.id || '') && x.utc_valid); if (s) base = new Date(s.utc_valid).getTime(); } catch { /* estimate */ }
    const bust = Math.floor(Date.now() / 300e3);
    for (let m = 50; m >= 0; m -= 5) {
      const lname = m ? `nexrad-n0q-900913-m${String(m).padStart(2, '0')}m` : 'nexrad-n0q-900913';
      const tile = `${IEM}/${lname}/{z}/{x}/{y}.png?_=${bust}`;
      frames.push({ t: base - m * 60e3, url: S.hiDef && hiDefReady ? tile.replace('https://', 'hidef://') : tile, maxzoom: 12 });
    }
  } else {
    const j = await feeds.rainviewer();
    for (const f of j.radar.past) frames.push({ t: f.time * 1000, url: `${j.host}${f.path}/256/{z}/{x}/{y}/2/1_1.png`, maxzoom: 7 });
  }
  clearRadar();
  if (!styleReady) return;
  const b = beforeId();
  R.frames = frames.map((f, i) => {
    const id = `radar-${i}`;
    if (f.image) map.addSource(id, { type: 'image', url: f.image, coordinates: f.coords });
    else map.addSource(id, { type: 'raster', tiles: [f.url], tileSize: 256, maxzoom: f.maxzoom });
    map.addLayer({ id, type: 'raster', source: id, paint: { 'raster-opacity': 0, 'raster-fade-duration': 0, 'raster-opacity-transition': { duration: 0 } } }, b);
    return { ...f, id };
  });
  $('#tlRange').max = R.frames.length - 1;
  showFrame(R.frames.length - 1);
  if (R.playing) play();
}
function reloadRadar() { refresh('radar'); }
function clearRadar() { clearInterval(R.timer); if (map?.getStyle()) R.frames.forEach((f) => rm([f.id], [f.id])); R.frames = []; }
function showFrame(i) {
  if (!R.frames.length) return;
  R.idx = i;
  R.frames.forEach((f, k) => { if (map.getLayer(f.id)) map.setPaintProperty(f.id, 'raster-opacity', k === i ? S.opacity : 0); });
  const f = R.frames[i];
  $('#tlTime').textContent = localTime(f.t);
  $('#tlAgo').textContent = (S.radarSrc === 'site' ? `K${S.site} · ` : '') + (i === R.frames.length - 1 ? 'Latest' : `${Math.round((Date.now() - f.t) / 60e3)} min ago`);
  $('#tlRange').value = i;
}
function play() {
  clearInterval(R.timer); R.playing = true; $('#tlPlay').innerHTML = PAUSE;
  R.timer = setInterval(() => {
    if (!R.frames.length) return;
    if (R.idx === R.frames.length - 1 && R.hold < 3) { R.hold++; return; }
    R.hold = 0; showFrame((R.idx + 1) % R.frames.length);
  }, S.speed);
}
function pause() { clearInterval(R.timer); R.playing = false; $('#tlPlay').innerHTML = PLAY; }
function stopAnim() { clearInterval(R.timer); }
const PLAY = '<svg width="22" height="22" viewBox="0 0 24 24"><path d="M7 4.5v15l12.5-7.5z" fill="currentColor"/></svg>';
const PAUSE = '<svg width="22" height="22" viewBox="0 0 24 24"><path d="M6.5 4.5h4v15h-4zM13.5 4.5h4v15h-4z" fill="currentColor"/></svg>';

// ================= Satellite, lightning, rain totals =================
ADD.sat = async () => {
  if (S.sat === 'geocolor') {
    const t = new Date(Math.floor((Date.now() - 90 * 60e3) / 600e3) * 600e3).toISOString().replace('.000Z', 'Z');
    return raster('sat', `https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/GOES-East_ABI_GeoColor/default/${t}/GoogleMapsCompatible_Level7/{z}/{y}/{x}.jpg`, { opacity: 0.85, maxzoom: 7, before: firstRadarOr() });
  }
  const ch = { ir: 'ch13', vis: 'ch02', wv: 'ch09' }[S.sat] || 'ch13';
  return raster('sat', `${IEM}/goes_east_conus_${ch}/{z}/{x}/{y}.png?_=${Math.floor(Date.now() / 300e3)}`, { opacity: 0.7, maxzoom: 9, before: firstRadarOr() });
};
const firstRadarOr = () => (R.frames[0] && map.getLayer(R.frames[0].id) ? R.frames[0].id : beforeId());
// Lightning strike density, last 15 minutes (NOAA nowCOAST / NWS Ocean Prediction Center)
const WMS = (base, layer, ver = '1.3.0') => `${base}?SERVICE=WMS&VERSION=${ver}&REQUEST=GetMap&LAYERS=${layer}&STYLES=&FORMAT=image/png&TRANSPARENT=true&${ver === '1.3.0' ? 'CRS' : 'SRS'}=EPSG:3857&WIDTH=256&HEIGHT=256&BBOX={bbox-epsg-3857}`;
// Lightning: strike density shading (NOAA nowCOAST) plus individual flashes from the GOES-19 lightning mapper
// (via /api/lightning). Bolts = last 5 minutes, then dots fade from orange to red until 30 minutes old.
function boltImage() {
  if (map.hasImage('bolt')) return;
  const c = document.createElement('canvas'); c.width = c.height = 40; const g = c.getContext('2d');
  g.beginPath(); g.moveTo(23, 2); g.lineTo(8, 22); g.lineTo(18, 22); g.lineTo(14, 38); g.lineTo(32, 15); g.lineTo(21, 15); g.lineTo(27, 2); g.closePath();
  g.fillStyle = '#fde047'; g.strokeStyle = '#1e1b4b'; g.lineWidth = 2.5; g.lineJoin = 'round'; g.stroke(); g.fill();
  map.addImage('bolt', g.getImageData(0, 0, 40, 40), { pixelRatio: 2 });
}
ADD.lightning = async () => {
  const dens = raster('lightning', `${WMS('https://nowcoast.noaa.gov/geoserver/observations/lightning_detection/ows', 'ldn_lightning_strike_density')}&_=${Math.floor(Date.now() / 300e3)}`, { opacity: 0.55, maxzoom: 10 });
  boltImage();
  map.addSource('strikes', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
  map.addLayer({ id: 'strikes-old', type: 'circle', source: 'strikes', filter: ['>=', ['get', 'age'], 5],
    paint: { 'circle-radius': ['interpolate', ['linear'], ['zoom'], 3, 1.6, 8, 3.5], 'circle-color': ['interpolate', ['linear'], ['get', 'age'], 5, '#fb923c', 15, '#ef4444', 30, '#7f1d1d'], 'circle-opacity': ['interpolate', ['linear'], ['get', 'age'], 5, 0.95, 30, 0.35] } });
  map.addLayer({ id: 'strikes-new', type: 'symbol', source: 'strikes', filter: ['<', ['get', 'age'], 5],
    layout: { 'icon-image': 'bolt', 'icon-size': ['interpolate', ['linear'], ['zoom'], 3, 0.55, 8, 1], 'icon-allow-overlap': true, 'icon-ignore-placement': true } });
  let alive = true, lastT = 0;
  const flashes = new Set(), timers = new Set();
  // MyRadar-style flashes: new strikes replay as white blooms spread over the next minute
  const flash = (lon, lat) => {
    const el = document.createElement('div'); el.innerHTML = '<div class="ltg-flash"></div>';
    const m = new ml.Marker({ element: el }).setLngLat([lon, lat]).addTo(map);
    flashes.add(m);
    setTimeout(() => { m.remove(); flashes.delete(m); }, 1200);
  };
  const schedule = (list, now) => {
    const since = lastT || now - 120e3;
    lastT = Math.max(lastT, ...list.map((s) => s[2]));
    const b = map.getBounds();
    let fresh = list.filter(([lon, lat, t]) => t > since && b.contains([lon, lat]));
    if (fresh.length > 150) fresh = fresh.sort(() => Math.random() - 0.5).slice(0, 150);
    for (const [lon, lat] of fresh) {
      const id = setTimeout(() => { timers.delete(id); if (alive) flash(lon, lat); }, Math.random() * 58e3);
      timers.add(id);
    }
  };
  const load = async () => {
    try {
      const j = await getData('/api/lightning', { noProxy: true, timeout: 30000 });
      if (!alive || !map.getSource('strikes')) return;
      const now = Date.now();
      map.getSource('strikes').setData({ type: 'FeatureCollection', features: j.f.map(([lon, lat, t]) => ({ type: 'Feature', geometry: { type: 'Point', coordinates: [lon, lat] }, properties: { age: (now - t) / 60e3 } })) });
      schedule(j.f, now);
    } catch (e) { console.warn('lightning strikes', e); }
  };
  load();
  const timer = setInterval(load, 60e3);
  return { remove: () => { alive = false; clearInterval(timer); timers.forEach(clearTimeout); flashes.forEach((m) => m.remove()); dens.remove(); rm(['strikes-new', 'strikes-old'], ['strikes']); } };
};
ADD.rain = async () => {
  const layer = { '1h': 'q2-n1p-900913', '24h': 'q2-p24h-900913', '72h': 'q2-p72h-900913' }[S.rain] || 'q2-p24h-900913';
  return raster('rain', `${IEM}/${layer}/{z}/{x}/{y}.png?_=${Math.floor(Date.now() / 600e3)}`, { opacity: 0.7, maxzoom: 10, before: firstRadarOr() });
};

// ================= Warnings =================
let alertProps = [];
ADD.alerts = async () => {
  const j = await feeds.alerts();
  const rank = (e) => (/Warning|Emergency/.test(e) ? 2 : /Watch/.test(e) ? 1 : 0);
  alertProps = [];
  const feats = j.features.filter((f) => f.geometry).sort((a, b) => rank(a.properties.event) - rank(b.properties.event)).map((f) => {
    const i = alertProps.push(f.properties) - 1;
    return { type: 'Feature', geometry: f.geometry, properties: { i, c: alertColor(f.properties.event), r: rank(f.properties.event) } };
  });
  return geo('alerts', { type: 'FeatureCollection', features: feats }, [
    { type: 'fill', paint: { 'fill-color': ['get', 'c'], 'fill-opacity': ['match', ['get', 'r'], 2, 0.25, 0.1] } },
    { type: 'line', filter: ['==', ['get', 'r'], 2], paint: { 'line-color': ['get', 'c'], 'line-width': 2.5 } },
    { type: 'line', filter: ['!=', ['get', 'r'], 2], paint: { 'line-color': ['get', 'c'], 'line-width': 1.5, 'line-dasharray': [3, 2] } },
  ], (f) => window.dispatchEvent(new CustomEvent('show-alert', { detail: alertProps[f.properties.i] })));
};

// ================= SPC outlook & mesoscale discussions =================
ADD.spc = async () => {
  const j = await feeds.spc(1);
  return geo('spc', j, [
    { type: 'fill', paint: { 'fill-color': ['coalesce', ['get', 'fill'], '#888'], 'fill-opacity': 0.35 } },
    { type: 'line', paint: { 'line-color': ['coalesce', ['get', 'stroke'], '#888'], 'line-width': 1.5 } },
  ], (f, ll) => popup(ll, `<b>SPC Day 1: ${esc(f.properties.LABEL2 || f.properties.LABEL)}</b><br><a href="https://www.spc.noaa.gov/products/outlook/day1otlk.html" target="_blank" rel="noopener">Full outlook ↗</a>`));
};
ADD.mcd = async () => {
  const j = await feeds.mcd();
  if (!j.features?.length) toast('No active mesoscale discussions right now');
  return geo('mcd', j, [
    { type: 'fill', paint: { 'fill-color': '#22d3ee', 'fill-opacity': 0.12 } },
    { type: 'line', paint: { 'line-color': '#22d3ee', 'line-width': 2, 'line-dasharray': [2, 1.5] } },
  ], (f, ll) => { const p = f.properties; popup(ll, `<b>SPC Mesoscale Discussion ${esc(p.num || p.product_num || '')}</b><br>${esc(p.concerning || '')}<br>${p.watch_confidence ? `Watch chance ${esc(p.watch_confidence)}%<br>` : ''}<a href="${esc(p.spcurl || 'https://www.spc.noaa.gov/products/md/')}" target="_blank" rel="noopener">Read it ↗</a>`); });
};

// ================= Storm reports =================
ADD.lsr = async () => {
  const j = await feeds.lsr();
  const col = (t = '') => (/TORNADO|FUNNEL/i.test(t) ? '#ef4444' : /HAIL/i.test(t) ? '#22c55e' : /WIND|TSTM/i.test(t) ? '#3b82f6' : /FLOOD|RAIN/i.test(t) ? '#06b6d4' : /SNOW|ICE|SLEET/i.test(t) ? '#e5e7eb' : '#a855f7');
  j.features.forEach((f) => { f.properties.c = col(f.properties.typetext); });
  return geo('lsr', j, [{ type: 'circle', top: true, paint: { 'circle-radius': 6, 'circle-color': ['get', 'c'], 'circle-stroke-color': '#000', 'circle-stroke-width': 1 } }],
    (f, ll) => { const p = f.properties; popup(ll, `<b>${esc(p.typetext)}</b> ${p.magnitude ? esc(p.magnitude) + (p.unit ? ' ' + esc(p.unit) : '') : ''}<br>${esc(p.city)}, ${esc(p.st || p.state || '')}<br><small>${p.valid ? new Date(String(p.valid).endsWith('Z') ? p.valid : p.valid + 'Z').toLocaleString() : ''}</small><p>${esc(p.remark || '')}</p>`); });
};

// ================= Radar sites: tap one to view that single radar =================
// [label, has tilts, legend]
export const SITE_PRODUCTS = {
  ref: ['Reflectivity', true], vel: ['Velocity', true], srv: ['Storm-Relative Velocity', false], cc: ['Correlation Coefficient (debris, hail)', true],
  zdr: ['Differential Reflectivity', true], hhc: ['Precipitation Type', true], vil: ['VIL (hail potential)', false], eet: ['Echo Tops', false],
};
const TILTS = ['0.5°', '0.9°', '1.3°', '1.8°'];
const LEGENDS = {
  vel: 'linear-gradient(90deg,#023a02,#00c000,#9ff59f,#8a8a8a,#f5b8b8,#e01f1f,#4d0000)',
  srv: 'linear-gradient(90deg,#023a02,#00c000,#9ff59f,#8a8a8a,#f5b8b8,#e01f1f,#4d0000)',
  cc: 'linear-gradient(90deg,#130c5a,#2c26c9,#5ad2f0,#26b04a,#f6e93f,#f26c22,#e5281c,#d63ad6)',
  zdr: 'linear-gradient(90deg,#6f6f6f,#1e3cff,#2fd56b,#f6e93f,#f26c22,#b0103c,#f0b0f0)',
  hhc: 'linear-gradient(90deg,#8fd3ff,#3e70ff,#2fd56b,#0a8a2a,#f6e93f,#e5281c,#ff2ee0)',
  vil: 'linear-gradient(90deg,#5ad2f0,#26b04a,#f6e93f,#f26c22,#a8101c,#d63ad6)',
  eet: 'linear-gradient(90deg,#5ad2f0,#26b04a,#f6e93f,#f26c22,#a8101c,#d63ad6)',
};
export async function useSite(code, prod, tilt) {
  S.site = code;
  if (prod) { S.siteFam = prod === 'N0B' ? 'ref' : prod === 'N0S' ? 'srv' : prod; S.siteProd = S.siteFam === 'srv' ? 'N0S' : 'N0B'; }
  if (tilt != null) S.tilt = SITE_PRODUCTS[S.siteFam]?.[1] ? +tilt : 0;
  S.radarSrc = 'site'; S.layers.radar = true; save();
  refresh('radar'); updateDock(); if (active.sites) refresh('sites');
}
const RADOME_SVG = '<svg class="radome-ico" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="7.8" r="4.6" fill="currentColor" stroke="none"/><rect x="9" y="12.5" width="6" height="1.5" rx=".5" fill="currentColor" stroke="none"/><path stroke-width="1.3" d="M9.9 14 8.4 22.6M14.1 14l1.5 8.6M9.9 14l4.8 3.6M14.1 14l-4.8 3.6M9.3 17.6l6.3 5M14.7 17.6l-6.3 5M7.2 22.6h9.6"/><path stroke-width="1.5" d="M5.2 4.2a7 7 0 0 0 0 7.2M2.6 2.6a10 10 0 0 0 0 10.4M18.8 4.2a7 7 0 0 1 0 7.2M21.4 2.6a10 10 0 0 1 0 10.4"/></svg>';
// Radar site marker: a NEXRAD radome on its lattice tower, on a dark disc (purple when it's the radar showing)
function radomeImages() {
  const draw = (id, ring, fill, ink) => {
    if (map.hasImage(id)) return;
    const S2 = 2, D = 30 * S2, c = document.createElement('canvas'); c.width = c.height = D;
    const g = c.getContext('2d');
    g.beginPath(); g.arc(D / 2, D / 2, D / 2 - 2 * S2, 0, Math.PI * 2); g.fillStyle = fill; g.fill(); g.lineWidth = 2 * S2; g.strokeStyle = ring; g.stroke();
    g.save(); g.translate(D * 0.2, D * 0.17); g.scale((D * 0.6) / 24, (D * 0.6) / 24);
    g.fillStyle = ink; g.strokeStyle = ink; g.lineWidth = 1.5; g.lineCap = 'round';
    g.beginPath(); g.arc(12, 7.6, 5.6, 0, Math.PI * 2); g.fill();
    g.fillRect(8.3, 13, 7.4, 1.6);
    g.stroke(new Path2D('M9.4 14.6 7.6 22.6M14.6 14.6l1.8 8M9.4 14.6l5.9 4M14.6 14.6l-5.9 4M8.7 18.6l7.7 4M15.3 18.6l-7.7 4M6.4 22.6h11.2'));
    g.restore();
    map.addImage(id, g.getImageData(0, 0, D, D), { pixelRatio: S2 });
  };
  draw('radome', '#a78bfa', 'rgba(11,16,32,.9)', '#f5f3ff');
  draw('radome-on', '#ffffff', '#8b5cf6', '#ffffff');
}
ADD.sites = async () => {
  const list = await radarSites();
  const fc = { type: 'FeatureCollection', features: list.map((x) => ({ type: 'Feature', geometry: { type: 'Point', coordinates: [x.lon, x.lat] }, properties: { id: x.id, code: x.code, name: x.name, on: S.radarSrc === 'site' && S.site === x.code ? 1 : 0 } })) };
  radomeImages();
  return geo('sites', fc, [
    { type: 'symbol', top: true, layout: { 'icon-image': ['case', ['==', ['get', 'on'], 1], 'radome-on', 'radome'], 'icon-size': ['interpolate', ['linear'], ['zoom'], 3, 0.6, 7, 0.85, 10, 1], 'icon-allow-overlap': true } },
    { type: 'symbol', top: true, minzoom: 6, layout: { 'text-field': ['get', 'id'], 'text-size': 11, 'text-offset': [0, 1.7], 'text-font': ['Noto Sans Bold'], 'text-allow-overlap': false }, paint: { 'text-color': '#e9d5ff', 'text-halo-color': '#0b1020', 'text-halo-width': 1.6 } },
  ], (f, ll) => {
    const p = f.properties, cur = S.radarSrc === 'site' && S.site === p.code;
    const tilted = SITE_PRODUCTS[S.siteFam]?.[1];
    const pop = popup(f.geometry.coordinates, `<div class="qp"><div class="qp-name">${esc(p.id)} · ${esc(p.name)}</div><div class="qp-row">${cur ? 'Showing this radar now' : 'NEXRAD Doppler radar'}</div>
      <div class="qp-prods">${Object.entries(SITE_PRODUCTS).map(([k, [t]]) => `<button class="btn small${cur && S.siteFam === k ? '' : ' ghost'}" data-sp="${k}">${t.replace(/ \(.*\)/, '')}</button>`).join('')}</div>
      <div class="qp-row muted small">Tilt (beam angle)</div>
      <div class="seg small qp-tilt">${TILTS.map((t, i) => `<button data-tilt="${i}" class="${cur && S.tilt === i && tilted ? 'on' : ''}"${tilted || !cur ? '' : ' disabled'}>${t}</button>`).join('')}</div>
      ${cur ? '<div class="qp-btns"><button class="btn small ghost" data-sp="mosaic">Back to US mosaic</button></div>' : ''}</div>`);
    setTimeout(() => {
      const el = pop.getElement();
      el?.querySelectorAll('[data-sp]').forEach((b) => b.onclick = () => {
        pop.remove();
        if (b.dataset.sp === 'mosaic') { S.radarSrc = 'us'; save(); refresh('radar'); updateDock(); if (active.sites) refresh('sites'); return; }
        useSite(p.code, b.dataset.sp, cur ? S.tilt : 0);
      });
      el?.querySelectorAll('[data-tilt]').forEach((b) => b.onclick = () => { pop.remove(); useSite(p.code, cur ? S.siteFam : 'ref', +b.dataset.tilt); });
    }, 0);
  });
};

// ================= Buoys: live wave height and wind from every NDBC station =================
ADD.buoys = async () => {
  const [list, names] = await Promise.all([buoyList(), buoyNames()]);
  const ftLbl = (m) => (m == null ? '' : `${(m * 3.28084).toFixed(0)}'`);
  const col = (m) => (m == null ? '#64748b' : m < 0.6 ? '#22c55e' : m < 1.2 ? '#84cc16' : m < 2 ? '#eab308' : m < 3 ? '#f97316' : '#ef4444');
  const fc = { type: 'FeatureCollection', features: list.filter((b) => Date.now() - b.t < 6 * 36e5).map((b) => ({ type: 'Feature', geometry: { type: 'Point', coordinates: [b.lon, b.lat] }, properties: { ...b, name: names[b.id] || '', lbl: ftLbl(b.wvht), c: col(b.wvht) } })) };
  return geo('buoys', fc, [
    { type: 'circle', top: true, paint: { 'circle-radius': ['case', ['has', 'wvht'], 6, 4], 'circle-color': ['get', 'c'], 'circle-stroke-color': '#0b1020', 'circle-stroke-width': 1.5 } },
    { type: 'symbol', top: true, minzoom: 4.5, layout: { 'text-field': ['get', 'lbl'], 'text-size': 11, 'text-offset': [0, 1.2], 'text-font': ['Noto Sans Bold'] }, paint: { 'text-color': '#e0f2fe', 'text-halo-color': '#0b1020', 'text-halo-width': 1.5 } },
  ], (f, ll) => {
    const p = f.properties, n = (v) => (v === 'null' || v == null ? null : +v);
    const wv = n(p.wvht), ws = n(p.wspd), gs = n(p.gst), wt = n(p.wtmp), dp = n(p.dpd);
    popup(f.geometry.coordinates, `<div class="qp"><div class="qp-name">Buoy ${esc(p.id)}${p.name ? ` · ${esc(p.name)}` : ''}</div>
      <div class="qp-row">Waves <b>${wv != null ? (wv * 3.28084).toFixed(1) + ' ft' : '--'}</b>${dp ? ` at ${dp}s` : ''}${n(p.mwd) != null ? ` from ${compass(n(p.mwd))}` : ''}</div>
      <div class="qp-row">Wind ${n(p.wdir) != null ? compass(n(p.wdir)) : ''} ${ws != null ? Math.round(ws * 1.94384) + ' kn' : '--'}${gs != null ? `, gusts ${Math.round(gs * 1.94384)} kn` : ''}</div>
      <div class="qp-row">Water ${wt != null ? fmtT(wt) : '--'} · ${Math.round((Date.now() - p.t) / 60e3)} min ago</div>
      <div class="qp-btns"><a class="btn small ghost" href="https://www.ndbc.noaa.gov/station_page.php?station=${esc(p.id)}" target="_blank" rel="noopener">NDBC page ↗</a><button class="btn small" id="bmar">Marine forecast</button></div></div>`);
    setTimeout(() => { const b = document.getElementById('bmar'); if (b) b.onclick = () => { closePopups(); H.onPick?.({ lat: f.geometry.coordinates[1], lon: f.geometry.coordinates[0] }, `Buoy ${p.id}`); }; }, 0);
  });
};

// ================= Power outages: DOE ODIN, by county (participating utilities only) =================
ADD.outages = async () => {
  const sel = 'county,state,name,metersaffected,cause,estimatedrestorationtime,reportedstarttime,communitydescriptor,geom';
  const j = await getData(`https://openenergyhub.ornl.gov/api/explore/v2.1/catalog/datasets/odin-real-time-outages-county/exports/geojson?select=${encodeURIComponent(sel)}`, { cache: 300e3, timeout: 30000 });
  // one feature per county with every utility's count added up
  const by = {};
  for (const f of j.features || []) {
    const p = f.properties, k = p.communitydescriptor || `${p.county}-${p.state}`;
    if (!f.geometry) continue;
    const e = by[k] ||= { type: 'Feature', geometry: f.geometry, properties: { county: p.county, state: p.state, out: 0, list: [] } };
    const n = +p.metersaffected || 0; e.properties.out += n;
    let ert = ''; try { ert = p.estimatedrestorationtime ? JSON.parse(p.estimatedrestorationtime).ert || '' : ''; } catch { /* plain */ }
    e.properties.list.push({ u: String(p.name || '').replace(/,\d+$/, ''), n, cause: p.cause || '', ert, start: p.reportedstarttime || '' });
  }
  const feats = Object.values(by).map((f) => ({ ...f, properties: { ...f.properties, list: JSON.stringify(f.properties.list) } }));
  if (!feats.length) toast('No outages reported by participating utilities right now');
  return geo('outages', { type: 'FeatureCollection', features: feats }, [
    { type: 'fill', paint: { 'fill-color': ['step', ['get', 'out'], '#fde68a', 50, '#fbbf24', 250, '#f97316', 1000, '#dc2626', 5000, '#7f1d1d'], 'fill-opacity': 0.55 } },
    { type: 'line', paint: { 'line-color': '#92400e', 'line-width': 0.8 } },
  ], (f, ll) => {
    const p = f.properties, list = JSON.parse(p.list || '[]').sort((a, b) => b.n - a.n);
    const t = (s) => (s ? new Date(s).toLocaleString([], { weekday: 'short', hour: 'numeric', minute: '2-digit' }) : '');
    popup(ll, `<div class="qp"><div class="qp-name">${esc(p.county)} County, ${esc(p.state)}</div><div class="qp-row"><b>${(+p.out).toLocaleString()}</b> customers without power</div>
      ${list.slice(0, 6).map((x) => `<div class="qp-row small">${esc(x.u)}: ${x.n.toLocaleString()}${x.cause && !/unknown/i.test(x.cause) ? ` · ${esc(x.cause)}` : ''}${x.ert ? ` · back by ${t(x.ert)}` : ''}</div>`).join('')}
      <div class="muted small">DOE ODIN · participating utilities only</div></div>`);
  });
};

// ================= Tropics & snow (NOAA map services) =================
const NOAA_MS = 'https://mapservices.weather.noaa.gov';
const agsExport = (svc, layers, img = false) => `${NOAA_MS}/${svc}/${img ? 'exportImage' : 'export'}?bbox={bbox-epsg-3857}&bboxSR=3857&imageSR=3857&size=256,256&format=png32&transparent=true${layers ? `&layers=show:${layers}` : ''}&f=image`;
// NOAA's map images don't allow cross-site loading, so they come through our proxy (the bbox placeholder stays for MapLibre)
const viaProxy = (u) => `/api/proxy?url=${encodeURIComponent(u).replace('%7Bbbox-epsg-3857%7D', '{bbox-epsg-3857}')}`;
const bustQ = (min) => `&_=${Math.floor(Date.now() / (min * 60e3))}`;
ADD.twoutlook = async () => raster('twoutlook', viaProxy(agsExport('tropical/rest/services/tropical/NHC_tropical_weather_summary/MapServer', '1,2,3,33') + bustQ(30)), { opacity: 0.85, maxzoom: 10 });
ADD.windprob = async () => raster('windprob', viaProxy(agsExport('tropical/rest/services/tropical/NHC_tropical_weather_summary/MapServer', '30,18') + bustQ(30)), { opacity: 0.7, maxzoom: 10 });
ADD.surgerisk = async () => { const id = { 1: 2, 2: 6, 3: 10, 4: 14, 5: 18 }[S.surgeCat] || 10; toast('Zoom in on the coast to see surge risk'); return raster('surgerisk', viaProxy(agsExport('tropical/rest/services/tropical/StormSurgeRisk/MapServer', id)), { opacity: 0.75, maxzoom: 16 }); };
ADD.snowdepth = async () => raster('snowdepth', viaProxy(agsExport('raster/rest/services/snow/NOHRSC_Snow_Analysis/MapServer', '0') + bustQ(180)), { opacity: 0.7, maxzoom: 12, before: firstRadarOr() });
ADD.snowprob = async () => {
  const off = { 1: 0, 2: 5, 3: 10 }[S.snowDay] || 0, sub = { 4: 1, 8: 2, 12: 3, ice: 4 }[S.snowAmt] || 1;
  return raster('snowprob', viaProxy(agsExport('vector/rest/services/precip/wpc_prob_winter_precip/MapServer', off + sub) + bustQ(120)), { opacity: 0.7, maxzoom: 10, before: firstRadarOr() });
};
// IMS snow & ice (values 3 = sea ice, 4 = snow); everything else made transparent
const IMS_RULE = encodeURIComponent(JSON.stringify({ rasterFunction: 'Colormap', rasterFunctionArguments: { Colormap: [[0, 0, 0, 0], [1, 0, 0, 0], [2, 0, 0, 0], [3, 150, 205, 255], [4, 255, 255, 255]] }, variableName: 'Raster' }));
ADD.snowcover = async () => raster('snowcover', viaProxy(`${agsExport('raster/rest/services/obs/usnic_ims_snow_ice_1km/ImageServer', '', true)}&noData=0,1,2&noDataInterpretation=esriNoDataMatchAny&renderingRule=${IMS_RULE}${bustQ(360)}`), { opacity: 0.6, maxzoom: 9, before: firstRadarOr() });

// ================= More marine layers =================
// Sea surface temperature, NASA GIBS (MUR blend, yesterday's analysis)
ADD.sst = async () => {
  // 'default' = NASA's newest available day (the analysis runs about 2 days behind)
  return raster('sst', `https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/GHRSST_L4_MUR_Sea_Surface_Temperature/default/default/GoogleMapsCompatible_Level7/{z}/{y}/{x}.png?_=${Math.floor(Date.now() / 216e5)}`, { opacity: 0.75, maxzoom: 7, before: firstRadarOr() });
};
// NOAA electronic nautical charts (depths, channels, buoys, hazards)
ADD.charts = async () => raster('charts', 'https://gis.charttools.noaa.gov/arcgis/rest/services/MCS/NOAAChartDisplay/MapServer/exts/MaritimeChartService/MapServer/export?bbox={bbox-epsg-3857}&bboxSR=3857&imageSR=3857&size=256,256&format=png&transparent=true&f=image', { opacity: 1, maxzoom: 18, before: firstRadarOr() });
// Offshore oil & gas platforms in place now (BOEM / BSEE)
ADD.rigs = async () => {
  const j = await getData('https://gis.boem.gov/arcgis/rest/services/BOEM_BSEE/MMC_Layers/MapServer/0/query?where=REMOVAL_DATE%20IS%20NULL&outFields=COMPLEX_ID_NUM,INSTALL_DATE&f=geojson', { cache: 86400e3, timeout: 30000 });
  return geo('rigs', j, [{ type: 'circle', top: true, paint: { 'circle-radius': ['interpolate', ['linear'], ['zoom'], 4, 2.5, 9, 6], 'circle-color': '#f59e0b', 'circle-stroke-color': '#0b1020', 'circle-stroke-width': 1 } }],
    (f, ll) => { const p = f.properties, yr = p.INSTALL_DATE ? new Date(p.INSTALL_DATE).getFullYear() : '';
      const pop = popup(f.geometry.coordinates, `<div class="qp"><div class="qp-name">Offshore platform</div><div class="qp-row">Complex ${esc(p.COMPLEX_ID_NUM)}${yr ? ` · installed ${yr}` : ''}</div><div class="qp-btns"><button class="btn small" id="rigsea">Seas &amp; forecast here</button></div><div class="muted small">BOEM / BSEE</div></div>`);
      setTimeout(() => { const b = document.getElementById('rigsea'); if (b) b.onclick = () => { pop.remove(); H.onPick?.({ lat: f.geometry.coordinates[1], lon: f.geometry.coordinates[0] }, `Platform ${p.COMPLEX_ID_NUM}`); }; }, 0); });
};
// NOAA BuoyCAMs: live photos from cameras on offshore buoys
ADD.cams = async () => {
  const list = await getData('https://www.ndbc.noaa.gov/buoycams.php', { proxyFirst: true, cache: 600e3 });
  const fc = { type: 'FeatureCollection', features: list.filter((c) => c.img).map((c) => ({ type: 'Feature', geometry: { type: 'Point', coordinates: [c.lng, c.lat] }, properties: c })) };
  return geo('cams', fc, [
    { type: 'circle', top: true, paint: { 'circle-radius': 9, 'circle-color': '#0ea5e9', 'circle-stroke-color': '#fff', 'circle-stroke-width': 2 } },
    { type: 'symbol', top: true, layout: { 'text-field': '◉', 'text-size': 10, 'text-allow-overlap': true, 'text-font': ['Noto Sans Bold'] }, paint: { 'text-color': '#fff' } },
  ], (f) => { const c = f.properties;
    popup(f.geometry.coordinates, `<div class="qp cam-pop"><div class="qp-name">${esc(c.name)}</div><div class="cam-strip"><img src="https://www.ndbc.noaa.gov/images/buoycam/${esc(c.img)}" alt="Buoy ${esc(c.id)} camera"></div><div class="muted small">Swipe for all 6 views · ${camTime(c.img)} · <a href="https://www.ndbc.noaa.gov/buoycam.php?station=${esc(c.id)}" target="_blank" rel="noopener">NDBC ↗</a></div></div>`); });
};
export const camTime = (img) => { const m = String(img).match(/(\d{4})_(\d\d)_(\d\d)_(\d\d)(\d\d)/); return m ? new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5])).toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : ''; };

// ================= Hail map: storm reports sized by stone size + SPC hail risk =================
const hailColor = (inch) => (inch >= 2.75 ? '#d946ef' : inch >= 2 ? '#ef4444' : inch >= 1.5 ? '#f97316' : inch >= 1 ? '#facc15' : '#a3e635');
ADD.hail = async () => {
  const [rep, risk] = await Promise.allSettled([
    getData(`https://mesonet.agron.iastate.edu/geojson/lsr.geojson?hours=${S.hail}`, { cache: 300e3 }),
    getData('https://www.spc.noaa.gov/products/outlook/day1otlk_hail.lyr.geojson', { proxyFirst: true, cache: 900e3 }),
  ]);
  const hs = [];
  if (risk.status === 'fulfilled' && risk.value?.features?.length) hs.push(geo('hailrisk', risk.value, [
    { type: 'fill', paint: { 'fill-color': ['coalesce', ['get', 'fill'], '#facc15'], 'fill-opacity': 0.18 } },
    { type: 'line', paint: { 'line-color': ['coalesce', ['get', 'stroke'], '#facc15'], 'line-width': 1.2, 'line-dasharray': [2, 1] } },
  ], (f, ll) => popup(ll, `<b>SPC hail risk today: ${esc(f.properties.LABEL2 || f.properties.LABEL || '')}</b><br><small>Chance of 1 inch or larger hail within 25 miles of a point</small>`)));
  const feats = rep.status === 'fulfilled' ? rep.value.features.filter((f) => /HAIL/i.test(f.properties.typetext || '')) : [];
  feats.forEach((f) => { const m = parseFloat(f.properties.magnitude) || 0.75; f.properties.m = m; f.properties.c = hailColor(m); });
  if (!feats.length) toast(`No hail reports in the last ${S.hail === '24' ? 'day' : S.hail === '72' ? '3 days' : 'week'}`);
  hs.push(geo('hail', { type: 'FeatureCollection', features: feats }, [
    { type: 'circle', top: true, paint: { 'circle-radius': ['interpolate', ['linear'], ['get', 'm'], 0.5, 4, 1, 6, 2, 10, 4, 16], 'circle-color': ['get', 'c'], 'circle-opacity': 0.9, 'circle-stroke-color': '#111', 'circle-stroke-width': 1 } },
    { type: 'symbol', top: true, minzoom: 7, layout: { 'text-field': ['concat', ['to-string', ['get', 'm']], '"'], 'text-size': 11, 'text-offset': [0, 1.3], 'text-font': ['Noto Sans Bold'] }, paint: { 'text-color': '#fff', 'text-halo-color': '#000', 'text-halo-width': 1.4 } },
  ], (f, ll) => { const p = f.properties; popup(ll, `<b>Hail ${esc(p.m)} in</b> ${hailName(p.m)}<br>${esc(p.city)}, ${esc(p.st || p.state || '')}<br><small>${p.valid ? new Date(String(p.valid).endsWith('Z') ? p.valid : p.valid + 'Z').toLocaleString() : ''} · ${esc(p.source || '')}</small><p>${esc(p.remark || '')}</p>`); }));
  return { remove: () => hs.forEach((h) => h.remove()) };
};
export const hailName = (i) => (i >= 4 ? '(softball)' : i >= 2.75 ? '(baseball)' : i >= 2.5 ? '(tennis ball)' : i >= 1.75 ? '(golf ball)' : i >= 1.5 ? '(ping pong ball)' : i >= 1.25 ? '(half dollar)' : i >= 1 ? '(quarter)' : i >= 0.88 ? '(nickel)' : '(pea to penny)');

// ================= Traffic (TomTom flow + incidents, key required) =================
ADD.traffic = async () => {
  if (!KEYS.tomtom) throw new Error('no key');
  const bust = Math.floor(Date.now() / 120e3);
  map.addSource('traffic', { type: 'raster', tiles: [`https://api.tomtom.com/traffic/map/4/tile/flow/relative0/{z}/{x}/{y}.png?key=${KEYS.tomtom}&thickness=6&_=${bust}`], tileSize: 256, minzoom: 5, maxzoom: 18 });
  map.addLayer({ id: 'traffic', type: 'raster', source: 'traffic', minzoom: 5, paint: { 'raster-opacity': 0.9 } }, beforeId());
  map.addSource('trafficinc', { type: 'raster', tiles: [`https://api.tomtom.com/traffic/map/4/tile/incidents/s3/{z}/{x}/{y}.png?key=${KEYS.tomtom}&_=${bust}`], tileSize: 256, minzoom: 8, maxzoom: 18 });
  map.addLayer({ id: 'trafficinc', type: 'raster', source: 'trafficinc', minzoom: 8 });
  if (map.getZoom() < 5) toast('Zoom in to see traffic');
  // Tap-able incident details (crashes, closures, construction) when zoomed in to a metro area
  map.addSource('trafficpts', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
  map.addLayer({ id: 'trafficpts', type: 'circle', source: 'trafficpts', minzoom: 9, paint: { 'circle-radius': 7, 'circle-color': ['get', 'c'], 'circle-stroke-color': '#fff', 'circle-stroke-width': 1.5 } });
  const CAT = { 1: 'Accident', 2: 'Fog', 3: 'Dangerous conditions', 4: 'Rain', 5: 'Ice', 6: 'Traffic jam', 7: 'Lane closed', 8: 'Road closed', 9: 'Road work', 10: 'Wind', 11: 'Flooding', 14: 'Broken-down vehicle' };
  const COL = { 1: '#ef4444', 6: '#f97316', 7: '#eab308', 8: '#7f1d1d', 9: '#f59e0b' };
  let seq = 0;
  const load = async () => {
    if (map.getZoom() < 9 || !map.getSource('trafficpts')) return;
    const my = ++seq, b = map.getBounds();
    const fields = encodeURIComponent('{incidents{type,geometry{type,coordinates},properties{iconCategory,magnitudeOfDelay,events{description},from,to,delay,roadNumbers,startTime,endTime}}}');
    try {
      const j = await getData(`https://api.tomtom.com/traffic/services/5/incidentDetails?key=${KEYS.tomtom}&bbox=${b.getWest().toFixed(4)},${b.getSouth().toFixed(4)},${b.getEast().toFixed(4)},${b.getNorth().toFixed(4)}&fields=${fields}&language=en-US&timeValidityFilter=present`, { noProxy: true, cache: 120e3 });
      if (my !== seq || !map.getSource('trafficpts')) return;
      map.getSource('trafficpts').setData({ type: 'FeatureCollection', features: (j.incidents || []).map((i) => {
        const g = i.geometry, c = g.type === 'Point' ? g.coordinates : g.coordinates[Math.floor(g.coordinates.length / 2)], p = i.properties;
        return { type: 'Feature', geometry: { type: 'Point', coordinates: c }, properties: { c: COL[p.iconCategory] || '#a855f7', cat: CAT[p.iconCategory] || 'Incident', desc: p.events?.map((e) => e.description).join('; ') || '', from: p.from || '', to: p.to || '', road: (p.roadNumbers || []).join(', '), delay: p.delay || 0 } };
      }) });
    } catch (e) { console.warn('traffic incidents', e); }
  };
  let t; const onMove = () => { clearTimeout(t); t = setTimeout(load, 700); };
  map.on('moveend', onMove); load();
  clickers.push(['trafficpts', (f, ll) => { const p = f.properties; popup(f.geometry.coordinates, `<div class="qp"><div class="qp-name">${esc(p.cat)}${p.road ? ` · ${esc(p.road)}` : ''}</div><div class="qp-row">${esc(p.desc)}</div>${p.from ? `<div class="qp-row">${esc(p.from)}${p.to ? ` to ${esc(p.to)}` : ''}</div>` : ''}${+p.delay ? `<div class="qp-row">Delay about ${Math.round(p.delay / 60)} min</div>` : ''}<div class="muted small">TomTom Traffic</div></div>`); }]);
  return { remove: () => { map.off('moveend', onMove); seq++; for (let i = clickers.length - 1; i >= 0; i--) if (clickers[i][0] === 'trafficpts') clickers.splice(i, 1); rm(['trafficpts', 'trafficinc', 'traffic'], ['trafficpts', 'trafficinc', 'traffic']); } };
};

// ================= Route weather (drawn by route.js) =================
let routeData = null, routeMarkers = [];
export function drawRoute(fc, stops, line, keepView) {
  clearRoute(true); routeData = [fc, stops, line];
  if (!styleReady) return;
  map.addSource('route', { type: 'geojson', data: fc });
  map.addLayer({ id: 'route-casing', type: 'line', source: 'route', layout: { 'line-cap': 'round', 'line-join': 'round' }, paint: { 'line-color': '#0b1020', 'line-width': 9, 'line-opacity': 0.75 } });
  map.addLayer({ id: 'route-line', type: 'line', source: 'route', layout: { 'line-cap': 'round', 'line-join': 'round' }, paint: { 'line-color': ['get', 'c'], 'line-width': 5.5 } });
  routeMarkers = stops.map((p) => { const m = pin([p.lon, p.lat], p.html, `route-pin k-${p.kind} sv${p.sev}`, () => popup([p.lon, p.lat], `<div class="qp">${p.tip}</div>`)); return m; });
  if (!keepView) {
    const b = new ml.LngLatBounds(); line.forEach((c) => b.extend(c));
    const desk = innerWidth > 760;
    map.fitBounds(b, { padding: desk ? { top: 80, bottom: 140, left: 380, right: 420 } : { top: 140, bottom: 220, left: 30, right: 30 }, duration: 1200, maxZoom: 11 });
  }
}
export function clearRoute(keep) {
  routeMarkers.forEach((m) => m.remove()); routeMarkers = [];
  if (map?.getStyle()) rm(['route-line', 'route-casing'], ['route']);
  if (!keep) routeData = null;
}

// ================= Fronts & pressure centers (WPC coded bulletin) =================
function addFrontImages() {
  const mk = (name, color, shape) => {
    if (map.hasImage(name)) return;
    const s = 24, c = document.createElement('canvas'); c.width = c.height = s; const g = c.getContext('2d');
    g.fillStyle = color; g.beginPath();
    if (shape === 'tri') { g.moveTo(4, 14); g.lineTo(20, 14); g.lineTo(12, 3); } else { g.arc(12, 14, 7, Math.PI, 0); }
    g.closePath(); g.fill();
    map.addImage(name, { width: s, height: s, data: new Uint8Array(g.getImageData(0, 0, s, s).data.buffer) });
  };
  try { mk('f-cold', '#3b82f6', 'tri'); mk('f-warm', '#ef4444', 'semi'); mk('f-occ', '#a855f7', 'tri'); mk('f-occ2', '#a855f7', 'semi'); mk('f-st-c', '#3b82f6', 'tri'); mk('f-st-w', '#ef4444', 'semi'); } catch (e) { console.warn('front icons', e); }
}
function parseFronts(txt) {
  const items = []; let cur = null, valid = '';
  for (const raw of txt.split('\n')) {
    const l = raw.trim(); if (!l) { cur = null; continue; }
    const v = l.match(/VALID\s+(\d{12})Z/); if (v) { if (valid) break; valid = v[1]; } // first (nearest) forecast time only
    const m = l.match(/^(HIGHS|LOWS|COLD|WARM|STNRY|OCFNT|TROF)\b(.*)$/);
    if (m) { cur = { type: m[1], toks: m[2].trim().split(/\s+/).filter(Boolean) }; items.push(cur); }
    else if (cur && /^\d/.test(l)) cur.toks.push(...l.split(/\s+/));
    else cur = null;
  }
  const pt = (s) => { const n = s.length; const latD = n >= 6 ? 3 : 2; return [-(+s.slice(latD) / 10), +s.slice(0, latD) / 10]; };
  const lines = [], centers = [];
  for (const it of items) {
    if (it.type === 'HIGHS' || it.type === 'LOWS') {
      for (let i = 0; i + 1 < it.toks.length; i += 2) centers.push({ hi: it.type === 'HIGHS', mb: it.toks[i], ll: pt(it.toks[i + 1]) });
    } else if (it.toks.length > 1) {
      lines.push({ type: 'Feature', properties: { t: it.type }, geometry: { type: 'LineString', coordinates: it.toks.map(pt) } });
    }
  }
  return { lines: { type: 'FeatureCollection', features: lines }, centers, valid };
}
ADD.fronts = async () => {
  const { lines, centers, valid } = parseFronts(await feeds.fronts());
  const color = ['match', ['get', 't'], 'COLD', '#3b82f6', 'WARM', '#ef4444', 'OCFNT', '#a855f7', 'STNRY', '#ef4444', '#f59e0b'];
  const sym = (t, img, off = 0) => ({ type: 'symbol', filter: ['==', ['get', 't'], t], layout: { 'symbol-placement': 'line', 'symbol-spacing': 46, 'icon-image': img, 'icon-size': 0.75, 'icon-rotation-alignment': 'map', 'icon-allow-overlap': true, 'icon-offset': [off, -6] } });
  const h = geo('fronts', lines, [
    { type: 'line', filter: ['!=', ['get', 't'], 'TROF'], paint: { 'line-color': color, 'line-width': 3 } },
    { type: 'line', filter: ['==', ['get', 't'], 'STNRY'], paint: { 'line-color': '#3b82f6', 'line-width': 3, 'line-dasharray': [2, 2] } },
    { type: 'line', filter: ['==', ['get', 't'], 'TROF'], paint: { 'line-color': '#f59e0b', 'line-width': 2, 'line-dasharray': [2, 2] } },
    sym('COLD', 'f-cold'), sym('WARM', 'f-warm'), sym('OCFNT', 'f-occ'), sym('OCFNT', 'f-occ2', 12), sym('STNRY', 'f-st-c'), sym('STNRY', 'f-st-w', 12),
  ]);
  const mk = centers.map((c) => pin(c.ll, `<b>${c.hi ? 'H' : 'L'}</b><small>${esc(c.mb)}</small>`, `pc ${c.hi ? 'pc-h' : 'pc-l'}`));
  return { remove: () => { h.remove(); mk.forEach((m) => m.remove()); } };
};

// ================= Temperatures & air quality grids =================
ADD.temps = async () => gridLayer('temps', async (g) => (await gridPoints(g.lats, g.lons)).map((p) => p.current && ({
  html: `<div style="background:${tempColor(p.current.temperature_2m)}"><b>${Math.round(U.temp(p.current.temperature_2m))}°</b></div>`,
})));
// Wave height grid over the ocean in view (land points come back empty and are skipped)
ADD.waves = async () => gridLayer('waves', async (g) => {
  let j = await getData(`https://marine-api.open-meteo.com/v1/marine?latitude=${g.lats.join(',')}&longitude=${g.lons.join(',')}&current=wave_height,wave_direction,wave_period`, { cache: 900e3 });
  if (!Array.isArray(j)) j = [j];
  const col = (m) => (m < 0.6 ? '#22c55e' : m < 1.2 ? '#84cc16' : m < 2 ? '#eab308' : m < 3 ? '#f97316' : '#ef4444');
  const imperial = U.temp(10) > 30;
  return j.map((p) => { const c = p?.current; if (!c || c.wave_height == null) return null;
    return { html: `<div style="background:${col(c.wave_height)}"><b>${imperial ? Math.round(c.wave_height * 3.28084) + "'" : c.wave_height.toFixed(1) + 'm'}</b><i class="wave-dir" style="transform:rotate(${(c.wave_direction + 180) % 360}deg)">↑</i></div>` }; });
});
ADD.aqi = async () => gridLayer('aqi', async (g) => (await aqGrid(g.lats, g.lons)).map((p) => p.current?.us_aqi != null && ({
  html: `<div style="background:${aqiInfo(p.current.us_aqi).color}"><b>${Math.round(p.current.us_aqi)}</b><small>AQI</small></div>`,
})));
// ================= Rain rate, echo tops, road weather =================
// MRMS precipitation rate (inches per hour), every 2 minutes. IEM names each image by its UTC time.
const IEMC = 'https://mesonet.agron.iastate.edu/c/tile.py/1.0.0';
ADD.rainrate = async () => {
  let t = Math.floor((Date.now() - 6 * 60e3) / 120e3) * 120e3;
  try { const j = await feeds.iemTms(); const s = (j.services || []).find((x) => /a2m/i.test(x.id || '') && x.utc_valid); if (s) t = new Date(s.utc_valid).getTime(); } catch { /* estimate */ }
  const stamp = new Date(t).toISOString().replace(/[-:T]/g, '').slice(0, 12);
  return raster('rainrate', `${IEMC}/mrms::a2m-${stamp}/{z}/{x}/{y}.png`, { opacity: 0.8, maxzoom: 10, before: firstRadarOr() });
};
// Echo tops: how high the storm tops reach (NEXRAD EET mosaic). Taller tops mean stronger updrafts.
ADD.echotops = async () => raster('echotops', `${IEM}/nexrad-eet/{z}/{x}/{y}.png?_=${Math.floor(Date.now() / 300e3)}`, { opacity: 0.75, maxzoom: 10 });
// Road weather, estimated from the latest weather at each spot: snow, ice, wet or dry pavement.
const ROAD = { dry: ['Dry', '#16a34a'], wet: ['Wet', '#2563eb'], slush: ['Slushy', '#7c3aed'], snow: ['Snow', '#e5e7eb'], ice: ['Icy', '#db2777'], frost: ['Frost risk', '#06b6d4'] };
export function roadState(h, i) {
  const t = h.temperature_2m[i], prev = (k) => h[k].slice(Math.max(0, i - 3), i + 1).reduce((a, b) => a + (b || 0), 0);
  const p3 = prev('precipitation'), s3 = prev('snowfall'), code = h.weather_code[i];
  if ([56, 57, 66, 67].includes(code) || (t <= 0 && p3 >= 0.2 && s3 < 0.1)) return 'ice';
  if (s3 >= 0.5 || [71, 73, 75, 77, 85, 86].includes(code)) return t > 1 ? 'slush' : 'snow';
  if (p3 >= 0.2 || h.precipitation[i] > 0) return t <= 1 ? 'ice' : 'wet';
  if (t <= 1 && (h.dew_point_2m?.[i] ?? -99) >= t - 1) return 'frost';
  return 'dry';
}
ADD.road = async () => gridLayer('road', async (g) => {
  let j = await getData(`https://api.open-meteo.com/v1/forecast?latitude=${g.lats.join(',')}&longitude=${g.lons.join(',')}&hourly=temperature_2m,dew_point_2m,precipitation,snowfall,weather_code&past_hours=3&forecast_hours=1&timezone=GMT`, { cache: 600e3 });
  if (!Array.isArray(j)) j = [j];
  return j.map((p) => { const h = p?.hourly; if (!h?.time?.length) return null;
    const now = Date.now(); let i = h.time.findIndex((t) => new Date(t + 'Z').getTime() > now) - 1; if (i < 0) i = h.time.length - 1;
    const [label, color] = ROAD[roadState(h, i)];
    return { html: `<div class="road-chip" style="background:${color}${label === 'Snow' ? ';color:#111' : ''}"><b>${label}</b></div>` }; });
});
function gridLayer(id, fetchCells) {
  let list = [], seq = 0;
  const draw = async () => {
    const my = ++seq; const g = viewGrid(map.getContainer().clientWidth > 900 ? 9 : 6, 6);
    const cells = await fetchCells(g).catch(() => null);
    if (!cells || my !== seq || !active[id]) return;
    list.forEach((m) => m.remove());
    list = cells.map((c, i) => c && pin([+g.lons[i], +g.lats[i]], c.html, 'tbub')).filter(Boolean);
  };
  let t; const onMove = () => { clearTimeout(t); t = setTimeout(draw, 600); };
  map.on('moveend', onMove);
  draw();
  return { remove: () => { seq++; map.off('moveend', onMove); list.forEach((m) => m.remove()); } };
}

// ================= Animated winds =================
ADD.winds = async () => {
  const cv = document.createElement('canvas'); cv.className = 'wind-canvas';
  map.getContainer().appendChild(cv);
  const ctx = cv.getContext('2d');
  let grid = null, parts = [], raf = 0, moving = false, seq = 0;
  const dpr = Math.min(2, devicePixelRatio || 1);
  const size = () => { const c = map.getCanvas(); cv.width = c.clientWidth * dpr; cv.height = c.clientHeight * dpr; cv.style.width = c.clientWidth + 'px'; cv.style.height = c.clientHeight + 'px'; ctx.setTransform(dpr, 0, 0, dpr, 0, 0); };
  const load = async () => {
    const my = ++seq; const g = viewGrid(10, 8);
    const pts = await gridPoints(g.lats, g.lons).catch(() => null);
    if (!pts || my !== seq) return;
    const u = [], v = [];
    pts.forEach((p) => { const sp = p.current?.wind_speed_10m ?? 0, d = (p.current?.wind_direction_10m ?? 0) * Math.PI / 180; u.push(-sp * Math.sin(d)); v.push(-sp * Math.cos(d)); });
    grid = { ...g, cols: 10, rows: 8, u, v };
    parts = Array.from({ length: map.getContainer().clientWidth > 900 ? 2200 : 1100 }, () => seed({}));
  };
  const seed = (p) => { p.lng = grid.w + Math.random() * (grid.e - grid.w); p.lat = grid.s + Math.random() * (grid.n - grid.s); p.age = Math.random() * 90 | 0; return p; };
  const sample = (lng, lat) => {
    const fx = (lng - grid.w) / (grid.e - grid.w) * grid.cols - 0.5, fy = (lat - grid.s) / (grid.n - grid.s) * grid.rows - 0.5;
    if (fx < -0.5 || fy < -0.5 || fx > grid.cols - 0.5 || fy > grid.rows - 0.5) return null;
    const x0 = Math.max(0, Math.min(grid.cols - 1, Math.floor(fx))), y0 = Math.max(0, Math.min(grid.rows - 1, Math.floor(fy)));
    const x1 = Math.min(grid.cols - 1, x0 + 1), y1 = Math.min(grid.rows - 1, y0 + 1), tx = Math.max(0, Math.min(1, fx - x0)), ty = Math.max(0, Math.min(1, fy - y0));
    const at = (a, x, y) => a[y * grid.cols + x];
    const lerp = (a) => (at(a, x0, y0) * (1 - tx) + at(a, x1, y0) * tx) * (1 - ty) + (at(a, x0, y1) * (1 - tx) + at(a, x1, y1) * tx) * ty;
    return [lerp(grid.u), lerp(grid.v)];
  };
  const frame = () => {
    raf = requestAnimationFrame(frame);
    if (!grid || moving) return;
    const W = cv.width / dpr, Hh = cv.height / dpr;
    ctx.globalCompositeOperation = 'destination-in'; ctx.fillStyle = 'rgba(0,0,0,0.93)'; ctx.fillRect(0, 0, W, Hh);
    ctx.globalCompositeOperation = 'source-over';
    ctx.strokeStyle = document.documentElement.dataset.theme === 'light' ? 'rgba(15,23,42,0.75)' : 'rgba(255,255,255,0.8)';
    ctx.lineWidth = 1.2; ctx.beginPath();
    const k = 0.07 * (grid.e - grid.w) / Math.max(300, W);
    for (const p of parts) {
      const uv = sample(p.lng, p.lat);
      if (!uv || ++p.age > 110) { seed(p); p.age = 0; continue; }
      const a = map.project([p.lng, p.lat]);
      p.lng += uv[0] * k / Math.max(0.3, Math.cos(p.lat * Math.PI / 180)); p.lat += uv[1] * k;
      const b = map.project([p.lng, p.lat]);
      if (Math.abs(a.x - b.x) > 30 || Math.abs(a.y - b.y) > 30) continue;
      ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y);
    }
    ctx.stroke();
  };
  const onStart = () => { moving = true; ctx.clearRect(0, 0, cv.width, cv.height); };
  const onEnd = () => { moving = false; size(); load(); };
  size(); await load(); frame();
  map.on('movestart', onStart); map.on('moveend', onEnd); map.on('resize', size);
  if (map.getZoom() < 3) toast('Zoom in for the best wind detail');
  return { remove: () => { seq++; cancelAnimationFrame(raf); cv.remove(); map.off('movestart', onStart); map.off('moveend', onEnd); map.off('resize', size); } };
};

// ================= Tropics (NHC) =================
ADD.tropics = async () => {
  const j = await feeds.storms();
  const storms = j.activeStorms || [];
  window.dispatchEvent(new CustomEvent('storms', { detail: storms }));
  const mk = storms.map((s) => {
    const mph = Math.round((s.intensity || 0) * 1.15078);
    const kind = s.classification === 'HU' ? 'Hurricane' : s.classification === 'TS' ? 'Tropical Storm' : s.classification === 'TD' ? 'Tropical Depression' : 'Tropical System';
    return pin([s.longitudeNumeric, s.latitudeNumeric], `<span>🌀</span><b>${esc(s.name)}</b>`, 'storm-pin', () => popup([s.longitudeNumeric, s.latitudeNumeric], `<b>${kind} ${esc(s.name)}</b><br>Winds ${mph} mph · ${esc(s.pressure)} mb<br>Moving ${compass(+s.movementDir)} at ${Math.round((s.movementSpeed || 0) * 1.15078)} mph<br><a href="https://www.nhc.noaa.gov/" target="_blank" rel="noopener">NHC advisory ↗</a> · <a href="https://www.tropicaltidbits.com/storminfo/" target="_blank" rel="noopener">Models ↗</a>`));
  });
  // Forecast cones and tracks from the NHC GIS service
  let geoH = null;
  if (storms.length) {
    try {
      const meta = await feeds.nhcMeta();
      const want = storms.flatMap((s) => ['Forecast Cone', 'Forecast Track'].map((n) => meta.layers.find((l) => l.name === `${s.binNumber} ${n}`)?.id)).filter((x) => x != null);
      const parts = await Promise.all(want.map((id) => feeds.nhcLayer(id).catch(() => null)));
      const features = parts.filter(Boolean).flatMap((p) => p.features || []);
      if (features.length && active.tropics) {
        geoH = geo('nhc', { type: 'FeatureCollection', features }, [
          { type: 'fill', filter: ['match', ['geometry-type'], ['Polygon', 'MultiPolygon'], true, false], paint: { 'fill-color': '#ffffff', 'fill-opacity': 0.14 } },
          { type: 'line', filter: ['match', ['geometry-type'], ['Polygon', 'MultiPolygon'], true, false], paint: { 'line-color': '#ffffff', 'line-width': 1.5 } },
          { type: 'line', filter: ['match', ['geometry-type'], ['LineString', 'MultiLineString'], true, false], paint: { 'line-color': '#fbbf24', 'line-width': 2.5 } },
        ]);
      }
    } catch (e) { console.warn('nhc cones', e); }
  }
  return { remove: () => { mk.forEach((m) => m.remove()); geoH?.remove(); } };
};

// ================= Drought, quakes, fires =================
ADD.drought = async () => {
  const j = await feeds.drought();
  return geo('drought', j, [{ type: 'fill', paint: { 'fill-color': ['match', ['to-number', ['get', 'dm']], 0, '#ffff00', 1, '#fcd37f', 2, '#ffaa00', 3, '#e60000', 4, '#730000', '#999'], 'fill-opacity': 0.45 } }],
    (f, ll) => popup(ll, `<b>Drought: ${['D0 Abnormally Dry', 'D1 Moderate', 'D2 Severe', 'D3 Extreme', 'D4 Exceptional'][+f.properties.dm] || ''}</b><br><small>US Drought Monitor</small>`));
};
ADD.quakes = async () => {
  const j = await feeds.quakes();
  return geo('quakes', j, [{ type: 'circle', top: true, paint: { 'circle-radius': ['max', 4, ['*', ['get', 'mag'], 2.6]], 'circle-color': '#fb923c', 'circle-opacity': 0.75, 'circle-stroke-color': '#7c2d12', 'circle-stroke-width': 1 } }],
    (f, ll) => popup(ll, `<b>M${(+f.properties.mag).toFixed(1)}</b> ${esc(f.properties.place)}<br><small>${new Date(+f.properties.time).toLocaleString()}</small><br><a href="${esc(f.properties.url)}" target="_blank" rel="noopener">USGS ↗</a>`));
};
ADD.fires = async () => {
  const j = await feeds.fires();
  return geo('fires', j, [{ type: 'circle', top: true, paint: { 'circle-radius': 6, 'circle-color': '#f97316', 'circle-stroke-color': '#7f1d1d', 'circle-stroke-width': 2 } }],
    (f, ll) => { const p = f.properties; popup(ll, `<b>🔥 ${esc(p.IncidentName)} Fire</b><br>${p.IncidentSize ? Math.round(p.IncidentSize).toLocaleString() + ' acres' : ''}${p.PercentContained != null ? ` · ${p.PercentContained}% contained` : ''}`); });
};

// ================= ISS =================
ADD.iss = async () => {
  const now = Math.floor(Date.now() / 1000);
  const ts = Array.from({ length: 30 }, (_, i) => now + i * 180);
  const chunks = await Promise.all([0, 10, 20].map((o) => feeds.issPath(ts.slice(o, o + 10)).catch(() => [])));
  const pts = chunks.flat().map((p) => [p.longitude, p.latitude]);
  const segs = [[]]; pts.forEach((p, i) => { if (i && Math.abs(p[0] - pts[i - 1][0]) > 180) segs.push([]); segs.at(-1).push(p); });
  const h = geo('iss', { type: 'FeatureCollection', features: segs.filter((s) => s.length > 1).map((s) => ({ type: 'Feature', properties: {}, geometry: { type: 'LineString', coordinates: s } })) },
    [{ type: 'line', top: true, paint: { 'line-color': '#c084fc', 'line-width': 1.5, 'line-dasharray': [2, 2] } }]);
  const first = await feeds.iss();
  const m = pin([first.longitude, first.latitude], '<span>🛰️</span><b>ISS</b>', 'iss-pin', async () => {
    const p = await feeds.iss(); popup([p.longitude, p.latitude], `<b>International Space Station</b><br>Altitude ${Math.round(p.altitude * 0.621)} mi · ${Math.round(p.velocity * 0.621).toLocaleString()} mph<br>${p.visibility === 'daylight' ? 'In sunlight' : 'In Earth\'s shadow'}`);
  });
  const t = setInterval(async () => { try { const p = await feeds.iss(); m.setLngLat([p.longitude, p.latitude]); } catch { /* skip */ } }, 5000);
  return { remove: () => { clearInterval(t); m.remove(); h.remove(); } };
};

// ================= My Places (star pins) =================
let placeMarkers = [];
ADD.places = async () => { drawPlaces(); return { remove: () => { placeMarkers.forEach((m) => m.remove()); placeMarkers = []; } }; };
export function drawPlaces() {
  placeMarkers.forEach((m) => m.remove()); placeMarkers = [];
  if (!S.layers.places || !map) return;
  for (const p of H.getPlaces?.() || []) {
    placeMarkers.push(pin([p.lon, p.lat], '<svg width="30" height="38" viewBox="0 0 30 38"><path d="M15 37C15 37 2 22 2 14a13 13 0 0 1 26 0c0 8-13 23-13 23z" fill="#f5a524" stroke="#7c4a03" stroke-width="1.5"/><path d="M15 6.5l2.3 4.8 5.2.7-3.8 3.6.9 5.2-4.6-2.5-4.6 2.5.9-5.2-3.8-3.6 5.2-.7z" fill="#1f1300"/></svg>', 'place-pin', () => quickForecast({ lng: p.lon, lat: p.lat }, p.name)));
  }
}

// ================= Tap / long-press quick forecast =================
export async function quickForecast(ll, name) {
  const lat = ll.lat, lng = ll.lng ?? ll.lon;
  const pop = popup([lng, lat], '<div class="qp">Loading…</div>');
  try {
    const j = await quickPoint(lat, lng);
    const c = j.current, w = wx(c.weather_code, c.is_day), id = 'qp' + Date.now();
    pop.setHTML(`<div class="qp">${name ? `<div class="qp-name">${esc(name)}</div>` : ''}<div class="qp-top">${icon(w.icon, 44)}<div><div class="qp-t">${fmtT(c.temperature_2m)}</div><div>${w.text}</div></div></div>
      <div class="qp-row">Feels ${fmtT(c.apparent_temperature)} · H ${fmtT(j.daily.temperature_2m_max[0])} L ${fmtT(j.daily.temperature_2m_min[0])}</div>
      <div class="qp-row">Wind ${compass(c.wind_direction_10m)} ${fmtW(c.wind_speed_10m)}, gusts ${fmtW(c.wind_gusts_10m)}</div>
      <div class="qp-row">Rain chance today ${j.daily.precipitation_probability_max[0] ?? '--'}%</div>
      <div class="qp-btns"><button class="btn small ghost" id="${id}s">${name ? '★ Saved' : '☆ Save place'}</button><button class="btn small" id="${id}f">Full forecast</button></div></div>`);
    setTimeout(() => {
      const f = document.getElementById(id + 'f'), s = document.getElementById(id + 's');
      if (f) f.onclick = () => { pop.remove(); H.onPick?.({ lat, lon: lng }, name); };
      if (s && !name) s.onclick = async () => { s.disabled = true; s.textContent = 'Saving…'; await H.onSavePlace?.({ lat, lon: lng }); s.textContent = '★ Saved'; };
    }, 0);
  } catch { pop.setHTML('<div class="qp">Could not load this spot.</div>'); }
}

// ================= Bottom dock & sheets =================
function buildDock() {
  $('#tlPlay').innerHTML = PAUSE;
  $('#tlPlay').onclick = () => (R.playing ? pause() : play());
  $('#tlRange').oninput = (e) => { pause(); showFrame(+e.target.value); };
  $('#legendBar').style.background = `linear-gradient(90deg,${DBZ_LEGEND.join(',')})`;
  $('#srcBtn').onclick = openSourceSheet;
  $('#toolLayers').onclick = openLayersSheet;
  $('#toolStyle').onclick = openStyleSheet;
  $('#toolInfo').onclick = () => quickForecast(map.getCenter());
  $('#toolGlobe').onclick = () => map.flyTo({ zoom: map.getZoom() > 3 ? 1.6 : 6.5, duration: 1500 });
  $('#sheetClose').onclick = closeSheet;
}
function updateDock() {
  const on = S.layers.radar;
  const sp = SITE_PRODUCTS[S.siteFam] || SITE_PRODUCTS.ref;
  $('#srcName').textContent = on ? (S.radarSrc === 'us' ? (S.hiDef ? 'Hi-Def Radar' : 'Standard Radar') : S.radarSrc === 'site' ? `K${S.site || ''} ${sp[0].replace(/ \(.*\)/, '')}${sp[1] ? ` ${TILTS[S.tilt]}` : ''}` : 'Global Radar') : 'Radar Off';
  $('#legendBar').classList.remove('vel');
  $('#legendBar').style.background = on && S.radarSrc === 'site' && LEGENDS[S.siteFam] ? LEGENDS[S.siteFam] : `linear-gradient(90deg,${DBZ_LEGEND.join(',')})`;
  $('#legendBar').style.opacity = on ? 1 : 0.25;
  $('#tlPlay').disabled = !on;
  if (!on) { $('#tlTime').textContent = '--'; $('#tlAgo').textContent = ''; }
}
function openSourceSheet() {
  const sel = (v) => (v === 'off' ? !S.layers.radar : S.layers.radar && (v === 'std' ? S.radarSrc === 'us' && !S.hiDef : v === 'us' ? S.radarSrc === 'us' && S.hiDef : S.radarSrc === v));
  const opt = (v, t, d) => `<button class="opt-row${sel(v) ? ' on' : ''}" data-v="${v}"><span class="opt-thumb ${v}"></span><span><b>${t}</b><small>${d}</small></span><i>✓</i></button>`;
  openSheet('Radar', `<div class="opt-list">
    ${opt('us', 'Hi-Def Radar', 'US NEXRAD mosaic · smoothed, drizzle and clutter removed')}
    ${opt('std', 'Standard Radar', 'The US mosaic without smoothing filters')}
    ${opt('global', 'Global Radar', 'Worldwide coverage · lower resolution')}
    ${opt('off', 'Radar Off', 'Hide the radar loop')}</div>
    <div class="sheet-sub">Loop settings</div>
    <label class="slider">Opacity <input type="range" id="opacity" min="0.2" max="1" step="0.05" value="${S.opacity}"></label>
    <label class="slider">Loop speed <input type="range" id="speed" min="150" max="1000" step="50" value="${1150 - S.speed}"></label>`, (b) => {
    $$('.opt-row', b).forEach((r) => r.onclick = () => {
      const v = r.dataset.v;
      if (v === 'off') S.layers.radar = false;
      else {
        const src = v === 'std' ? 'us' : v, hd = v !== 'std';
        S.layers.radar = true;
        if (S.radarSrc !== src || (src === 'us' && S.hiDef !== hd)) { S.radarSrc = src; S.hiDef = hd; disable('radar'); }
      }
      applyLayers(); closeSheet();
    });
    $('#opacity', b).oninput = (e) => { S.opacity = +e.target.value; showFrame(R.idx); save(); };
    $('#speed', b).oninput = (e) => { S.speed = 1150 - +e.target.value; save(); if (R.playing) play(); };
  });
}
const OPTS = {
  radarOpts: () => `<label class="slider">Opacity <input type="range" data-o="opacity" min="0.2" max="1" step="0.05" value="${S.opacity}"></label><label class="slider">Loop speed <input type="range" data-o="speed" min="150" max="1000" step="50" value="${1150 - S.speed}"></label>`,
  satOpts: () => `<div class="seg" data-o="sat">${[['ir', 'Infrared'], ['vis', 'Visible'], ['wv', 'Water vapor'], ['geocolor', 'True color']].map(([v, t]) => `<button data-v="${v}" class="${S.sat === v ? 'on' : ''}">${t}</button>`).join('')}</div><small class="muted">True color runs about 90 minutes behind real time.</small>`,
  surgeOpts: () => `<div class="seg" data-o="surgeCat">${['1', '2', '3', '4', '5'].map((v) => `<button data-v="${v}" class="${S.surgeCat === v ? 'on' : ''}">Cat ${v}</button>`).join('')}</div><small class="muted">Worst-case flooding above ground for a hurricane of that strength (NHC). Not a forecast for any one storm.</small>`,
  snowOpts: () => `<div class="seg" data-o="snowDay">${['1', '2', '3'].map((v) => `<button data-v="${v}" class="${S.snowDay === v ? 'on' : ''}">Day ${v}</button>`).join('')}</div><div class="seg" data-o="snowAmt">${[['4', '4"+ snow'], ['8', '8"+'], ['12', '12"+'], ['ice', '¼" ice']].map(([v, t]) => `<button data-v="${v}" class="${S.snowAmt === v ? 'on' : ''}">${t}</button>`).join('')}</div><small class="muted">WPC chance of reaching that amount.</small>`,
  hailOpts: () => `<div class="seg" data-o="hail">${[['24', '24 hours'], ['72', '3 days'], ['168', '7 days']].map(([v, t]) => `<button data-v="${v}" class="${S.hail === v ? 'on' : ''}">${t}</button>`).join('')}</div><small class="muted">Hail reports sized by stone size, plus today's SPC hail risk area.</small>`,
  dopplerOpts: () => {
    const on = S.radarSrc === 'site' && S.layers.radar;
    const tilted = SITE_PRODUCTS[S.siteFam]?.[1];
    return `<small class="muted">${on ? `Showing K${S.site}. ` : 'Tap a radar dish on the map, or pick a product to use the radar nearest you. '}</small>
      <div class="qp-prods" data-doppler>${Object.entries(SITE_PRODUCTS).map(([k, [t]]) => `<button class="btn small${on && S.siteFam === k ? '' : ' ghost'}" data-sp="${k}">${t.replace(/ \(.*\)/, '')}</button>`).join('')}</div>
      <div class="seg small qp-tilt" data-dtilt>${TILTS.map((t, i) => `<button data-tilt="${i}" class="${on && tilted && S.tilt === i ? 'on' : ''}"${on && !tilted ? ' disabled' : ''}>${t}</button>`).join('')}</div>
      ${on ? '<button class="btn small ghost" data-sp="mosaic">Back to Hi-Def mosaic</button>' : ''}`;
  },
  rainOpts: () => `<div class="seg" data-o="rain">${[['1h', 'Past hour'], ['24h', '24 hours'], ['72h', '72 hours']].map(([v, t]) => `<button data-v="${v}" class="${S.rain === v ? 'on' : ''}">${t}</button>`).join('')}</div>`,
};
// ================= Layers sheet: Loops / Overlays / Radars (same layout as the app) =================
// Loops: picture cards for the radar, satellite and rain loops. Overlays: switches for everything drawn on top.
// Radars: every NEXRAD site by state, the three nearest first, with search.
const LOOP_IDS = new Set(['radar', 'sat', 'lightning', 'rainrate', 'rain', 'echotops', 'sites']);
const THUMB_BASE = `${ESRI}/Canvas/World_Dark_Gray_Base/MapServer/tile/4/6/4`;
let layersTab = store.get('layersTab', 'loops');
let statesP;
const siteStates = () => (statesP ||= fetch('/data/radar-states.json').then((r) => r.json()).catch(() => ({})));
const thumb = (img, sym) => {
  const hd = img?.startsWith('hidef:'); const src = hd ? img.slice(6) : img;
  return `<span class="lthumb"${hd ? ` data-hd="${src}"` : ''} style="background-image:${src ? `url('${src}'),` : ''}url('${THUMB_BASE}')">${sym ? `<i>${sym}</i>` : ''}</span>`;
};
// Swap the Hi-Def card's thumbnail for a smoothed copy
async function smoothThumbs(root) {
  for (const el of $$('[data-hd]', root)) {
    try { const { data } = await hiDefTile({ url: el.dataset.hd.replace('https://', 'hidef://') }); el.style.backgroundImage = `url('${URL.createObjectURL(new Blob([data], { type: 'image/png' }))}'),url('${THUMB_BASE}')`; } catch { /* keep the plain one */ }
  }
}

function openLayersSheet() {
  const pills = `<div class="lpills">${[['loops', 'Loops'], ['overlays', 'Overlays'], ['radars', 'Radars']].map(([k, t]) => `<button data-ltab="${k}" class="${layersTab === k ? 'on' : ''}">${t}</button>`).join('')}</div><div id="lpane"></div>`;
  openSheet('Layers', pills, (b) => {
    $$('[data-ltab]', b).forEach((x) => x.onclick = () => {
      layersTab = x.dataset.ltab; store.set('layersTab', layersTab);
      $$('[data-ltab]', b).forEach((y) => y.classList.toggle('on', y === x));
      renderLayersPane();
    });
    renderLayersPane();
  });
}
function renderLayersPane() {
  const p = $('#lpane'); if (!p) return;
  if (layersTab === 'overlays') overlaysPane(p);
  else if (layersTab === 'radars') radarsPane(p);
  else loopsPane(p);
}

// ---------- Loops ----------
function loopsPane(p) {
  const mosaic = S.layers.radar && S.radarSrc !== 'site';
  const geoT = new Date(Math.floor((Date.now() - 90 * 60e3) / 600e3) * 600e3).toISOString().replace('.000Z', 'Z');
  const goes = (ch) => `${IEM}/goes_east_conus_${ch}/4/4/6.png`;
  const cards = [
    ['radar:us', 'Hi-Def Radar', 'Smooth, high-resolution radar mosaic', mosaic && S.radarSrc === 'us' && S.hiDef, `hidef:${IEM}/nexrad-n0q-900913/4/4/6.png`],
    ['radar:std', 'Standard Radar', 'The radar mosaic without smoothing filters', mosaic && S.radarSrc === 'us' && !S.hiDef, `${IEM}/nexrad-n0q-900913/4/4/6.png`],
    ['radar:global', 'Global Radar', 'Worldwide coverage at lower resolution', mosaic && S.radarSrc === 'global', null, '🌐'],
    ['sat:geocolor', 'True Color Satellite', 'Clouds as your eyes would see them (daytime, about 90 minutes behind)', S.layers.sat && S.sat === 'geocolor', `https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/GOES-East_ABI_GeoColor/default/${geoT}/GoogleMapsCompatible_Level7/4/6/4.jpg`],
    ['sat:vis', 'Visible Satellite', 'Sharp daytime cloud detail', S.layers.sat && S.sat === 'vis', goes('ch02')],
    ['sat:ir', 'Infrared Satellite', 'Cloud-top temperatures, day and night', S.layers.sat && S.sat === 'ir', goes('ch13')],
    ['sat:wv', 'Water Vapor', 'Moisture in the middle and upper air', S.layers.sat && S.sat === 'wv', goes('ch09')],
    ['rainrate', 'Rain Rate', "How hard it's raining right now", S.layers.rainrate, null, '💧'],
    ['rain:1h', 'Past Hour Rain', 'Rain that fell in the last hour', S.layers.rain && S.rain === '1h', `${IEM}/q2-n1p-900913/4/4/6.png`],
    ['rain:24h', 'Rain Totals (24 hr)', 'Rain that fell in the last day', S.layers.rain && S.rain === '24h', `${IEM}/q2-p24h-900913/4/4/6.png`],
    ['rain:72h', 'Rain Totals (3 days)', 'Rain that fell in the last three days', S.layers.rain && S.rain === '72h', `${IEM}/q2-p72h-900913/4/4/6.png`],
    ['echotops', 'Echo Tops', 'How tall the storms are', S.layers.echotops, `${IEM}/nexrad-eet/4/4/6.png`],
    ['lightning', 'Lightning', 'Live strikes and strike density', S.layers.lightning, null, '⚡'],
    ['none', 'No Loop', 'Hide the radar and satellite', !S.layers.radar && !S.layers.sat, null, '⊘'],
  ];
  p.innerHTML = `<div class="lcards">${cards.map(([k, t, d, on, img, sym]) => {
    const id = k.split(':')[0];
    const locked = k !== 'none' && !canLayer(id);
    return `<button class="lcard${on && !locked ? ' on' : ''}" data-loop="${k}">${thumb(img, sym)}<span class="ltext"><b>${t} ${locked ? badge(tierOf(id)) : ''}</b><small>${d}</small></span>${locked ? '<span class="llock">🔒</span>' : ''}</button>`;
  }).join('')}</div>
  <div class="sheet-sub">Radar settings</div><div class="lrow-opts">${OPTS.radarOpts()}</div>`;
  smoothThumbs(p);

  $$('[data-loop]', p).forEach((c) => c.onclick = () => {
    const k = c.dataset.loop; const [id, v] = k.split(':');
    if (k === 'none') {
      S.layers.radar = false; S.layers.sat = false;
      if (S.radarSrc === 'site') S.radarSrc = 'us';
      applyLayers(); return loopsPane(p);
    }
    if (!canLayer(id)) { gate(id, layerName(id)); return; }
    if (id === 'radar') {
      const src = v === 'std' ? 'us' : v, hd = v !== 'std';
      S.layers.radar = true;
      if (S.radarSrc !== src || (src === 'us' && S.hiDef !== hd)) { S.radarSrc = src; S.hiDef = hd; disable('radar'); }
      applyLayers();
    } else if (id === 'sat' || id === 'rain') {
      const key = id === 'sat' ? 'sat' : 'rain';
      if (S.layers[id] && S[key] === v) toggleLayer(id, false);
      else { S[key] = v; S.layers[id] = true; save(); refresh(id); }
    } else toggleLayer(id, !S.layers[id]);
    loopsPane(p);
  });
  $$('[data-o="opacity"]', p).forEach((i) => i.oninput = () => { S.opacity = +i.value; showFrame(R.idx); save(); });
  $$('[data-o="speed"]', p).forEach((i) => i.oninput = () => { S.speed = 1150 - +i.value; save(); if (R.playing) play(); });
}

// ---------- Overlays ----------
function overlaysPane(p) {
  const row = ([id, name, opts]) => `<div class="lrow" data-id="${id}">
    <button class="lrow-main" ${opts ? `data-exp="${id}"` : ''}><span>${name} ${badge(tierOf(id))}</span>${opts ? '<i class="chev">›</i>' : ''}</button>
    <label class="tg${canLayer(id) ? '' : ' locked'}"><input type="checkbox" data-layer="${id}" ${S.layers[id] && canLayer(id) ? 'checked' : ''}><span></span></label>
    ${opts ? `<div class="lrow-opts" hidden>${OPTS[opts]()}</div>` : ''}</div>`;
  const openSet = new Set(store.get('layerGroupsOpen', ['Severe Weather', 'Pro: Radar, Marine & Space']));
  const groups = LAYER_GROUPS.map(([g, rows, kind]) => [g, rows.filter(([id]) => !LOOP_IDS.has(id)), kind]).filter(([, rows]) => rows.length);
  p.innerHTML = groups.map(([g, rows, kind]) => {
    const name = kind === 'pro' ? 'Marine & Space' : g;
    const n = rows.filter(([id]) => S.layers[id] && canLayer(id)).length;
    return `<div class="lgroup${openSet.has(g) ? ' open' : ''}" data-g="${esc(g)}">
      <button class="lgroup-head"><span>${name}${kind === 'pro' ? ` ${badge('pro')}` : ''}</span><span class="muted small">${n ? `${n} on` : ''}</span><i class="chev">›</i></button>
      <div class="lgroup-body">${rows.map(row).join('')}</div></div>`;
  }).join('') + '<p class="muted small sheet-foot">Tap anywhere on the map for that spot\'s forecast, or to save it as a place.</p>';

  $$('.lgroup-head', p).forEach((h) => h.onclick = () => {
    const g = h.parentElement; g.classList.toggle('open');
    const cur = new Set(store.get('layerGroupsOpen', ['Severe Weather', 'Pro: Radar, Marine & Space']));
    if (g.classList.contains('open')) cur.add(g.dataset.g); else cur.delete(g.dataset.g);
    store.set('layerGroupsOpen', [...cur]);
  });
  $$('[data-layer]', p).forEach((cb) => cb.onchange = () => {
    const id = cb.dataset.layer;
    if (cb.checked && !canLayer(id)) { cb.checked = false; gate(id, layerName(id)); return; }
    if (cb.checked && id === 'traffic' && !KEYS.tomtom) { cb.checked = false; toast('Traffic needs a TomTom key in config.js'); return; }
    toggleLayer(id, cb.checked);
  });
  $$('[data-exp]', p).forEach((btn) => btn.onclick = () => { const o = btn.closest('.lrow').querySelector('.lrow-opts'); o.hidden = !o.hidden; btn.classList.toggle('open', !o.hidden); });
  $$('.seg[data-o]', p).forEach((sg) => $$('button', sg).forEach((btn) => btn.onclick = () => {
    $$('button', sg).forEach((x) => x.classList.toggle('on', x === btn));
    const key = sg.dataset.o; S[key] = btn.dataset.v; save();
    const lid = key === 'hail' ? 'hail' : key === 'surgeCat' ? 'surgerisk' : 'snowprob';
    if (!canLayer(lid)) { gate(lid, layerName(lid)); return; }
    S.layers[lid] = true; const t = $(`[data-layer="${lid}"]`, p); if (t) t.checked = true; refresh(lid); updateDock();
  }));
}

// ---------- Radars ----------
async function radarsPane(p, q = '') {
  const locked = !canLayer('sites');
  const cur = S.radarSrc === 'site' && S.layers.radar ? S.site : null;
  const head = `<div class="rsearch"><input type="search" id="rq" placeholder="Search radars by name, ID or state" value="${esc(q)}" autocomplete="off"></div>
    ${locked ? `<button class="rpack" data-unlock><b>Doppler radar at any site ${badge('pro')}</b><small>Reflectivity and velocity at 4 tilts, dual-pol, VIL and echo tops. Included in Pro, or get the one-time ${esc(RADAR_PACK_NAME)}.</small></button>`
      : `<div class="lrow-opts rprods">${OPTS.dopplerOpts()}</div>`}
    ${cur ? '<button class="opt-row" data-mosaic><span class="opt-thumb us"></span><span><b>Back to Hi-Def Radar</b><small>The smooth US mosaic</small></span></button>' : ''}`;
  p.innerHTML = `${head}<div id="rlist"><div class="empty">Loading radars…</div></div>`;
  let list, states;
  try { [list, states] = await Promise.all([radarSites(), siteStates()]); } catch { $('#rlist', p).innerHTML = '<div class="empty">Radar sites are unavailable right now.</div>'; return; }
  const c = map.getCenter();
  const miles = (s) => Math.round(Math.hypot(s.lat - c.lat, (s.lon - c.lng) * Math.cos(c.lat * Math.PI / 180)) * 69);
  const state = (s) => states[s.id] || 'Outside the US';
  const row = (s) => `<button class="srow${cur === s.code ? ' on' : ''}" data-site="${s.code}">${RADOME_SVG}<span><b>${s.id}</b><small>${esc(s.name)} · ${miles(s)} mi</small></span>${locked ? '<span class="llock">🔒</span>' : '<i>✓</i>'}</button>`;
  const draw = (term) => {
    const t = term.trim().toLowerCase();
    const match = t ? list.filter((s) => `${s.id} ${s.name} ${state(s)}`.toLowerCase().includes(t)) : list;
    const byState = {};
    for (const s of match) (byState[state(s)] ||= []).push(s);
    const near = t ? '' : `<div class="sheet-sub">Nearest to the map center</div>${[...list].sort((a, b) => miles(a) - miles(b)).slice(0, 3).map(row).join('')}`;
    $('#rlist', p).innerHTML = near + Object.keys(byState).sort((a, b) => (a === 'Outside the US') - (b === 'Outside the US') || a.localeCompare(b))
      .map((st) => `<div class="sheet-sub">${esc(st)}</div>${byState[st].map(row).join('')}`).join('') || '<div class="empty">No radars match that search.</div>';
    $$('[data-site]', p).forEach((b) => b.onclick = async () => {
      if (locked) { gate('sites', 'Doppler radar'); return; }
      S.layers.sites = true;
      await useSite(b.dataset.site, S.radarSrc === 'site' ? S.siteFam : 'ref', S.radarSrc === 'site' ? S.tilt : 0);
      if (!active.sites) applyLayers();
      const st = list.find((x) => x.code === b.dataset.site); if (st) map.flyTo({ center: [st.lon, st.lat], zoom: Math.max(map.getZoom(), 6.5), duration: 900 });
      closeSheet();
    });
  };
  draw(q);
  $('#rq', p).oninput = (e) => draw(e.target.value);
  const un = $('[data-unlock]', p); if (un) un.onclick = () => gate('sites', 'Doppler radar');
  const mo = $('[data-mosaic]', p); if (mo) mo.onclick = () => { S.radarSrc = 'us'; save(); refresh('radar'); updateDock(); if (active.sites) refresh('sites'); radarsPane(p); };
  // Product and tilt for the current (or nearest) site
  const nearestThen = async (fam, tilt) => {
    S.layers.sites = true;
    const code = S.radarSrc === 'site' && S.site ? S.site : nearestSite(list, c.lat, c.lng)?.code || 'MLB';
    await useSite(code, fam, tilt);
    if (!active.sites) applyLayers();
    radarsPane(p, $('#rq', p)?.value || '');
  };
  $$('[data-doppler] [data-sp]', p).forEach((x) => x.onclick = () => nearestThen(x.dataset.sp, S.radarSrc === 'site' ? S.tilt : 0));
  $$('.rprods [data-sp="mosaic"]', p).forEach((x) => x.onclick = () => { S.radarSrc = 'us'; save(); refresh('radar'); updateDock(); if (active.sites) refresh('sites'); radarsPane(p); });
  $$('[data-dtilt] [data-tilt]', p).forEach((x) => x.onclick = () => nearestThen(S.radarSrc === 'site' ? S.siteFam : 'ref', +x.dataset.tilt));
}
const RADAR_PACK_NAME = 'Pro Radar Pack';

// ================= Map background (same choices as the app) =================
function openStyleSheet() {
  const cur = S.style;
  const opts = [['auto', 'Auto', 'Grayscale at night, Daylight in light mode']].concat(Object.entries(STYLES).map(([k, s]) => [k, s.name, s.blurb || '']));
  const tile = (k) => (k === 'auto' ? null : STYLES[k].thumb);
  openSheet('Map Style', `<div class="style-grid">${opts.map(([v, t, d]) => {
    const locked = v === 'vfr' && !canLayer('charts');
    const img = tile(v);
    return `<button class="style-card${cur === v ? ' on' : ''}" data-v="${v}"><span class="style-thumb ${v}"${img ? ` style="background-image:url('${img}')"` : ''}></span><b>${t} ${v === 'vfr' ? badge('pro') : ''}</b>${d ? `<small>${d}</small>` : ''}${locked ? '<span class="llock">🔒</span>' : ''}</button>`;
  }).join('')}</div>`, (b) => {
    $$('.style-card', b).forEach((c) => c.onclick = () => {
      if (c.dataset.v === 'vfr' && !canLayer('charts')) { gate('charts', 'The VFR sectional map'); return; }
      setStyle(c.dataset.v); $$('.style-card', b).forEach((x) => x.classList.toggle('on', x === c));
    });
  });
}

// Units changed: redraw layers that print numbers
export function refreshUnits() { for (const id of ['temps', 'waves']) if (active[id]) refresh(id); }
