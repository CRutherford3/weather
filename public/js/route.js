// Pro: route weather planner. Drive mode shows the forecast at the time you reach each part of the route.
// EV mode also plans DC fast charging stops and shows the weather at each charger.
import { getData, store, $, $$, esc, openSheet, closeSheet, toast, fmtT, fmtW, icon, wx, debounce } from './util.js';
import { geocode, reverseGeocode, feeds } from './api.js';
import { KEYS } from './config.js';
import { can, gate, badge } from './plan.js';
import * as Map from './map.js';

const KM_MI = 1.609344;
const st = {
  from: null, to: null, mode: store.get('routeMode', 'drive'), depart: 0, // hours from now
  ev: store.get('ev', { range: 250, charge: 90, reserve: 10, plug: 'J1772COMBO', kw: 150, nets: [] }),
  result: null, busy: false,
};
// Networks from the user's charging apps. Matched against the DOE station network name.
const NETS = [['evgo', 'EVgo', /evgo/i], ['chargepoint', 'ChargePoint', /chargepoint/i], ['blink', 'Blink', /blink/i], ['evconnect', 'EV Connect', /ev ?connect/i],
  ['fpl', 'FPL EVolution', /fpl/i], ['rede', 'RED E', /red ?e\b|rede/i], ['eos', 'EOS', /\beos\b/i], ['ea', 'Electrify America', /electrify ?america/i], ['tesla', 'Tesla', /tesla/i]];
const PLUGS = [['J1772COMBO', 'CCS'], ['TESLA', 'NACS / Tesla'], ['CHADEMO', 'CHAdeMO']];

export function initRoute(getLoc) {
  st.getLoc = getLoc;
  $('#toolRoute').onclick = openRoute;
  $('#routeChip').onclick = (e) => { if (e.target.closest('[data-clear]')) { clearRoute(); return; } openRoute(); };
}
export function clearRoute() { st.result = null; Map.clearRoute(); $('#routeChip').hidden = true; }

export function openRoute() {
  if (!can('route')) { gate('route', 'Route weather'); return; }
  if (!st.from) { const l = st.getLoc(); if (l) st.from = { ...l }; }
  const ev = st.ev;
  openSheet("Route weather", `
    <div class="seg big" id="rtMode"><button data-v="drive" class="${st.mode === 'drive' ? 'on' : ''}">Drive</button><button data-v="ev" class="${st.mode === 'ev' ? 'on' : ''}">EV charging</button></div>
    <div class="rt-form">
      <label class="rt-f"><span>From</span><input id="rtFrom" autocomplete="off" value="${esc(st.from?.name || '')}" placeholder="Starting point"><div class="rt-res" id="rtFromRes" hidden></div></label>
      <button class="rt-swap" id="rtSwap" title="Swap" aria-label="Swap start and destination">⇅</button>
      <label class="rt-f"><span>To</span><input id="rtTo" autocomplete="off" value="${esc(st.to?.name || '')}" placeholder="Destination"><div class="rt-res" id="rtToRes" hidden></div></label>
      <label class="rt-f"><span>Leave</span><select id="rtDep">${departOpts()}</select></label>
      <div class="rt-ev" id="rtEv" ${st.mode === 'ev' ? '' : 'hidden'}>
        <label><span>Full range (mi)</span><input type="number" id="evRange" min="60" max="600" value="${ev.range}"></label>
        <label><span>Charge now %</span><input type="number" id="evCharge" min="5" max="100" value="${ev.charge}"></label>
        <label><span>Arrive with %</span><input type="number" id="evReserve" min="5" max="50" value="${ev.reserve}"></label>
        <label><span>Plug</span><select id="evPlug">${PLUGS.map(([v, t]) => `<option value="${v}" ${ev.plug === v ? 'selected' : ''}>${t}</option>`).join('')}</select></label>
        <div class="rt-nets"><span>Networks <small>(none picked = all)</small></span><div class="chips" id="evNets">${NETS.map(([k, t]) => `<button data-net="${k}" class="${(ev.nets || []).includes(k) ? 'on' : ''}">${t}</button>`).join('')}</div></div>
      </div>
      <button class="btn wide" id="rtGo">${st.busy ? 'Planning…' : 'Plan route'}</button>
    </div>
    <div id="rtOut">${st.result ? resultHTML(st.result) : '<p class="muted small">Pick a destination. Weather is the forecast for the hour you reach each point, and warnings show where your route crosses them.</p>'}</div>`, (b) => {
    $$('#rtMode button', b).forEach((x) => x.onclick = () => { st.mode = x.dataset.v; store.set('routeMode', st.mode); $$('#rtMode button', b).forEach((y) => y.classList.toggle('on', y === x)); $('#rtEv', b).hidden = st.mode !== 'ev'; });
    wireSearch(b, 'rtFrom', 'from'); wireSearch(b, 'rtTo', 'to');
    $('#rtSwap', b).onclick = () => { [st.from, st.to] = [st.to, st.from]; $('#rtFrom', b).value = st.from?.name || ''; $('#rtTo', b).value = st.to?.name || ''; };
    $$('#evNets [data-net]', b).forEach((x) => x.onclick = () => x.classList.toggle('on'));
    $('#rtDep', b).value = String(st.depart);
    $('#rtDep', b).onchange = (e) => { st.depart = +e.target.value; };
    $('#rtGo', b).onclick = () => {
      Object.assign(st.ev, { range: +$('#evRange', b).value || 250, charge: +$('#evCharge', b).value || 90, reserve: +$('#evReserve', b).value || 10, plug: $('#evPlug', b).value, nets: $$('#evNets .on', b).map((x) => x.dataset.net) });
      store.set('ev', st.ev); plan();
    };
    wireResult(b);
  });
}

