// Radar / map view: animated radar, satellite, warnings, storm reports, SPC outlook, tropics, quakes, fires, temps.
import { TILES, alertColor, DBZ_LEGEND } from './config.js';
import { store, $, $$, esc, U, fmtT, fmtW, compass, debounce, toast, tempColor, wx, icon, localTime } from './util.js';
import { feeds, gridPoints, quickPoint } from './api.js';

const L = window.L;
export const S = {
  base: store.get('base', 'auto'),
  radarSrc: store.get('radarSrc', 'us'),
  opacity: store.get('opacity', 0.75),
  speed: store.get('speed', 450),
  sat: store.get('satType', 'ir'),
  layers: Object.assign({ radar: true, alerts: true, sat: false, temps: false, rain24: false, lsr: false, spc: false, tropics: true, quakes: false, fires: false }, store.get('layers', {})),
};
const save = () => { store.set('layers', S.layers); store.set('base', S.base); store.set('radarSrc', S.radarSrc); store.set('opacity', S.opacity); store.set('speed', S.speed); store.set('satType', S.sat); };

let map, baseLayer, labelLayer, homeMarker, onPick;
const R = { frames: [], idx: 0, playing: true, timer: null, hold: 0 };
const overlay = {};

export const LAYER_INFO = [
  { id: 'radar', name: 'Radar', desc: 'Animated precipitation (NEXRAD, updates every 5 min)' },
  { id: 'alerts', name: 'Warnings', desc: 'Live NWS warnings and watches with polygons' },
  { id: 'sat', name: 'Satellite', desc: 'GOES-East clouds: infrared, visible, water vapor or true color' },
  { id: 'temps', name: 'Temps & Wind', desc: 'Current temperature and wind across the map' },
  { id: 'rain24', name: 'Rain Totals (24 hr)', desc: 'Radar estimated rainfall, past 24 hours' },
  { id: 'spc', name: 'Severe Outlook', desc: 'SPC Day 1 thunderstorm risk areas' },
  { id: 'lsr', name: 'Storm Reports', desc: 'Tornado, hail, wind and flood reports, 24 hr' },
  { id: 'tropics', name: 'Hurricanes', desc: 'Active tropical systems (NHC)' },
  { id: 'quakes', name: 'Earthquakes', desc: 'Magnitude 2.5+ in the past day (USGS)' },
  { id: 'fires', name: 'Wildfires', desc: 'Active US wildfires over 100 acres' },
];

export function initMap(el, loc, themeFn, pickFn) {
  onPick = pickFn;
  map = L.map(el, { zoomControl: false, worldCopyJump: true, minZoom: 3, maxZoom: 17, preferCanvas: true }).setView([loc.lat, loc.lon], 8);
  L.control.zoom({ position: 'bottomright' }).addTo(map);
  L.control.scale({ position: 'bottomleft', imperial: true, metric: false }).addTo(map);
  for (const [n, z] of [['sat', 330], ['radar', 350], ['labels', 450], ['warn', 460]]) {
    const p = map.createPane(n); p.style.zIndex = z; if (n === 'labels') p.style.pointerEvents = 'none';
  }
  setBase(themeFn());
  setHome(loc);
  map.on('click', (e) => mapClick(e.latlng));
  map.on('moveend', debounce(() => { if (S.layers.temps) loadTemps(); }, 700));
  applyLayers();
  buildTimeline();
  setInterval(() => { if (S.layers.radar) loadRadar(); }, 5 * 60e3);
  setInterval(() => { if (S.layers.alerts) loadAlerts(); }, 2 * 60e3);
  return map;
}
export const getMap = () => map;

export function setBase(theme) {
  if (!map) return;
  const mode = S.base === 'auto' ? theme : S.base;
  baseLayer?.remove(); labelLayer?.remove();
  const url = mode === 'satellite' ? TILES.satellite : mode === 'roads' ? TILES.roads : mode === 'light' ? TILES.light : TILES.dark;
  baseLayer = L.tileLayer(url, { maxNativeZoom: TILES.maxNative, maxZoom: 19, attribution: 'Basemap &copy; Esri, HERE, Garmin, &copy; OpenStreetMap contributors' }).addTo(map);
  // Street map already has its own labels
  if (mode !== 'roads') labelLayer = L.tileLayer((mode === 'light') ? TILES.lightLabels : TILES.darkLabels, { maxNativeZoom: TILES.maxNative, maxZoom: 19, pane: 'labels' }).addTo(map);
  else labelLayer = null;
}

