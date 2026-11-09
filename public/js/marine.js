// Pro: Marine & Offshore. Nearest NDBC buoy (live), wave and swell forecast (Open-Meteo Marine),
// NOAA tides (CO-OPS), and the NWS coastal / offshore marine forecast text.
import { getData, NWS_HEADERS, esc, units, fmtT, compass, dayName } from './util.js';

const imp = () => units.system === 'imperial';
const ft = (m) => (m == null || isNaN(m) ? '--' : imp() ? `${(m * 3.28084).toFixed(1)} ft` : `${(+m).toFixed(1)} m`);
const kn = (k) => (k == null || isNaN(k) ? '--' : `${Math.round(k)} kn`);
const miles = (a, b) => { const R = 3958.8, t = Math.PI / 180, x = (b.lon - a.lon) * t * Math.cos(((a.lat + b.lat) / 2) * t), y = (b.lat - a.lat) * t; return Math.sqrt(x * x + y * y) * R; };
const arrow = (deg) => (deg == null ? '' : `<i class="mar-arr" style="transform:rotate(${(+deg + 180) % 360}deg)">↑</i>`); // points where waves/wind go

// ---------- NDBC buoys (one file holds the latest report from every station) ----------
let buoyP, namesP;
export function buoys() {
  return (buoyP ||= getData('https://www.ndbc.noaa.gov/data/latest_obs/latest_obs.txt', { type: 'text', proxyFirst: true, cache: 600e3, timeout: 30000 }).then((txt) => {
    const out = [];
    for (const line of txt.split('\n')) {
      if (!line || line.startsWith('#')) continue;
      const c = line.trim().split(/\s+/); if (c.length < 19) continue;
      const n = (v) => (v === 'MM' ? null : +v);
      out.push({ id: c[0], lat: +c[1], lon: +c[2], t: Date.UTC(+c[3], +c[4] - 1, +c[5], +c[6], +c[7]), wdir: n(c[8]), wspd: n(c[9]), gst: n(c[10]), wvht: n(c[11]), dpd: n(c[12]), mwd: n(c[14]), pres: n(c[15]), atmp: n(c[17]), wtmp: n(c[18]) });
    }
    return out;
  }).catch((e) => { buoyP = null; throw e; }));
}
export function buoyNames() {
  return (namesP ||= getData('https://www.ndbc.noaa.gov/activestations.xml', { type: 'text', proxyFirst: true, cache: 86400e3, timeout: 30000 })
    .then((x) => { const m = {}; for (const s of x.matchAll(/<station id="([^"]+)"[^>]*name="([^"]*)"/g)) m[s[1].toUpperCase()] = s[2].replace(/&amp;/g, '&'); return m; })
    .catch(() => ({})));
}
// Nearest buoy that reports waves (falls back to any station)
function nearestBuoy(list, loc) {
  const fresh = list.filter((b) => Date.now() - b.t < 6 * 36e5);
  const pick = (arr) => arr.reduce((best, b) => { const d = miles(loc, b); return d < best.d ? { b, d } : best; }, { b: null, d: Infinity });
  const w = pick(fresh.filter((b) => b.wvht != null));
  return w.b && w.d < 250 ? w : pick(fresh);
}

// ---------- tides ----------
let tideP;
function tideStations() {
  return (tideP ||= getData('https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations.json?type=tidepredictions', { cache: 86400e3, timeout: 30000 })
    .then((j) => j.stations.map((s) => ({ id: s.id, name: s.name, state: s.state, lat: +s.lat, lon: +s.lng })))
    .catch((e) => { tideP = null; throw e; }));
}
const ymd = (d) => `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, '0')}${String(d.getDate()).padStart(2, '0')}`;
const TIDE = 'https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?datum=MLLW&units=english&time_zone=lst_ldt&format=json&application=updraft';