function departOpts() {
  const now = new Date(), out = [[0, 'Now']];
  for (const h of [1, 2, 3, 4, 6, 8, 12]) out.push([h, `In ${h} hour${h > 1 ? 's' : ''} (${timeStr(+now + h * 36e5)})`]);
  for (let d = 1; d <= 5; d++) for (const hr of [6, 9, 12]) {
    const t = new Date(now); t.setDate(t.getDate() + d); t.setHours(hr, 0, 0, 0);
    out.push([((t - now) / 36e5).toFixed(2), `${t.toLocaleDateString([], { weekday: 'short' })} ${timeStr(+t)}`]);
  }
  return out.map(([v, t]) => `<option value="${v}">${esc(t)}</option>`).join('');
}
const timeStr = (ms) => new Date(ms).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
const dayTime = (ms) => { const d = new Date(ms), today = new Date().toDateString() === d.toDateString(); return today ? timeStr(ms) : `${d.toLocaleDateString([], { weekday: 'short' })} ${timeStr(ms)}`; };

function wireSearch(b, inputId, key) {
  const inp = $(`#${inputId}`, b), box = $(`#${inputId}Res`, b);
  const show = (items) => {
    box.innerHTML = items.map((r, i) => `<button data-i="${i}">${esc(r.name)}</button>`).join(''); box.hidden = !items.length;
    $$('button', box).forEach((x) => x.onmousedown = (e) => { e.preventDefault(); st[key] = items[+x.dataset.i]; inp.value = st[key].name; box.hidden = true; });
  };
  inp.addEventListener('input', debounce(async () => {
    const q = inp.value.trim(); if (q.length < 2) return show([]);
    const here = st.getLoc();
    try { show([...(key === 'from' && here ? [{ ...here, name: `📍 ${here.name}` }] : []), ...(await geocode(q))]); } catch { show([]); }
  }, 250));
  inp.addEventListener('blur', () => setTimeout(() => { box.hidden = true; }, 150));
}