export function setHome(loc) {
  if (!map) return;
  homeMarker?.remove();
  homeMarker = L.marker([loc.lat, loc.lon], { icon: L.divIcon({ className: 'home-pin', html: '<span></span>', iconSize: [18, 18] }), interactive: false }).addTo(map);
}
export const flyTo = (loc, z = 8) => map?.flyTo([loc.lat, loc.lon], z, { duration: 0.8 });

export function applyLayers() {
  const L1 = S.layers;
  L1.radar ? loadRadar() : clearRadar();
  toggle('alerts', L1.alerts, loadAlerts);
  toggle('sat', L1.sat, loadSat);
  toggle('temps', L1.temps, loadTemps);
  toggle('rain24', L1.rain24, loadRain24);
  toggle('spc', L1.spc, loadSPC);
  toggle('lsr', L1.lsr, loadLSR);
  toggle('tropics', L1.tropics, loadTropics);
  toggle('quakes', L1.quakes, loadQuakes);
  toggle('fires', L1.fires, loadFires);
  $('#timeline')?.classList.toggle('hidden', !L1.radar);
  save();
}
function toggle(id, on, loader) {
  if (on) loader().catch((e) => { console.warn(id, e); toast(`${LAYER_INFO.find((l) => l.id === id)?.name} is unavailable right now`); });
  else if (overlay[id]) { overlay[id].remove(); delete overlay[id]; }
}
function setOverlay(id, layer) { overlay[id]?.remove(); overlay[id] = layer.addTo(map); }

// ---------- radar ----------
function clearRadar() { clearInterval(R.timer); R.frames.forEach((f) => f.layer.remove()); R.frames = []; }
async function loadRadar() {
  const keepIdx = R.frames.length && R.idx !== R.frames.length - 1 ? null : 'last';
  const frames = [];
  if (S.radarSrc === 'us') {
    // IEM NEXRAD mosaic: current plus 10 past frames at 5 minute steps
    let base = Math.floor(Date.now() / 300e3) * 300e3 - 300e3;
    try { const j = await feeds.iemTms(); const s = (j.services || []).find((x) => /n0q/i.test(x.id || x.layername || '') && x.utc_valid); if (s) base = new Date(s.utc_valid).getTime(); } catch { /* use estimate */ }
    const bust = Math.floor(Date.now() / 300e3);
    for (let m = 50; m >= 0; m -= 5) {
      const lname = m ? `nexrad-n0q-900913-m${String(m).padStart(2, '0')}m` : 'nexrad-n0q-900913';
      frames.push({ t: base - m * 60e3, url: `https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/${lname}/{z}/{x}/{y}.png?_=${bust}`, maxNative: 12, attr: 'NEXRAD via Iowa Environmental Mesonet' });
    }
  } else {
    const j = await feeds.rainviewer();
    for (const f of j.radar.past) frames.push({ t: f.time * 1000, url: `${j.host}${f.path}/256/{z}/{x}/{y}/2/1_1.png`, maxNative: 7, attr: 'RainViewer' });
  }
  clearRadar();
  R.frames = frames.map((f) => ({ ...f, layer: L.tileLayer(f.url, { pane: 'radar', opacity: 0, maxNativeZoom: f.maxNative, maxZoom: 17, attribution: f.attr, className: 'radar-tiles' }).addTo(map) }));
  $('#tlRange').max = R.frames.length - 1;
  showFrame(keepIdx === 'last' ? R.frames.length - 1 : Math.min(R.idx, R.frames.length - 1));
  if (R.playing) play();
}
function showFrame(i) {
  R.idx = i;
  R.frames.forEach((f, k) => f.layer.setOpacity(k === i ? S.opacity : 0));
  const f = R.frames[i]; if (!f) return;
  const ago = Math.round((Date.now() - f.t) / 60e3);
  $('#tlTime').textContent = localTime(f.t);
  $('#tlAgo').textContent = i === R.frames.length - 1 ? 'Latest' : `${ago} min ago`;
  $('#tlRange').value = i;
}
function play() {
  clearInterval(R.timer); R.playing = true; $('#tlPlay').innerHTML = pauseSvg;
  R.timer = setInterval(() => {
    if (!R.frames.length) return;
    if (R.idx === R.frames.length - 1 && R.hold < 3) { R.hold++; return; }
    R.hold = 0; showFrame((R.idx + 1) % R.frames.length);
  }, S.speed);
}
function pause() { clearInterval(R.timer); R.playing = false; $('#tlPlay').innerHTML = playSvg; }
const playSvg = '<svg width="18" height="18" viewBox="0 0 24 24"><path d="M7 5v14l12-7z" fill="currentColor"/></svg>';
const pauseSvg = '<svg width="18" height="18" viewBox="0 0 24 24"><path d="M7 5h4v14H7zM13 5h4v14h-4z" fill="currentColor"/></svg>';
function buildTimeline() {
  $('#tlPlay').innerHTML = pauseSvg;
  $('#tlPlay').onclick = () => (R.playing ? pause() : play());
  $('#tlRange').oninput = (e) => { pause(); showFrame(+e.target.value); };
  $('#tlPrev').onclick = () => { pause(); showFrame((R.idx - 1 + R.frames.length) % R.frames.length); };
  $('#tlNext').onclick = () => { pause(); showFrame((R.idx + 1) % R.frames.length); };
  $('#tlLegend').innerHTML = `<span>Light</span><i style="background:linear-gradient(90deg,${DBZ_LEGEND.join(',')})"></i><span>Severe</span>`;
}
export function setOpacity(v) { S.opacity = v; showFrame(R.idx); save(); }
export function setSpeed(v) { S.speed = v; save(); if (R.playing) play(); }
export function setRadarSrc(v) { S.radarSrc = v; save(); if (S.layers.radar) loadRadar(); }
export function setSat(v) { S.sat = v; save(); if (S.layers.sat) loadSat(); }
export function setBaseMode(v, theme) { S.base = v; save(); setBase(theme); }