// ---------- everything for one location ----------
export async function loadMarine(loc) {
  const [list, names] = await Promise.all([buoys(), buoyNames()]);
  const { b, d } = nearestBuoy(list, loc);
  if (!b) throw new Error('No buoys reporting');
  const pt = { lat: b.lat, lon: b.lon };
  const [wave, wind, zone, tide, cams] = await Promise.allSettled([
    getData(`https://marine-api.open-meteo.com/v1/marine?latitude=${pt.lat}&longitude=${pt.lon}&timezone=auto&forecast_days=7&current=ocean_current_velocity,ocean_current_direction&hourly=wave_height,wave_direction,wave_period,swell_wave_height,swell_wave_direction,swell_wave_period,wind_wave_height,sea_surface_temperature&daily=wave_height_max,swell_wave_height_max,swell_wave_period_max,wave_direction_dominant`, { cache: 1800e3 }),
    getData(`https://api.open-meteo.com/v1/forecast?latitude=${pt.lat}&longitude=${pt.lon}&timezone=auto&forecast_days=7&wind_speed_unit=kn&current=wind_speed_10m,wind_direction_10m,wind_gusts_10m,pressure_msl&daily=wind_speed_10m_max,wind_gusts_10m_max,wind_direction_10m_dominant,weather_code`, { cache: 1800e3 }),
    marineZone(pt),
    loadTides(loc),
    getData('https://www.ndbc.noaa.gov/buoycams.php', { proxyFirst: true, cache: 600e3 }),
  ]);
  // Many nearshore buoys only measure waves; borrow wind and pressure from the closest station that has them
  const fresh = list.filter((x) => Date.now() - x.t < 3 * 36e5);
  const near = (key) => { const r = fresh.filter((x) => x[key] != null).map((x) => ({ x, d: miles(pt, x) })).sort((a, c) => a.d - c.d)[0]; return r && r.d < 75 ? { ...r.x, miles: r.d, name: names[r.x.id] || '' } : null; };
  const windStn = b.wspd == null ? near('wspd') : null, presStn = b.pres == null ? near('pres') : null;
  const cam = (cams.value || []).filter((c) => c.img).map((c) => ({ ...c, miles: miles(loc, { lat: c.lat, lon: c.lng }) })).sort((a, b) => a.miles - b.miles)[0];
  const alerts = await marineAlerts(loc, zone.value?.id);
  return { loc, buoy: { ...b, name: names[b.id] || '', miles: d }, wave: wave.value, wind: wind.value, zone: zone.value, tide: tide.value, cam: cam && cam.miles < 300 ? cam : null, alerts, windStn, presStn };
}
async function marineZone(pt) {
  for (const type of ['coastal', 'offshore']) {
    try {
      const z = (await getData(`https://api.weather.gov/zones?type=${type}&point=${pt.lat.toFixed(3)},${pt.lon.toFixed(3)}`, { headers: NWS_HEADERS, cache: 86400e3 })).features?.[0]?.properties;
      if (!z) continue;
      const f = await getData(`https://api.weather.gov/zones/${type}/${z.id}/forecast`, { headers: NWS_HEADERS, cache: 1800e3 });
      return { id: z.id, name: z.name, periods: f.properties?.periods || [] };
    } catch { /* try the next type */ }
  }
  return null;
}
// Marine and beach hazards: small craft advisories, gales, rip currents, high surf, fog, waterspouts
const MARINE_RX = /Marine|Craft|Gale|Storm Warning|Hurricane|Tropical|Rip|Surf|Beach|Coastal|Waterspout|Fog|Seas|Freezing Spray|Lakeshore/i;
async function marineAlerts(loc, zoneId) {
  const urls = [`https://api.weather.gov/alerts/active?point=${loc.lat.toFixed(3)},${loc.lon.toFixed(3)}`];
  if (zoneId) urls.push(`https://api.weather.gov/alerts/active?zone=${zoneId}`);
  const res = await Promise.allSettled(urls.map((u) => getData(u, { headers: NWS_HEADERS, cache: 300e3 })));
  const seen = new Set(), out = [];
  for (const r of res) for (const f of r.value?.features || []) { const p = f.properties; if (!MARINE_RX.test(p.event) || seen.has(p.event)) continue; seen.add(p.event); out.push({ event: p.event, headline: p.headline, ends: p.ends || p.expires }); }
  return out;
}