// ---------- planning ----------
async function plan() {
  if (!st.from || !st.to) return toast('Pick a start and a destination from the list');
  if (st.busy) return;
  st.busy = true; const out = $('#rtOut'); const btn = $('#rtGo');
  if (btn) btn.textContent = 'Planning…';
  if (out) out.innerHTML = '<div class="empty">Finding the route and forecast along it…</div>';
  try {
    const r = await getRoute(st.from, st.to);
    const t0 = Date.now() + st.depart * 36e5;
    let samples, stops = [];
    if (st.mode === 'ev') ({ samples, stops } = await planEV(r, t0));
    else samples = sampleRoute(r, t0, 0);
    await addWeather(samples, t0);
    await addAlerts(samples);
    const res = { from: st.from, to: st.to, mode: st.mode, t0, r, samples, stops, best: bestDepartures(samples, t0) };
    st.result = res;
    draw(res);
    if ($('#rtOut')) { $('#rtOut').innerHTML = resultHTML(res); wireResult($('#sheetBody')); }
    nameStops(res);
  } catch (e) {
    console.error(e);
    if ($('#rtOut')) $('#rtOut').innerHTML = `<div class="empty">${esc(e.message || 'Could not plan that route right now.')}</div>`;
  } finally { st.busy = false; if ($('#rtGo')) $('#rtGo').textContent = 'Plan route'; }
}

// Road route with time along each segment (OSRM). Coordinates are [lon, lat].
async function getRoute(a, b) {
  const url = `https://router.project-osrm.org/route/v1/driving/${a.lon},${a.lat};${b.lon},${b.lat}?overview=full&geometries=geojson&annotations=duration,distance`;
  const j = await getData(url, { timeout: 25000 });
  const rt = j.routes?.[0]; if (!rt) throw new Error('No driving route found between those places.');
  const coords = rt.geometry.coordinates, ann = rt.legs[0].annotation;
  const cumT = [0], cumD = [0];
  for (let i = 0; i < ann.duration.length; i++) { cumT.push(cumT[i] + ann.duration[i]); cumD.push(cumD[i] + ann.distance[i]); }
  return { coords, cumT, cumD, dist: rt.distance, dur: rt.duration };
}
// position at a given distance (meters) along the route
function atDist(r, d) {
  let i = r.cumD.findIndex((x) => x >= d); if (i <= 0) i = i === 0 ? 0 : r.cumD.length - 1;
  if (i === 0) return { lon: r.coords[0][0], lat: r.coords[0][1], t: 0, d: 0 };
  const f = (d - r.cumD[i - 1]) / Math.max(1, r.cumD[i] - r.cumD[i - 1]);
  const [x0, y0] = r.coords[i - 1], [x1, y1] = r.coords[i];
  return { lon: x0 + (x1 - x0) * f, lat: y0 + (y1 - y0) * f, t: r.cumT[i - 1] + (r.cumT[i] - r.cumT[i - 1]) * f, d };
}
// Evenly spaced forecast points (about every 30 min of driving, at most 30). extraDelay(sec at distance) adds charging stops.
function sampleRoute(r, t0, delayFn = 0) {
  const n = Math.min(30, Math.max(4, Math.round(r.dur / 1800)));
  const out = [];
  for (let k = 0; k <= n; k++) {
    const p = atDist(r, r.dist * k / n);
    const delay = typeof delayFn === 'function' ? delayFn(p.d) : 0;
    out.push({ ...p, eta: t0 + (p.t + delay) * 1000, kind: k === 0 ? 'start' : k === n ? 'end' : 'pt' });
  }
  return out;
}