// ---------- satellite (NASA GIBS, GOES-East) ----------
async function loadSat() {
  if (S.sat === 'geocolor') {
    // NASA GIBS true color runs about 60 to 90 minutes behind real time
    const t = new Date(Math.floor((Date.now() - 90 * 60e3) / 600e3) * 600e3).toISOString().replace('.000Z', 'Z');
    setOverlay('sat', L.tileLayer(`https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/GOES-East_ABI_GeoColor/default/${t}/GoogleMapsCompatible_Level7/{z}/{y}/{x}.jpg`, { pane: 'sat', opacity: 0.85, maxNativeZoom: 7, maxZoom: 17, attribution: 'NASA GIBS / NOAA GOES' }));
    return;
  }
  // Iowa Environmental Mesonet GOES-East CONUS channels (refresh every few minutes)
  const ch = { ir: 'ch13', vis: 'ch02', wv: 'ch09' }[S.sat] || 'ch13';
  setOverlay('sat', L.tileLayer(`https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/goes_east_conus_${ch}/{z}/{x}/{y}.png?_=${Math.floor(Date.now() / 300e3)}`, { pane: 'sat', opacity: 0.75, maxNativeZoom: 9, maxZoom: 17, attribution: 'NOAA GOES via Iowa Environmental Mesonet' }));
}

// ---------- 24 hr rainfall (MRMS via IEM) ----------
async function loadRain24() {
  setOverlay('rain24', L.tileLayer(`https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/q2-p24h-900913/{z}/{x}/{y}.png?_=${Math.floor(Date.now() / 600e3)}`, { pane: 'sat', opacity: 0.7, maxNativeZoom: 10, maxZoom: 17, attribution: 'MRMS via IEM' }));
}

