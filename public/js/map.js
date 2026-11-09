// Radar map built on MapLibre GL (vector maps, globe view when zoomed out).
// Layers: radar loop, satellite, warnings, fronts, lightning, winds, temps, air quality, rain totals,
// SPC outlook, mesoscale discussions, storm reports, hurricanes, drought, earthquakes, wildfires, ISS.
import { alertColor, DBZ_LEGEND } from './config.js';
import { store, getData, $, $$, esc, U, fmtT, fmtW, compass, toast, tempColor, wx, icon, localTime, aqiInfo, openSheet, closeSheet } from './util.js';
import { feeds, gridPoints, quickPoint, aqGrid, radarSites, nearestSite, siteScans } from './api.js';
import { KEYS } from './config.js';
import { canLayer, tierOf, badge, gate } from './plan.js';

const ml = window.maplibregl;
const ESRI = 'https://services.arcgisonline.com/ArcGIS/rest/services';
const IEM = 'https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0';

export const STYLES = {
  dark: { name: 'Dark', url: 'https://tiles.openfreemap.org/styles/dark' },
  light: { name: 'Light', url: 'https://tiles.openfreemap.org/styles/positron' },
  streets: { name: 'Streets', url: 'https://tiles.openfreemap.org/styles/liberty' },
  satellite: {
    name: 'Satellite',
    url: {
      version: 8,
      glyphs: 'https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf',
      sources: {
        img: { type: 'raster', tiles: [`${ESRI}/World_Imagery/MapServer/tile/{z}/{y}/{x}`], tileSize: 256, maxzoom: 18, attribution: 'Imagery &copy; Esri' },
        ref: { type: 'raster', tiles: [`${ESRI}/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}`], tileSize: 256, maxzoom: 18 },
      },
      layers: [{ id: 'img', type: 'raster', source: 'img' }, { id: 'ref', type: 'raster', source: 'ref' }],
    },
  },
};

const DEFAULT_LAYERS = { radar: true, alerts: true, places: true, fronts: true, sat: false, lightning: false, winds: false, temps: false, aqi: false, rain: false, spc: false, mcd: false, lsr: false, sites: false, hail: false, traffic: false, tropics: true, drought: false, quakes: false, fires: false, iss: false };
export const S = {
  style: store.get('mapStyle', 'auto'),
  radarSrc: store.get('radarSrc', 'us'),
  opacity: store.get('opacity', 0.75),
  speed: store.get('speed', 450),
  sat: store.get('satType', 'ir'),
  rain: store.get('rainType', '24h'),
  hail: store.get('hailHours', '72'),
  site: store.get('radarSite', null),     // e.g. 'MLB' for KMLB
  siteProd: store.get('siteProd', 'N0B'), // N0B reflectivity, N0U velocity
  layers: Object.assign({}, DEFAULT_LAYERS, store.get('layers2', {})),
};
const save = () => { store.set('layers2', S.layers); store.set('mapStyle', S.style); store.set('radarSrc', S.radarSrc); store.set('opacity', S.opacity); store.set('speed', S.speed); store.set('satType', S.sat); store.set('rainType', S.rain); store.set('hailHours', S.hail); store.set('radarSite', S.site); store.set('siteProd', S.siteProd); };

export const LAYER_GROUPS = [
  ['Radar & Satellite', [
    ['radar', 'Radar', 'radarOpts'], ['sites', 'Radar Sites (pick one)'], ['sat', 'Satellite Clouds', 'satOpts'], ['lightning', 'Lightning'], ['rain', 'Rain Totals', 'rainOpts'],
  ]],
  ['Severe Weather', [
    ['alerts', 'Warnings & Watches'], ['spc', 'SPC Severe Outlook'], ['mcd', 'Mesoscale Discussions'], ['lsr', 'Storm Reports (Hail, Wind, Tornado)'],
    ['hail', 'Hail Map', 'hailOpts'],
  ]],
  ['Conditions', [
    ['fronts', 'Fronts & Pressure'], ['winds', 'Winds (animated)'], ['temps', 'Temperatures'], ['aqi', 'Air Quality'],
  ]],
  ['Tropics', [['tropics', 'Hurricane Tracker']]],
  ['More', [
    ['places', 'My Places'], ['traffic', 'Traffic (US roads)'], ['drought', 'Droughts'], ['quakes', 'Earthquakes'], ['fires', 'Wildfires'], ['iss', 'ISS Orbital Tracking'],
  ]],
];