// ---------- EV ----------
async function planEV(r, t0) {
  const ev = st.ev;
  // simplify the line for the request (about 120 points)
  const step = Math.max(1, Math.floor(r.coords.length / 120));
  const pts = r.coords.filter((_, i) => i % step === 0 || i === r.coords.length - 1).map(([x, y]) => `${x.toFixed(4)} ${y.toFixed(4)}`);
  const url = `https://developer.nlr.gov/api/alt-fuel-stations/v1/nearby-route.json?api_key=${KEYS.nrel}&fuel_type=ELEC&ev_charging_level=dc_fast&status=E&access=public&ev_connector_type=${ev.plug}&distance=3&limit=all&route=${encodeURIComponent(`LINESTRING(${pts.join(',')})`)}`;
  let list = [];
  try { list = (await getData(url, { timeout: 30000 })).fuel_stations || []; }
  catch (e) { throw new Error('Charger lookup is unavailable right now (the free charger key may be over its hourly limit).'); }
  // only the networks the driver uses
  const nets = NETS.filter(([k]) => (ev.nets || []).includes(k));
  if (nets.length) list = list.filter((x) => nets.some(([, , re]) => re.test(x.ev_network || '')));
  // place each charger along the route
  const cand = list.map((s) => {
    let best = 0, bd = Infinity;
    for (let i = 0; i < r.coords.length; i += 2) { const dx = (r.coords[i][0] - s.longitude) * Math.cos(s.latitude * Math.PI / 180), dy = r.coords[i][1] - s.latitude, dd = dx * dx + dy * dy; if (dd < bd) { bd = dd; best = i; } }
    return { s, d: r.cumD[best], t: r.cumT[best] };
  }).sort((a, b) => a.d - b.d);

  const rangeMi = ev.range;
  const usableMi = (pct) => rangeMi * pct / 100;
  let posD = 0, soc = ev.charge, stops = [], delay = 0;
  const destMi = r.dist / 1609.344;
  const CHARGE_TO = 80, CHARGE_MIN = 30; // charge to 80%, about 30 minutes per stop at a fast charger
  for (let guard = 0; guard < 20; guard++) {
    const reachMi = usableMi(soc - ev.reserve);
    if ((r.dist - posD) / 1609.344 <= reachMi) break; // can make it
    const limitD = posD + reachMi * 1609.344;
    const ok = cand.filter((c) => c.d > posD + 16000 && c.d <= limitD);
    if (!ok.length) { stops.push({ gap: true, d: posD }); break; }
    // prefer the farthest charger in the last third of range, with more fast ports
    const far = ok[ok.length - 1].d;
    const pool = ok.filter((c) => c.d >= far - reachMi * 1609.344 * 0.25);
    const pick = pool.sort((a, b) => (b.s.ev_dc_fast_num || 0) - (a.s.ev_dc_fast_num || 0) || b.d - a.d)[0];
    const arriveSoc = soc - ((pick.d - posD) / 1609.344) / rangeMi * 100;
    stops.push({ ...pick, arriveSoc, delay });
    delay += CHARGE_MIN * 60;
    soc = CHARGE_TO; posD = pick.d;
  }
  const delayAt = (d) => stops.filter((x) => !x.gap && x.d < d).length * CHARGE_MIN * 60;
  const samples = sampleRoute(r, t0, delayAt);
  // chargers become forecast points too
  stops.filter((x) => !x.gap).forEach((x, i) => samples.push({ lon: x.s.longitude, lat: x.s.latitude, d: x.d, t: x.t, eta: t0 + (x.t + x.delay) * 1000, kind: 'charger', n: i + 1, station: x.s, arriveSoc: x.arriveSoc }));
  samples.sort((a, b) => a.d - b.d || (a.kind === 'charger' ? 1 : -1));
  const end = samples.find((x) => x.kind === 'end');
  const lastSoc = stops.length && !stops.at(-1).gap ? CHARGE_TO - ((r.dist - posD) / 1609.344) / rangeMi * 100 : ev.charge - destMi / rangeMi * 100;
  if (end) end.arriveSoc = lastSoc;
  return { samples, stops };
}