// ---------- NWS warnings ----------
let lastAlerts = [];
export const getNationalAlerts = () => lastAlerts;
async function loadAlerts() {
  const j = await feeds.alerts();
  lastAlerts = j.features;
  const withGeo = j.features.filter((f) => f.geometry);
  // Draw watches/advisories first so warnings sit on top
  const rank = (e) => (/Warning|Emergency/.test(e) ? 2 : /Watch/.test(e) ? 1 : 0);
  withGeo.sort((a, b) => rank(a.properties.event) - rank(b.properties.event));
  setOverlay('alerts', L.geoJSON({ type: 'FeatureCollection', features: withGeo }, {
    pane: 'warn',
    style: (f) => { const c = alertColor(f.properties.event); const w = rank(f.properties.event); return { color: c, weight: w === 2 ? 2.5 : 1.5, fillColor: c, fillOpacity: w === 2 ? 0.22 : 0.1, dashArray: w === 1 ? '6 4' : null }; },
    onEachFeature: (f, l) => l.on('click', (e) => { L.DomEvent.stop(e); window.dispatchEvent(new CustomEvent('show-alert', { detail: f.properties })); }),
  }));
}

// ---------- SPC Day 1 outlook ----------
async function loadSPC() {
  const j = await feeds.spc(1);
  setOverlay('spc', L.geoJSON(j, {
    pane: 'sat',
    style: (f) => ({ color: f.properties.stroke || '#888', weight: 1.5, fillColor: f.properties.fill || '#888', fillOpacity: 0.35 }),
    onEachFeature: (f, l) => l.bindPopup(`<b>SPC Day 1: ${esc(f.properties.LABEL2 || f.properties.LABEL)}</b><br><a href="https://www.spc.noaa.gov/products/outlook/day1otlk.html" target="_blank" rel="noopener">Full outlook</a>`),
  }));
}

// ---------- Local storm reports ----------
async function loadLSR() {
  const j = await feeds.lsr();
  const col = (t = '') => (/TORNADO|FUNNEL/i.test(t) ? '#ef4444' : /HAIL/i.test(t) ? '#22c55e' : /WIND|TSTM/i.test(t) ? '#3b82f6' : /FLOOD|RAIN/i.test(t) ? '#06b6d4' : /SNOW|ICE|SLEET/i.test(t) ? '#e5e7eb' : '#a855f7');
  setOverlay('lsr', L.geoJSON(j, {
    pointToLayer: (f, ll) => L.circleMarker(ll, { radius: 6, color: '#000', weight: 1, fillColor: col(f.properties.typetext), fillOpacity: 0.95 }),
    onEachFeature: (f, l) => { const p = f.properties; l.bindPopup(`<b>${esc(p.typetext)}</b> ${p.magnitude ? esc(p.magnitude) + (p.unit ? ' ' + esc(p.unit) : '') : ''}<br>${esc(p.city)}, ${esc(p.st || p.state || '')}<br><small>${p.valid ? new Date(p.valid + (String(p.valid).endsWith('Z') ? '' : 'Z')).toLocaleString() : ''}</small><p>${esc(p.remark || '')}</p><small>Source: ${esc(p.source || 'NWS')}</small>`); },
  }));
}

// ---------- Tropics ----------
let lastStorms = [];
export const getStorms = () => lastStorms;
async function loadTropics() {
  const j = await feeds.storms();
  lastStorms = j.activeStorms || [];
  const g = L.layerGroup();
  for (const s of lastStorms) {
    const ll = [s.latitudeNumeric, s.longitudeNumeric];
    const mph = Math.round((s.intensity || 0) * 1.15078);
    g.addLayer(L.marker(ll, { icon: L.divIcon({ className: 'storm-pin', html: `<span>${s.classification === 'HU' ? '🌀' : '◉'}</span><b>${esc(s.name)}</b>`, iconSize: [120, 28], iconAnchor: [14, 14] }) })
      .bindPopup(`<b>${esc(s.classification === 'HU' ? 'Hurricane' : s.classification === 'TS' ? 'Tropical Storm' : s.classification === 'TD' ? 'Tropical Depression' : 'Tropical System')} ${esc(s.name)}</b><br>Winds ${mph} mph · ${esc(s.pressure)} mb<br>Moving ${esc(s.movementDir)}° at ${Math.round((s.movementSpeed || 0) * 1.15078)} mph<br><a href="https://www.nhc.noaa.gov/" target="_blank" rel="noopener">NHC advisories</a>`));
  }
  setOverlay('tropics', g);
  window.dispatchEvent(new CustomEvent('storms', { detail: lastStorms }));
}