let map, themeFn, H = {}, styleReady = false;
const active = {};
const clickers = []; // [layerId, handler]

// ================= init =================
export function initMap(el, loc, getTheme, handlers) {
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
  if ((S.style === 'auto' ? themeFn() : S.style) === 'dark') brightenDark();
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
export function toggleLayer(id, on) { S.layers[id] = on; applyLayers(); }
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
function popup(lngLat, html) { closePopups(); return new ml.Popup({ maxWidth: '300px', className: 'wx-pop' }).setLngLat(lngLat).setHTML(html).addTo(map); }
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
  if (S.radarSrc === 'site') {
    if (!S.site) { const c = map.getCenter(); S.site = nearestSite(await radarSites(), c.lat, c.lng)?.code || 'MLB'; save(); }
    let scans = [];
    try { scans = (await siteScans(S.site, S.siteProd)).slice(-12); } catch { /* fall back to latest */ }
    if (!scans.length) frames.push({ t: Date.now(), url: `${IEM}/ridge::${S.site}-${S.siteProd}-0/{z}/{x}/{y}.png?_=${Math.floor(Date.now() / 120e3)}`, maxzoom: 12, site: true });
    for (const ts of scans) frames.push({ t: new Date(ts).getTime(), url: `${IEM}/ridge::${S.site}-${S.siteProd}-${ts.replace(/[-:TZ]/g, '').slice(0, 12)}/{z}/{x}/{y}.png`, maxzoom: 12 });
  } else if (S.radarSrc === 'us') {
    let base = Math.floor(Date.now() / 300e3) * 300e3 - 300e3;
    try { const j = await feeds.iemTms(); const s = (j.services || []).find((x) => /n0q/i.test(x.id || '') && x.utc_valid); if (s) base = new Date(s.utc_valid).getTime(); } catch { /* estimate */ }
    const bust = Math.floor(Date.now() / 300e3);
    for (let m = 50; m >= 0; m -= 5) {
      const lname = m ? `nexrad-n0q-900913-m${String(m).padStart(2, '0')}m` : 'nexrad-n0q-900913';
      frames.push({ t: base - m * 60e3, url: `${IEM}/${lname}/{z}/{x}/{y}.png?_=${bust}`, maxzoom: 12 });
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
    map.addSource(id, { type: 'raster', tiles: [f.url], tileSize: 256, maxzoom: f.maxzoom });
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
ADD.lightning = async () => raster('lightning', `${IEM}/goes_east_glm/{z}/{x}/{y}.png?_=${Math.floor(Date.now() / 120e3)}`, { opacity: 0.95, maxzoom: 9 });
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
export async function useSite(code, prod) {
  S.site = code; if (prod) S.siteProd = prod; S.radarSrc = 'site'; S.layers.radar = true; save();
  refresh('radar'); updateDock(); if (active.sites) refresh('sites');
}
ADD.sites = async () => {
  const list = await radarSites();
  const fc = { type: 'FeatureCollection', features: list.map((x) => ({ type: 'Feature', geometry: { type: 'Point', coordinates: [x.lon, x.lat] }, properties: { id: x.id, code: x.code, name: x.name, on: S.radarSrc === 'site' && S.site === x.code ? 1 : 0 } })) };
  return geo('sites', fc, [
    { type: 'circle', top: true, paint: { 'circle-radius': ['case', ['==', ['get', 'on'], 1], 9, 6], 'circle-color': ['case', ['==', ['get', 'on'], 1], '#8b5cf6', '#0b1020'], 'circle-stroke-color': ['case', ['==', ['get', 'on'], 1], '#fff', '#a78bfa'], 'circle-stroke-width': 2 } },
    { type: 'symbol', top: true, layout: { 'text-field': ['get', 'id'], 'text-size': 11, 'text-offset': [0, 1.35], 'text-font': ['Noto Sans Bold'], 'text-allow-overlap': false }, paint: { 'text-color': '#e9d5ff', 'text-halo-color': '#0b1020', 'text-halo-width': 1.6 } },
  ], (f, ll) => {
    const p = f.properties, cur = S.radarSrc === 'site' && S.site === p.code;
    const pop = popup(f.geometry.coordinates, `<div class="qp"><div class="qp-name">${esc(p.id)} · ${esc(p.name)}</div><div class="qp-row">${cur ? 'Showing this radar now' : 'NEXRAD Doppler radar'}</div>
      <div class="qp-btns"><button class="btn small${cur && S.siteProd === 'N0B' ? '' : ' ghost'}" data-sp="N0B">Reflectivity</button><button class="btn small${cur && S.siteProd === 'N0U' ? '' : ' ghost'}" data-sp="N0U">Velocity</button></div>
      ${cur ? '<div class="qp-btns"><button class="btn small ghost" data-sp="mosaic">Back to US mosaic</button></div>' : ''}</div>`);
    setTimeout(() => pop.getElement()?.querySelectorAll('[data-sp]').forEach((b) => b.onclick = () => {
      pop.remove();
      if (b.dataset.sp === 'mosaic') { S.radarSrc = 'us'; save(); refresh('radar'); updateDock(); if (active.sites) refresh('sites'); return; }
      useSite(p.code, b.dataset.sp);
    }), 0);
  });
};

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
  return { remove: () => rm(['trafficinc', 'traffic'], ['trafficinc', 'traffic']) };
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
ADD.aqi = async () => gridLayer('aqi', async (g) => (await aqGrid(g.lats, g.lons)).map((p) => p.current?.us_aqi != null && ({
  html: `<div style="background:${aqiInfo(p.current.us_aqi).color}"><b>${Math.round(p.current.us_aqi)}</b><small>AQI</small></div>`,
})));
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
  $('#srcName').textContent = on ? (S.radarSrc === 'us' ? 'Hi-Def Radar' : S.radarSrc === 'site' ? `K${S.site || ''} ${S.siteProd === 'N0U' ? 'Velocity' : 'Radar'}` : 'Global Radar') : 'Radar Off';
  $('#legendBar').classList.toggle('vel', on && S.radarSrc === 'site' && S.siteProd === 'N0U');
  $('#legendBar').style.opacity = on ? 1 : 0.25;
  $('#tlPlay').disabled = !on;
  if (!on) { $('#tlTime').textContent = '--'; $('#tlAgo').textContent = ''; }
}
function openSourceSheet() {
  const opt = (v, t, d) => `<button class="opt-row${(v === 'off' ? !S.layers.radar : S.layers.radar && S.radarSrc === v) ? ' on' : ''}" data-v="${v}"><span class="opt-thumb ${v}"></span><span><b>${t}</b><small>${d}</small></span><i>✓</i></button>`;
  openSheet('Radar', `<div class="opt-list">
    ${opt('us', 'Hi-Def Radar', 'US NEXRAD mosaic · sharpest detail · every 5 minutes')}
    ${opt('global', 'Global Radar', 'Worldwide coverage · lower resolution')}
    ${opt('site', 'Single Radar Site', `${S.site ? `K${S.site} · ` : ''}one Doppler radar, full detail, reflectivity or velocity`)}
    ${opt('off', 'Radar Off', 'Hide the radar loop')}</div>
    <div class="sheet-sub">Radar site</div>
    <div class="set-pad site-pick"><select id="sitePick"><option>Loading radar sites…</option></select>
      <div class="seg" id="siteProd"><button data-v="N0B" class="${S.siteProd === 'N0B' ? 'on' : ''}">Reflectivity</button><button data-v="N0U" class="${S.siteProd === 'N0U' ? 'on' : ''}">Velocity</button></div>
      <label class="lrow-inline"><input type="checkbox" id="showSites" ${S.layers.sites ? 'checked' : ''}> Show radar sites on the map (tap one to switch)</label></div>
    <div class="sheet-sub">Loop settings</div>
    <label class="slider">Opacity <input type="range" id="opacity" min="0.2" max="1" step="0.05" value="${S.opacity}"></label>
    <label class="slider">Loop speed <input type="range" id="speed" min="150" max="1000" step="50" value="${1150 - S.speed}"></label>`, (b) => {
    $$('.opt-row', b).forEach((r) => r.onclick = () => {
      const v = r.dataset.v;
      if (v === 'off') S.layers.radar = false; else { S.layers.radar = true; if (S.radarSrc !== v) { S.radarSrc = v; disable('radar'); } }
      if (v === 'site') S.layers.sites = true;
      applyLayers(); closeSheet();
    });
    radarSites().then((list) => {
      const c = map.getCenter(), near = nearestSite(list, c.lat, c.lng);
      const d = (x) => Math.round(Math.hypot(x.lat - c.lat, (x.lon - c.lng) * Math.cos(c.lat * Math.PI / 180)) * 69);
      const sorted = [...list].sort((a, b) => d(a) - d(b));
      const sel = $('#sitePick', b); if (!sel) return;
      sel.innerHTML = sorted.map((x) => `<option value="${x.code}" ${(S.site || near?.code) === x.code ? 'selected' : ''}>${x.id} · ${esc(x.name)} (${d(x)} mi)</option>`).join('');
      sel.onchange = () => { useSite(sel.value); const r = list.find((x) => x.code === sel.value); if (r) map.flyTo({ center: [r.lon, r.lat], zoom: Math.max(map.getZoom(), 7) }); };
    }).catch(() => { const sel = $('#sitePick', b); if (sel) sel.innerHTML = '<option>Radar sites unavailable</option>'; });
    $$('#siteProd button', b).forEach((x) => x.onclick = () => { $$('#siteProd button', b).forEach((y) => y.classList.toggle('on', y === x)); useSite(S.site || $('#sitePick', b).value, x.dataset.v); });
    $('#showSites', b).onchange = (e) => toggleLayer('sites', e.target.checked);
    $('#opacity', b).oninput = (e) => { S.opacity = +e.target.value; showFrame(R.idx); save(); };
    $('#speed', b).oninput = (e) => { S.speed = 1150 - +e.target.value; save(); if (R.playing) play(); };
  });
}
function openStyleSheet() {
  const cur = S.style;
  const cards = [['auto', 'Auto', 'Matches light / dark mode'], ['dark', 'Dark', ''], ['light', 'Light', ''], ['streets', 'Streets', ''], ['satellite', 'Satellite', '']];
  openSheet('Map Style', `<div class="style-grid">${cards.map(([v, t, d]) => `<button class="style-card${cur === v ? ' on' : ''}" data-v="${v}"><span class="style-thumb ${v}"></span><b>${t}</b>${d ? `<small>${d}</small>` : ''}</button>`).join('')}</div>`, (b) => {
    $$('.style-card', b).forEach((c) => c.onclick = () => { setStyle(c.dataset.v); $$('.style-card', b).forEach((x) => x.classList.toggle('on', x === c)); });
  });
}
const OPTS = {
  radarOpts: () => `<label class="slider">Opacity <input type="range" data-o="opacity" min="0.2" max="1" step="0.05" value="${S.opacity}"></label><label class="slider">Loop speed <input type="range" data-o="speed" min="150" max="1000" step="50" value="${1150 - S.speed}"></label>`,
  satOpts: () => `<div class="seg" data-o="sat">${[['ir', 'Infrared'], ['vis', 'Visible'], ['wv', 'Water vapor'], ['geocolor', 'True color']].map(([v, t]) => `<button data-v="${v}" class="${S.sat === v ? 'on' : ''}">${t}</button>`).join('')}</div><small class="muted">True color runs about 90 minutes behind real time.</small>`,
  hailOpts: () => `<div class="seg" data-o="hail">${[['24', '24 hours'], ['72', '3 days'], ['168', '7 days']].map(([v, t]) => `<button data-v="${v}" class="${S.hail === v ? 'on' : ''}">${t}</button>`).join('')}</div><small class="muted">Hail reports sized by stone size, plus today's SPC hail risk area.</small>`,
  rainOpts: () => `<div class="seg" data-o="rain">${[['1h', 'Past hour'], ['24h', '24 hours'], ['72h', '72 hours']].map(([v, t]) => `<button data-v="${v}" class="${S.rain === v ? 'on' : ''}">${t}</button>`).join('')}</div>`,
};
function openLayersSheet() {
  const row = ([id, name, opts]) => `<div class="lrow" data-id="${id}">
    <button class="lrow-main" ${opts ? `data-exp="${id}"` : ''}><span>${name} ${badge(tierOf(id))}</span>${opts ? '<i class="chev">›</i>' : ''}</button>
    <label class="tg${canLayer(id) ? '' : ' locked'}"><input type="checkbox" data-layer="${id}" ${S.layers[id] && canLayer(id) ? 'checked' : ''}><span></span></label>
    ${opts ? `<div class="lrow-opts" hidden>${OPTS[opts]()}</div>` : ''}</div>`;
  openSheet('Layers', LAYER_GROUPS.map(([g, rows]) => `<div class="lgroup"><div class="sheet-sub">${g}</div>${rows.map(row).join('')}</div>`).join('') +
    '<p class="muted small sheet-foot">Tap anywhere on the map for that spot\'s forecast, or to save it as a place.</p>', (b) => {
    $$('[data-layer]', b).forEach((cb) => cb.onchange = () => {
      const id = cb.dataset.layer;
      if (cb.checked && !canLayer(id)) { cb.checked = false; gate(id, layerName(id)); return; }
      if (cb.checked && id === 'traffic' && !KEYS.tomtom) { cb.checked = false; toast('Traffic needs a TomTom key in config.js'); return; }
      toggleLayer(id, cb.checked);
    });
    $$('[data-exp]', b).forEach((btn) => btn.onclick = () => { const o = btn.closest('.lrow').querySelector('.lrow-opts'); o.hidden = !o.hidden; btn.classList.toggle('open', !o.hidden); });
    $$('[data-o="opacity"]', b).forEach((i) => i.oninput = () => { S.opacity = +i.value; showFrame(R.idx); save(); });
    $$('[data-o="speed"]', b).forEach((i) => i.oninput = () => { S.speed = 1150 - +i.value; save(); if (R.playing) play(); });
    $$('.seg[data-o]', b).forEach((sg) => $$('button', sg).forEach((btn) => btn.onclick = () => {
      $$('button', sg).forEach((x) => x.classList.toggle('on', x === btn));
      const key = sg.dataset.o; S[key] = btn.dataset.v; save();
      const lid = key === 'sat' ? 'sat' : key === 'hail' ? 'hail' : 'rain';
      if (!canLayer(lid)) { gate(lid, layerName(lid)); return; }
      S.layers[lid] = true; $(`[data-layer="${lid}"]`, b).checked = true; refresh(lid); updateDock();
    }));
  });
}

// Units changed: redraw layers that print numbers
export function refreshUnits() { for (const id of ['temps']) if (active[id]) refresh(id); }