// ---------- weather along the route ----------
async function addWeather(samples, t0) {
  const lat = samples.map((s) => s.lat.toFixed(3)).join(','), lon = samples.map((s) => s.lon.toFixed(3)).join(',');
  const url = `https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}&hourly=temperature_2m,precipitation_probability,precipitation,snowfall,weather_code,wind_gusts_10m,visibility,is_day&forecast_days=8&timeformat=unixtime&timezone=GMT`;
  let j = await getData(url, { timeout: 25000 }); if (!Array.isArray(j)) j = [j];
  samples.forEach((s, i) => {
    const h = j[i]?.hourly; if (!h) return;
    s.hourly = h;
    s.w = pick(h, s.eta);
  });
}
function pick(h, ms) {
  const sec = ms / 1000; let k = h.time.findIndex((t) => t > sec - 1800); if (k < 0) k = h.time.length - 1;
  const w = { temp: h.temperature_2m[k], pop: h.precipitation_probability[k], pr: h.precipitation[k], sn: h.snowfall[k], code: h.weather_code[k], gust: h.wind_gusts_10m[k], vis: h.visibility[k], day: h.is_day[k] };
  w.sev = severity(w); w.icon = wx(w.code, w.day).icon; w.text = wx(w.code, w.day).text;
  return w;
}
// 0 good, 1 watch, 2 caution, 3 danger
function severity(w) {
  if ([95, 96, 99, 56, 57, 66, 67].includes(w.code) || w.sn >= 1 || w.gust >= 75 || (w.vis != null && w.vis < 800)) return 3;
  if (w.sn > 0 || (w.pop >= 60 && w.pr >= 1) || w.gust >= 55 || (w.vis != null && w.vis < 3000) || (w.temp <= 0 && w.pr > 0)) return 2;
  if (w.pop >= 30 || w.pr > 0.1 || w.gust >= 40) return 1;
  return 0;
}
const SEV = [['#22c55e', 'Good'], ['#eab308', 'Some rain'], ['#f97316', 'Caution'], ['#ef4444', 'Hazardous']];

// Leaving at a different time: score each start hour over the next 12 hours
function bestDepartures(samples, t0) {
  if (!samples[0]?.hourly) return [];
  const out = [];
  for (let h = 0; h <= 12; h++) {
    let score = 0, worst = 0;
    for (const s of samples) { if (!s.hourly) continue; const w = pick(s.hourly, s.eta + h * 36e5); score += w.sev ** 2; worst = Math.max(worst, w.sev); }
    out.push({ h, t: t0 + h * 36e5, score, worst });
  }
  return out;
}

async function addAlerts(samples) {
  try {
    const j = await feeds.alerts();
    const polys = j.features.filter((f) => f.geometry && /Warning|Advisory|Watch|Emergency/.test(f.properties.event));
    for (const s of samples) {
      s.alerts = [...new Set(polys.filter((f) => inGeom([s.lon, s.lat], f.geometry) && (!f.properties.ends || new Date(f.properties.ends) > s.eta)).map((f) => f.properties.event))];
    }
  } catch { /* alerts optional */ }
}
function inRing(p, ring) { let c = false; for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) { const [xi, yi] = ring[i], [xj, yj] = ring[j]; if ((yi > p[1]) !== (yj > p[1]) && p[0] < (xj - xi) * (p[1] - yi) / (yj - yi) + xi) c = !c; } return c; }
function inGeom(p, g) { const polys = g.type === 'Polygon' ? [g.coordinates] : g.type === 'MultiPolygon' ? g.coordinates : []; return polys.some((pl) => inRing(p, pl[0])); }