// ---------- Quakes / Fires ----------
async function loadQuakes() {
  const j = await feeds.quakes();
  setOverlay('quakes', L.geoJSON(j, {
    pointToLayer: (f, ll) => L.circleMarker(ll, { radius: Math.max(4, f.properties.mag * 2.6), color: '#7c2d12', weight: 1, fillColor: '#fb923c', fillOpacity: 0.7 }),
    onEachFeature: (f, l) => l.bindPopup(`<b>M${f.properties.mag.toFixed(1)}</b> ${esc(f.properties.place)}<br><small>${new Date(f.properties.time).toLocaleString()}</small><br><a href="${esc(f.properties.url)}" target="_blank" rel="noopener">USGS details</a>`),
  }));
}
async function loadFires() {
  const j = await feeds.fires();
  setOverlay('fires', L.geoJSON(j, {
    pointToLayer: (f, ll) => L.marker(ll, { icon: L.divIcon({ className: 'fire-pin', html: '🔥', iconSize: [22, 22] }) }),
    onEachFeature: (f, l) => { const p = f.properties; l.bindPopup(`<b>${esc(p.IncidentName)} Fire</b><br>${p.IncidentSize ? Math.round(p.IncidentSize).toLocaleString() + ' acres' : ''}${p.PercentContained != null ? ` · ${p.PercentContained}% contained` : ''}`); },
  }));
}

// ---------- Temps & wind grid ----------
async function loadTemps() {
  const b = map.getBounds(), sz = map.getSize();
  if (!sz.x || !sz.y) return; // map not laid out yet (hidden tab); moveend will retry
  const cols = sz.x > 900 ? 9 : 6, rows = Math.max(4, Math.min(8, Math.round(cols * sz.y / sz.x) || 4));
  const lats = [], lons = [];
  for (let r = 0; r < rows; r++) for (let c = 0; c < cols; c++) {
    lats.push((b.getSouth() + (b.getNorth() - b.getSouth()) * (r + 0.5) / rows).toFixed(3));
    lons.push((b.getWest() + (b.getEast() - b.getWest()) * (c + 0.5) / cols).toFixed(3));
  }
  const pts = await gridPoints(lats, lons);
  const g = L.layerGroup();
  pts.forEach((p, i) => {
    const c = p.current; if (!c || lats[i] == null) return;
    g.addLayer(L.marker([lats[i], lons[i]], { interactive: false, icon: L.divIcon({ className: 'tbub', iconSize: [64, 30], html: `<div style="background:${tempColor(c.temperature_2m)}"><b>${Math.round(U.temp(c.temperature_2m))}°</b><i style="transform:rotate(${c.wind_direction_10m + 180}deg)">↑</i><small>${Math.round(U.wind(c.wind_speed_10m))}</small></div>` }) }));
  });
  if (S.layers.temps) setOverlay('temps', g);
}

// ---------- tap anywhere for a quick forecast ----------
async function mapClick(ll) {
  const pop = L.popup({ maxWidth: 260 }).setLatLng(ll).setContent('<div class="qp">Loading…</div>').openOn(map);
  try {
    const j = await quickPoint(ll.lat, ll.lng);
    const c = j.current, w = wx(c.weather_code, c.is_day);
    const id = 'pick' + Date.now();
    pop.setContent(`<div class="qp"><div class="qp-top">${icon(w.icon, 44)}<div><div class="qp-t">${fmtT(c.temperature_2m)}</div><div>${w.text}</div></div></div>
      <div class="qp-row">Feels ${fmtT(c.apparent_temperature)} · H ${fmtT(j.daily.temperature_2m_max[0])} L ${fmtT(j.daily.temperature_2m_min[0])}</div>
      <div class="qp-row">Wind ${compass(c.wind_direction_10m)} ${fmtW(c.wind_speed_10m)}, gusts ${fmtW(c.wind_gusts_10m)}</div>
      <div class="qp-row">Rain chance today ${j.daily.precipitation_probability_max[0] ?? '--'}%</div>
      <button class="btn small" id="${id}">Full forecast here</button></div>`);
    setTimeout(() => { const b = document.getElementById(id); if (b) b.onclick = () => { map.closePopup(); onPick?.({ lat: ll.lat, lon: ll.lng }); }; }, 0);
  } catch { pop.setContent('<div class="qp">Could not load this spot.</div>'); }
}

export function invalidate() { map?.invalidateSize(); }