async function loadTides(loc) {
  const st = (await tideStations()).reduce((best, s) => { const d = miles(loc, s); return d < best.d ? { s, d } : best; }, { s: null, d: Infinity });
  if (!st.s || st.d > 120) return null;
  const today = ymd(new Date());
  const [hilo, curve] = await Promise.all([
    getData(`${TIDE}&product=predictions&interval=hilo&station=${st.s.id}&begin_date=${today}&range=72`, { cache: 3600e3 }),
    getData(`${TIDE}&product=predictions&interval=h&station=${st.s.id}&begin_date=${today}&range=48`, { cache: 3600e3 }),
  ]);
  return { station: st.s, miles: st.d, hilo: hilo.predictions || [], curve: curve.predictions || [] };
}

// ---------- rendering ----------
const parseLocal = (s) => new Date(s.replace(' ', 'T'));
const tm = (s) => parseLocal(s).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });

export function marineHTML(Mr) {
  if (!Mr) return '<div class="empty">Loading marine data…</div>';
  const b = Mr.buoy;
  const far = b.miles > 150 ? `<div class="mar-note">The nearest coast is about ${Math.round(b.miles)} miles away, so this shows the closest buoy.</div>` : '';
  const age = Math.round((Date.now() - b.t) / 60e3);
  const ago = (t) => { const m = Math.round((Date.now() - t) / 60e3); return m < 90 ? `${m} min ago` : `${Math.round(m / 60)} hr ago`; };
  const pr = (mb) => (imp() ? (mb * 0.02953).toFixed(2) + ' in' : Math.round(mb) + ' mb');
  const mc = Mr.wind?.current;
  // wind: this buoy, else nearest station that measures it, else the model
  const ws = b.wspd != null ? { v: b.wspd * 1.94384, d: b.wdir, g: b.gst != null ? b.gst * 1.94384 : null, src: '' } : Mr.windStn ? { v: Mr.windStn.wspd * 1.94384, d: Mr.windStn.wdir, g: Mr.windStn.gst != null ? Mr.windStn.gst * 1.94384 : null, src: `at ${Mr.windStn.id}, ${Math.round(Mr.windStn.miles)} mi` } : mc ? { v: mc.wind_speed_10m, d: mc.wind_direction_10m, g: mc.wind_gusts_10m, src: 'model estimate' } : null;
  const ps = b.pres != null ? { v: b.pres, src: ago(b.t) } : Mr.presStn ? { v: Mr.presStn.pres, src: `at ${Mr.presStn.id}` } : mc ? { v: mc.pressure_msl, src: 'model estimate' } : null;
  const cv = Mr.wave?.current;
  const now = `<div class="mar-now">
    <div class="mar-tile"><small>Waves</small><b>${ft(b.wvht)}</b><span>${b.dpd ? `${b.dpd}s period` : ''} ${b.mwd != null ? `from ${compass(b.mwd)}` : ''}</span></div>
    <div class="mar-tile"><small>Wind</small><b>${ws ? kn(ws.v) : '--'}</b><span>${ws ? `${ws.d != null ? compass(ws.d) : ''}${ws.g != null ? ` gusts ${kn(ws.g)}` : ''}${ws.src ? `<br>${ws.src}` : ''}` : ''}</span></div>
    <div class="mar-tile"><small>Water</small><b>${b.wtmp != null ? fmtT(b.wtmp) : '--'}</b><span>${b.atmp != null ? `air ${fmtT(b.atmp)}` : ago(b.t)}</span></div>
    <div class="mar-tile"><small>Pressure</small><b>${ps ? pr(ps.v) : '--'}</b><span>${ps ? ps.src : ''}</span></div>
    ${cv?.ocean_current_velocity != null ? `<div class="mar-tile"><small>Current</small><b>${(cv.ocean_current_velocity / 1.852).toFixed(1)} kn</b><span>toward ${compass(cv.ocean_current_direction)}</span></div>` : ''}</div>
    <div class="muted small">Buoy <a href="https://www.ndbc.noaa.gov/station_page.php?station=${esc(b.id)}" target="_blank" rel="noopener">${esc(b.id)}${b.name ? ` · ${esc(b.name)}` : ''}</a> · ${Math.round(b.miles)} mi away</div>`;

  // 7-day seas and wind
  let days = '';
  const w = Mr.wave?.daily, wn = Mr.wind?.daily;
  if (w) {
    days = `<div class="mar-days-wrap"><table class="mar-days"><tr><th></th><th>Seas</th><th>Swell</th><th>Wind</th><th>Water</th></tr>${w.time.map((t, i) => {
      const sst = Mr.wave.hourly?.sea_surface_temperature?.[i * 24 + 14];
      return `<tr><td>${i ? dayName(t) : 'Today'}</td><td><b>${ft(w.wave_height_max[i])}</b> ${arrow(w.wave_direction_dominant?.[i])}</td><td>${ft(w.swell_wave_height_max[i])} <small>${w.swell_wave_period_max[i] ? Math.round(w.swell_wave_period_max[i]) + 's' : ''}</small></td>
        <td>${wn ? `${wn.wind_direction_10m_dominant[i] != null ? compass(wn.wind_direction_10m_dominant[i]) : ''} ${kn(wn.wind_speed_10m_max[i])} <small>G${Math.round(wn.wind_gusts_10m_max[i])}</small>` : '--'}</td><td>${sst != null ? fmtT(sst) : '--'}</td></tr>`;
    }).join('')}</table></div>`;
  }
  // 72-hour wave height chart
  let chart = '';
  const h = Mr.wave?.hourly;
  if (h) {
    const n = Math.min(72, h.time.length), W = 600, H = 120;
    const vals = h.wave_height.slice(0, n), sw = h.swell_wave_height.slice(0, n);
    const max = Math.max(0.5, ...vals.filter((v) => v != null), ...sw.filter((v) => v != null));
    const X = (i) => 4 + i / (n - 1) * (W - 8), Y = (v) => H - 18 - (v / max) * (H - 30);
    const line = (a) => a.map((v, i) => (v == null ? '' : `${X(i).toFixed(1)},${Y(v).toFixed(1)}`)).filter(Boolean).join(' ');
    const ticks = h.time.slice(0, n).map((t, i) => (t.slice(11, 13) === '00' ? `<line x1="${X(i)}" x2="${X(i)}" y1="0" y2="${H - 16}" class="grid"/><text x="${X(i) + 3}" y="${H - 4}" class="axis">${dayName(t)}</text>` : '')).join('');
    chart = `<svg class="mar-chart" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none">${ticks}<polygon points="${X(0)},${H - 18} ${line(vals)} ${X(n - 1)},${H - 18}" fill="rgba(56,189,248,.25)"/><polyline points="${line(vals)}" fill="none" stroke="#38bdf8" stroke-width="2"/><polyline points="${line(sw)}" fill="none" stroke="#a78bfa" stroke-width="1.6" stroke-dasharray="4 3"/><text x="6" y="12" class="axis">${ft(max)}</text></svg>
      <div class="muted small"><span style="color:#38bdf8">━</span> Total seas &nbsp; <span style="color:#a78bfa">┅</span> Swell · next 72 hours</div>`;
  }
  // tides
  let tides = '<div class="empty">No NOAA tide station near this location.</div>';
  const T = Mr.tide;
  if (T) {
    const pts = T.curve.map((p) => ({ t: parseLocal(p.t).getTime(), v: +p.v }));
    let curve = '';
    if (pts.length > 2) {
      const W = 600, H = 90, t0 = pts[0].t, t1 = pts.at(-1).t, lo = Math.min(...pts.map((p) => p.v)), hi = Math.max(...pts.map((p) => p.v));
      const X = (t) => 4 + (t - t0) / (t1 - t0) * (W - 8), Y = (v) => H - 8 - (v - lo) / Math.max(0.1, hi - lo) * (H - 16);
      const nowX = X(Date.now());
      curve = `<svg class="mar-chart tide" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none"><polyline points="${pts.map((p) => `${X(p.t).toFixed(1)},${Y(p.v).toFixed(1)}`).join(' ')}" fill="none" stroke="#22d3ee" stroke-width="2"/>${nowX > 0 && nowX < W ? `<line x1="${nowX}" x2="${nowX}" y1="0" y2="${H}" stroke="#f472b6" stroke-width="1.5" stroke-dasharray="3 3"/>` : ''}</svg>`;
    }
    const next = T.hilo.filter((p) => parseLocal(p.t).getTime() > Date.now() - 36e5).slice(0, 8);
    tides = `${curve}<div class="mar-tides">${next.map((p) => `<div class="${p.type === 'H' ? 'hi' : 'lo'}"><b>${p.type === 'H' ? 'High' : 'Low'}</b><span>${dayName(p.t.replace(' ', 'T'))} ${tm(p.t)}</span><small>${(+p.v).toFixed(1)} ft</small></div>`).join('')}</div>
      <div class="muted small">NOAA tide station <a href="https://tidesandcurrents.noaa.gov/noaatidepredictions.html?id=${esc(T.station.id)}" target="_blank" rel="noopener">${esc(T.station.name)}${T.station.state ? ', ' + esc(T.station.state) : ''}</a> · ${Math.round(T.miles)} mi · pink line is now</div>`;
  }
  // NWS marine forecast
  const Z = Mr.zone;
  const zone = Z?.periods?.length ? `<div class="mar-zone"><div class="muted small">${esc(Z.name)} (${esc(Z.id)})</div>${Z.periods.slice(0, 6).map((p) => `<p><b>${esc(p.name)}:</b> ${esc(p.detailedForecast)}</p>`).join('')}</div>` : '<div class="empty">No NWS marine forecast zone near this buoy.</div>';

  // rough small-boat outlook for today from forecast seas and wind
  let outlook = '';
  if (w && wn) {
    const sf = w.wave_height_max[0] * 3.28084, wk = wn.wind_speed_10m_max[0];
    const [cls, txt] = sf < 3 && wk < 12 ? ['good', 'Good boating conditions today'] : sf < 5 && wk < 18 ? ['fair', 'Fair, a bit choppy for small boats'] : sf < 8 && wk < 25 ? ['rough', 'Rough, small craft should use caution'] : ['bad', 'Hazardous for small boats'];
    outlook = `<div class="mar-outlook ${cls}"><b>${txt}</b><span>Seas up to ${ft(w.wave_height_max[0])}, wind up to ${kn(wk)}. A rough guide only; check the NWS forecast below.</span></div>`;
  }
  const al = Mr.alerts?.length ? `<div class="mar-alerts">${Mr.alerts.map((a) => `<div><b>⚠ ${esc(a.event)}</b>${a.ends ? `<span>until ${new Date(a.ends).toLocaleString([], { weekday: 'short', hour: 'numeric', minute: '2-digit' })}</span>` : ''}</div>`).join('')}</div>` : '';
  const cam = Mr.cam ? `<div class="mar-cam"><h4>Live buoy camera</h4><div class="cam-strip"><img loading="lazy" src="https://www.ndbc.noaa.gov/images/buoycam/${esc(Mr.cam.img)}" alt="Buoy ${esc(Mr.cam.id)} camera"></div>
    <div class="muted small">${esc(Mr.cam.name)} · ${Math.round(Mr.cam.miles)} mi · six views around the buoy, scroll sideways · <a href="https://www.ndbc.noaa.gov/buoycam.php?station=${esc(Mr.cam.id)}" target="_blank" rel="noopener">NDBC ↗</a></div></div>` : '';
  const links = `<div class="chips links mar-links">${[['Nautical charts', 'https://nauticalcharts.noaa.gov/viewers/'], ['Local Notice to Mariners', 'https://www.navcen.uscg.gov/local-notices-to-mariners'], ['Rip current safety', 'https://www.weather.gov/safety/ripcurrent'], ['Boating safety (USCG)', 'https://uscgboating.org/'], ['Marine forecasts', 'https://www.weather.gov/marine/']].map(([t, u]) => `<a href="${u}" target="_blank" rel="noopener">${t} ↗</a>`).join('')}</div>`;

  return `${far}${al}${outlook}<div class="mar-grid">
    <section><h4>Right now</h4>${now}${cam}</section>
    <section><h4>Seas forecast</h4>${chart}${days}</section>
    <section><h4>Tides</h4>${tides}</section>
    <section><h4>NWS marine forecast</h4>${zone}</section></div>${links}
    <p class="muted small">Buoys: NOAA NDBC. Waves: Open-Meteo Marine models. Tides: NOAA CO-OPS. Forecast: National Weather Service. Not for navigation.</p>`;
}