// ---------- output ----------
function draw(res) {
  const s = res.samples;
  const segs = [];
  for (let i = 0; i < s.length - 1; i++) {
    const a = s[i], b = s[i + 1];
    const ia = res.r.cumD.findIndex((x) => x >= a.d), ib = res.r.cumD.findIndex((x) => x >= b.d);
    const coords = [[a.lon, a.lat], ...res.r.coords.slice(Math.max(0, ia), Math.max(ia + 1, ib)), [b.lon, b.lat]];
    segs.push({ type: 'Feature', geometry: { type: 'LineString', coordinates: coords }, properties: { c: SEV[Math.max(a.w?.sev || 0, b.w?.sev || 0)][0] } });
  }
  Map.drawRoute({ type: 'FeatureCollection', features: segs }, s.filter((x) => x.w && (x.kind !== 'pt' || s.indexOf(x) % 2 === 0)).map((x) => ({
    lon: x.lon, lat: x.lat, kind: x.kind, html: `${x.kind === 'charger' ? '<i class="rp-ev">⚡</i>' : ''}${icon(x.w.icon, 24)}<b>${fmtT(x.w.temp)}</b>`, sev: x.w.sev,
    tip: `${x.kind === 'charger' ? esc(x.station.station_name) + '<br>' : ''}<b>${dayTime(x.eta)}</b> · ${esc(x.w.text)}, ${fmtT(x.w.temp)}<br>${x.w.pop ?? 0}% rain chance · gusts ${fmtW(x.w.gust)}${x.alerts?.length ? `<br><b style="color:#f87171">${esc(x.alerts.join(', '))}</b>` : ''}`,
  })), res.r.coords);
  const mi = Math.round(res.r.dist / 1609.344);
  $('#routeChip').hidden = false;
  $('#routeChip').innerHTML = `<span>${res.mode === 'ev' ? '⚡ ' : ''}${esc(short(res.from.name))} → ${esc(short(res.to.name))} · ${mi} mi</span><button data-clear aria-label="Clear route">✕</button>`;
}
const short = (n = '') => n.replace(/^📍\s*/, '').split(',')[0];

function resultHTML(res) {
  const s = res.samples, end = s.find((x) => x.kind === 'end');
  const mi = Math.round(res.r.dist / 1609.344);
  const worst = Math.max(...s.map((x) => x.w?.sev || 0));
  const alerts = [...new Set(s.flatMap((x) => x.alerts || []))];
  const gap = res.stops.find((x) => x.gap);
  const chargers = s.filter((x) => x.kind === 'charger');
  const sum = worst >= 3 ? 'Hazardous weather on this route' : worst === 2 ? 'Some rough weather on this route' : worst === 1 ? 'Mostly fine, some rain possible' : 'Clear sailing';
  const best = res.best.length ? (() => { const b = [...res.best].sort((a, c) => a.score - c.score || a.h - c.h)[0];
    return `<div class="rt-best"><div class="sheet-sub">Best time to leave (next 12 hours)</div><div class="rt-bars">${res.best.map((x) => `<button class="rt-bar${x.h === b.h ? ' on' : ''}" data-dep="${x.h}" title="${dayTime(x.t)}" style="background:${SEV[x.worst][0]};height:${12 + Math.min(40, x.score * 2)}px"></button>`).join('')}</div>
      <div class="rt-bars-l"><span>${timeStr(res.t0)}</span><span>${b.h === 0 ? 'Leaving now is best' : `Best: ${dayTime(b.t)}`}</span><span>+12h</span></div></div>`; })() : '';
  const row = (x) => {
    const w = x.w; if (!w) return '';
    const label = x.kind === 'start' ? 'Start' : x.kind === 'end' ? 'Arrive' : x.kind === 'charger' ? `Charge stop ${x.n}` : `Mile ${Math.round(x.d / 1609.344)}`;
    const place = x.kind === 'charger' ? x.station.station_name : x.name || '';
    return `<div class="rt-row k-${x.kind}" style="--sv:${SEV[w.sev][0]}"><div class="rt-time"><b>${dayTime(x.eta)}</b><small>${label}</small></div>
      <div class="rt-wx">${icon(w.icon, 34)}<b>${fmtT(w.temp)}</b></div>
      <div class="rt-info"><span class="rt-place" data-place="${s.indexOf(x)}">${esc(place)}</span><small>${esc(w.text)} · ${w.pop ?? 0}% · gusts ${fmtW(w.gust)}${w.sn > 0 ? ` · snow ${(w.sn / 2.54).toFixed(1)} in/hr` : ''}</small>
      ${x.kind === 'charger' ? `<small class="rt-ev">⚡ ${x.station.ev_dc_fast_num || '?'} fast ports · ${esc(x.station.ev_network || 'Network n/a')} · arrive ~${Math.max(0, Math.round(x.arriveSoc))}%${x.station.street_address ? ` · ${esc(x.station.street_address)}` : ''}</small>
        <span class="rt-links"><a href="${dirLink(x)}" target="_blank" rel="noopener">Directions ↗</a>${x.station.ev_network_web ? `<a href="${esc(x.station.ev_network_web)}" target="_blank" rel="noopener">${esc(x.station.ev_network || 'Network')} ↗</a>` : ''}</span>` : ''}
      ${x.kind === 'end' && x.arriveSoc != null && res.mode === 'ev' ? `<small class="rt-ev">Arrive with ~${Math.max(0, Math.round(x.arriveSoc))}% battery</small>` : ''}
      ${x.alerts?.length ? `<small class="rt-alert">⚠ ${esc(x.alerts.join(', '))}</small>` : ''}</div></div>`;
  };
  return `<div class="rt-sum" style="--sv:${SEV[worst][0]}"><b>${sum}</b><span>${mi} mi · ${fmtDur(res.r.dur + (chargers.length * 1800))}${chargers.length ? ` incl. ${chargers.length} charge stop${chargers.length > 1 ? 's' : ''}` : ''} · arrive ${dayTime(end.eta)}</span>
      ${alerts.length ? `<em>⚠ Crosses: ${esc(alerts.join(', '))}</em>` : ''}</div>
    ${gap ? '<div class="rt-warn">No fast charger found within range for part of this route. Try allowing more networks, a higher starting charge, or check the leg after the last stop.</div>' : ''}
    ${res.mode === 'ev' ? '<p class="muted small">Charging stops assume a fast charger, about 30 minutes, charging to 80%. Cold weather can cut range 20 to 30%; plan extra margin below freezing.</p>' : ''}
    ${best}
    <div class="rt-list">${s.filter((x) => x.kind !== 'pt' || res.mode === 'drive' || true).map(row).join('')}</div>
    <p class="muted small sheet-foot">Route by OSRM (OpenStreetMap). Weather from Open-Meteo models and NWS alerts.${res.mode === 'ev' ? ' Chargers from the U.S. DOE Alternative Fuels Data Center.' : ''}</p>`;
}
const dirLink = (x) => (/iPhone|iPad|Macintosh/.test(navigator.userAgent) ? `https://maps.apple.com/?daddr=${x.lat},${x.lon}` : `https://www.google.com/maps/dir/?api=1&destination=${x.lat},${x.lon}`);
const fmtDur = (sec) => { const h = Math.floor(sec / 3600), m = Math.round((sec % 3600) / 60); return h ? `${h} hr ${m} min` : `${m} min`; };

function wireResult(b) {
  $$('[data-dep]', b).forEach((x) => x.onclick = () => { st.depart = Math.round(st.depart + +x.dataset.dep); const sel = $('#rtDep', b); if (sel && ![...sel.options].some((o) => +o.value === st.depart)) sel.add(new Option(`In ${st.depart} hours`, st.depart)); if (sel) sel.value = String(st.depart); plan(); });
}

// Town names for the timeline (filled in as they arrive)
async function nameStops(res) {
  const todo = res.samples.filter((x) => x.kind !== 'charger');
  for (let i = 0; i < todo.length; i += 6) {
    await Promise.all(todo.slice(i, i + 6).map(async (x) => {
      try { x.name = x.kind === 'start' ? res.from.name.replace(/^📍\s*/, '') : x.kind === 'end' ? res.to.name : await reverseGeocode(x.lat, x.lon); } catch { /* skip */ }
      const el = $(`[data-place="${res.samples.indexOf(x)}"]`); if (el && st.result === res) el.textContent = x.name || '';
    }));
  }
}
