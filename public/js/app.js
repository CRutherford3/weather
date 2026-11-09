import { APP_NAME, DEFAULT_LOC, alertColor } from './config.js';
import { store, units, $, $$, esc, debounce, toast, fmtT, fmtW, compass, icon, timeAgo, wx, tempColor, U, openSheet, closeSheet, dayName, hourLabel } from './util.js';
import { geocode, reverseGeocode, loadPoint, loadModels, loadDiscussion, placesNow } from './api.js';
import * as F from './forecast.js';
import * as Map from './map.js';
import { initDashboard, updateDashboard, showDashboard } from './dashboard.js';
import { plan, setPlan, can, gate, openPricing, fillAds, adSlot, TIERS, badge } from './plan.js';
import { initRoute } from './route.js';
import { getData } from './util.js';

const state = {
  loc: store.get('loc', null),
  theme: store.get('theme', 'auto'),
  favs: store.get('favs', []),
  recent: store.get('recent', []),
  M: null, models: null, afd: undefined, loading: false,
};

// ---------- theme ----------
const THEME_ICONS = {
  auto: '<svg width="18" height="18" viewBox="0 0 24 24"><circle cx="12" cy="12" r="8" fill="none" stroke="currentColor" stroke-width="2"/><path d="M12 4a8 8 0 0 1 0 16z" fill="currentColor"/></svg>',
  dark: '<svg width="18" height="18" viewBox="0 0 24 24"><path d="M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z" fill="currentColor"/></svg>',
  light: '<svg width="18" height="18" viewBox="0 0 24 24"><circle cx="12" cy="12" r="4.5" fill="currentColor"/><path d="M12 2v2.5M12 19.5V22M2 12h2.5M19.5 12H22M4.9 4.9l1.8 1.8M17.3 17.3l1.8 1.8M4.9 19.1l1.8-1.8M17.3 6.7l1.8-1.8" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>',
};
const mq = matchMedia('(prefers-color-scheme: light)');
const effTheme = () => (state.theme === 'auto' ? (mq.matches ? 'light' : 'dark') : state.theme);
function applyTheme() {
  const t = effTheme();
  document.documentElement.dataset.theme = t;
  $('meta[name="theme-color"]').content = t === 'dark' ? '#0a0f1c' : '#f3f6fb';
  $('#themeBtn').innerHTML = THEME_ICONS[state.theme];
  $('#themeBtn').title = `Theme: ${state.theme} (click to change)`;
  Map.setTheme(t);
  if (state.M) updateDashboard({});
}
mq.addEventListener('change', applyTheme);
$('#themeBtn').onclick = () => { state.theme = { auto: 'dark', dark: 'light', light: 'auto' }[state.theme]; store.set('theme', state.theme); applyTheme(); toast(`Theme: ${state.theme === 'auto' ? 'matches your device' : state.theme}`); };

// ---------- units ----------
function applyUnits() { $('#unitBtn').textContent = units.system === 'imperial' ? '°F' : '°C'; }
$('#unitBtn').onclick = () => { units.system = units.system === 'imperial' ? 'metric' : 'imperial'; store.set('units', units.system); applyUnits(); renderAll(); Map.refreshUnits(); };

// ---------- routing ----------
const VIEWS = ['radar', 'forecast', 'dashboard'];
function route() {
  const v = VIEWS.includes(location.hash.slice(1)) ? location.hash.slice(1) : 'radar';
  $('#modal').hidden = true;
  Map.closePopups(); closeSheet();
  VIEWS.forEach((x) => { $(`#view-${x}`).hidden = x !== v; });
  $$('[data-view]').forEach((a) => a.classList.toggle('active', a.dataset.view === v));
  document.body.dataset.view = v;
  if (v === 'radar') setTimeout(Map.invalidate, 50);
  if (v === 'forecast' || v === 'dashboard') loadExtras();
  if (v === 'dashboard') showDashboard();
}
window.addEventListener('hashchange', route);

// ---------- location ----------
let userPicked = false;
function setLocation(loc, { fly = true, auto = false } = {}) {
  if (!auto) userPicked = true;
  // picking a place by hand stops "follow my location" so GPS doesn't jump it back
  if (!auto && !loc.gps && watchId != null) { navigator.geolocation.clearWatch(watchId); watchId = null; updateLock(); toast('Stopped following your location'); }
  state.loc = loc; store.set('loc', loc);
  state.recent = [loc, ...state.recent.filter((r) => r.name !== loc.name)].slice(0, 6); store.set('recent', state.recent);
  $('#locName').textContent = loc.name; $('#q').value = '';
  updateFavBtn();
  Map.setHome(loc); if (fly) Map.flyTo(loc);
  state.models = null; state.afd = undefined; state.M = null;
  showLoading(loc);
  refresh();
}
// Clear the old place right away so the Forecast tab never shows the previous location
function showLoading(loc) {
  const msg = `<div class="empty">Loading ${esc(loc.name)}…</div>`;
  ['#fcHero', '#fcNowcast', '#fcDetails', '#fcHourly', '#fcDaily', '#fcAqi', '#fcSun', '#fcNws', '#fcModels', '#fcAfd', '#fcHail'].forEach((id) => { const el = $(id); if (el) el.innerHTML = msg; });
  $('#fcAlerts').innerHTML = ''; $('#alertBanner').hidden = true;
  updateDashboard({ M: null, loc, models: null, afd: undefined });
}
async function pickPoint({ lat, lon }, known) {
  const name = known || await reverseGeocode(lat, lon);
  setLocation({ lat, lon, name }, { fly: false });
  location.hash = '#forecast';
}
function geolocate(silent) {
  if (!navigator.geolocation) { if (!silent) toast('Location is not available in this browser'); return Promise.resolve(false); }
  return new Promise((res) => navigator.geolocation.getCurrentPosition(async (p) => {
    const { latitude: lat, longitude: lon } = p.coords;
    if (silent && userPicked) return res(false); // user already chose a place; don't override it
    setLocation({ lat, lon, name: await reverseGeocode(lat, lon), gps: true }, { auto: silent });
    res(true);
  }, () => { if (!silent) toast('Could not get your location. Check location permissions.'); res(false); }, { timeout: 10000, maximumAge: 300000 }));
}
$('#locBtn').onclick = () => geolocate(false);

// ---------- saved places ----------
const near = (a, b) => Math.abs(a.lat - b.lat) < 0.02 && Math.abs(a.lon - b.lon) < 0.02;
const isFav = () => state.loc && state.favs.some((f) => near(f, state.loc));
function saveFavs() { store.set('favs', state.favs); updateFavBtn(); Map.drawPlaces(); }
function updateFavBtn() { $('#favBtn').textContent = isFav() ? '★' : '☆'; $('#favBtn').classList.toggle('on', !!isFav()); }
$('#favBtn').onclick = () => {
  if (isFav()) state.favs = state.favs.filter((f) => !near(f, state.loc));
  else state.favs = [...state.favs, { lat: state.loc.lat, lon: state.loc.lon, name: state.loc.name }];
  saveFavs(); toast(isFav() ? `Saved ${state.loc.name}` : 'Removed from My Places');
};
async function savePlace({ lat, lon }) {
  const name = await reverseGeocode(lat, lon);
  if (!state.favs.some((f) => near(f, { lat, lon }))) state.favs = [...state.favs, { lat, lon, name }];
  saveFavs(); toast(`Saved ${name} to My Places`);
}
async function openPlaces() {
  const list = state.favs;
  const rows = list.map((p, i) => `<div class="place-row" data-i="${i}"><button class="place-main" data-go="${i}"><span class="place-star">★</span><span class="place-name">${esc(p.name)}</span><span class="place-temp" id="pt${i}">--</span></button><button class="place-del" data-del="${i}" aria-label="Remove ${esc(p.name)}">✕</button></div>`).join('');
  openSheet('My Places', `${list.length ? `<div class="place-list">${rows}</div>` : '<p class="empty">No saved places yet.</p>'}
    <button class="btn wide" id="addHere">+ Save ${esc(state.loc?.name || 'this location')}</button>
    <p class="muted small sheet-foot">Tip: tap anywhere on the map and choose <b>Save place</b>. Saved places show as stars on the map.</p>`, async (b) => {
    $$('[data-go]', b).forEach((x) => x.onclick = () => { const p = state.favs[+x.dataset.go]; closeSheet(); setLocation({ ...p }); });
    $$('[data-del]', b).forEach((x) => x.onclick = () => { state.favs = state.favs.filter((_, i) => i !== +x.dataset.del); saveFavs(); openPlaces(); });
    $('#addHere', b).onclick = () => { if (!isFav()) { state.favs = [...state.favs, { lat: state.loc.lat, lon: state.loc.lon, name: state.loc.name }]; saveFavs(); } openPlaces(); };
    try { (await placesNow(list)).forEach((r, i) => { const el = $(`#pt${i}`, b); if (el && r.current) el.innerHTML = `${icon(wx(r.current.weather_code, r.current.is_day).icon, 26)} ${fmtT(r.current.temperature_2m)}`; }); } catch { /* temps optional */ }
  });
}

// follow my location (lock)
let watchId = null;
function updateLock() { $('#wxLock')?.classList.toggle('on', watchId != null); }
function toggleFollow() {
  if (watchId != null) { navigator.geolocation.clearWatch(watchId); watchId = null; updateLock(); toast('Stopped following your location'); return; }
  if (!navigator.geolocation) return toast('Location is not available in this browser');
  watchId = navigator.geolocation.watchPosition(async (p) => {
    const { latitude: lat, longitude: lon } = p.coords;
    if (!state.loc?.gps || !near(state.loc, { lat, lon })) setLocation({ lat, lon, name: await reverseGeocode(lat, lon), gps: true }, { auto: true });
  }, () => { toast('Could not get your location. Check location permissions.'); watchId = null; updateLock(); }, { maximumAge: 60000, timeout: 15000 });
  updateLock(); toast('Following your location');
}

// search
const results = $('#results');
function showList(items, title) {
  if (!items.length) { results.hidden = true; return; }
  results.innerHTML = (title ? `<div class="res-h">${title}</div>` : '') + items.map((r, i) => `<button data-i="${i}">${r.fav ? '★ ' : ''}${esc(r.name)}</button>`).join('');
  results.hidden = false;
  $$('button', results).forEach((b) => b.onmousedown = (e) => { e.preventDefault(); results.hidden = true; $('#q').blur(); setLocation(items[+b.dataset.i]); });
}
function showDefaults() {
  const items = [...state.favs.map((f) => ({ ...f, fav: true })), ...state.recent.filter((r) => !state.favs.some((f) => f.name === r.name))];
  showList(items, items.length ? 'Saved & recent' : '');
}
$('#q').addEventListener('focus', () => { $('#searchWrap').classList.add('typing'); showDefaults(); });
$('#q').addEventListener('blur', () => setTimeout(() => { results.hidden = true; $('#searchWrap').classList.remove('typing'); }, 150));
$('#q').addEventListener('input', debounce(async (e) => {
  const q = e.target.value.trim();
  if (q.length < 2) return showDefaults();
  const m = q.match(/^\s*(-?\d+(\.\d+)?)\s*,\s*(-?\d+(\.\d+)?)\s*$/);
  if (m) return showList([{ lat: +m[1], lon: +m[3], name: `${(+m[1]).toFixed(3)}, ${(+m[3]).toFixed(3)}` }]);
  try { showList(await geocode(q)); } catch { toast('Search is unavailable right now'); }
}, 250));
$('#q').addEventListener('keydown', (e) => { if (e.key === 'Enter') { const b = $('button', results); if (b) b.dispatchEvent(new MouseEvent('mousedown')); } if (e.key === 'Escape') $('#q').blur(); });

// ---------- data ----------
let refreshTok = 0;
async function refresh() {
  if (!state.loc) return;
  const tok = ++refreshTok, loc = state.loc;
  state.loading = true; document.body.classList.add('loading');
  try {
    const D = await loadPoint(loc);
    if (tok !== refreshTok || state.loc !== loc) return; // a newer location was picked while this loaded
    state.M = F.buildModel(D);
    state.lastRefresh = Date.now();
    renderAll();
    if (!$('#view-forecast').hidden || !$('#view-dashboard').hidden) loadExtras();
  } catch (e) {
    if (tok !== refreshTok) return;
    console.error(e); toast('Could not load the forecast. Retrying in a minute.'); setTimeout(refresh, 60e3);
  } finally { if (tok === refreshTok) { state.loading = false; document.body.classList.remove('loading'); } }
}
async function loadExtras() {
  if (!state.loc || !state.M) return;
  const loc = state.loc, same = () => state.loc === loc;
  if (!state.models) { state.models = []; loadModels(loc).then((m) => { if (!same()) return; state.models = m; $('#fcModels').innerHTML = F.modelsHTML(m); updateDashboard({ models: m }); }).catch(() => { $('#fcModels').innerHTML = '<div class="empty">Model data unavailable right now.</div>'; }); }
  hailHistory($('#fcHail'));
  if (state.afd === undefined && state.M.nws?.office) { state.afd = null; loadDiscussion(state.M.nws.office).then((a) => { if (!same()) return; state.afd = a; $('#fcAfd').innerHTML = F.afdHTML(a); updateDashboard({ afd: a }); }).catch(() => { $('#fcAfd').innerHTML = F.afdHTML(null); updateDashboard({ afd: null }); }); }
  else if (!state.M.nws) { $('#fcAfd').innerHTML = F.afdHTML(null); updateDashboard({ afd: null }); }
}

// ---------- hail history (Pro) ----------
const hailCache = {};
async function hailHistory(el) {
  if (!el || !state.loc) return;
  const loc = state.loc;
  if (!can('hailHistory')) {
    el.innerHTML = `<div class="locked-card"><p>See every hail report within 10 miles of <b>${esc(loc.name)}</b> over the past 5 years: dates, stone sizes and how close they hit. Handy for roof and insurance claims.</p><button class="btn" data-unlock>Unlock with Pro</button></div>`;
    $('[data-unlock]', el).onclick = () => gate('hailHistory', 'Hail history');
    return;
  }
  const key = `${loc.lat.toFixed(3)},${loc.lon.toFixed(3)}`;
  el.innerHTML = '<div class="empty">Searching 5 years of storm reports…</div>';
  try {
    const dLat = 0.145, dLon = 0.145 / Math.cos(loc.lat * Math.PI / 180);
    const now = new Date(), sts = new Date(now); sts.setFullYear(now.getFullYear() - 5);
    const iso = (d) => d.toISOString().slice(0, 16) + 'Z';
    const j = hailCache[key] || (hailCache[key] = await getData(`https://mesonet.agron.iastate.edu/geojson/lsr.geojson?west=${(loc.lon - dLon).toFixed(3)}&east=${(loc.lon + dLon).toFixed(3)}&south=${(loc.lat - dLat).toFixed(3)}&north=${(loc.lat + dLat).toFixed(3)}&sts=${iso(sts)}&ets=${iso(now)}`, { timeout: 40000 }));
    if (state.loc !== loc) return;
    const mi = (a, b) => { const R = 3958.8, t = Math.PI / 180, x = (b[0] - a.lon) * t * Math.cos(a.lat * t), y = (b[1] - a.lat) * t; return Math.sqrt(x * x + y * y) * R; };
    const rows = j.features.filter((f) => /HAIL/i.test(f.properties.typetext || '')).map((f) => ({ p: f.properties, size: parseFloat(f.properties.magnitude) || 0, d: mi(loc, f.geometry.coordinates), t: new Date(String(f.properties.valid).endsWith('Z') ? f.properties.valid : f.properties.valid + 'Z') }))
      .filter((r) => r.d <= 10).sort((a, b) => b.t - a.t);
    if (!rows.length) { el.innerHTML = `<div class="empty ok">✓ No hail reports within 10 miles in the past 5 years.</div>`; return; }
    const big = rows.reduce((a, b) => (b.size > a.size ? b : a));
    const days = new Set(rows.map((r) => r.t.toDateString())).size;
    el.innerHTML = `<div class="hh-sum"><div><b>${rows.length}</b><small>reports</small></div><div><b>${days}</b><small>hail days</small></div><div><b>${big.size.toFixed(2)}"</b><small>largest ${Map.hailName(big.size)}</small></div><div><b>${rows[0].t.toLocaleDateString([], { month: 'short', day: 'numeric', year: 'numeric' })}</b><small>most recent</small></div></div>
      <div class="hh-list">${rows.slice(0, 40).map((r) => `<div class="hh-row"><span class="hh-dot" style="--s:${Math.min(28, 10 + r.size * 5)}px"></span><b>${r.size.toFixed(2)}"</b><span>${r.t.toLocaleDateString([], { month: 'short', day: 'numeric', year: 'numeric' })}</span><span>${r.d.toFixed(1)} mi · ${esc(r.p.city || '')}</span></div>`).join('')}</div>
      <p class="muted small">From NWS storm reports (people who saw it and reported it). Radar-estimated hail swaths are coming in a later update.</p>`;
  } catch (e) { console.warn(e); el.innerHTML = '<div class="empty">Hail history is unavailable right now.</div>'; }
}
window.addEventListener('hail-history', (e) => hailHistory(e.detail));

// ---------- rendering ----------
function renderAll() {
  const M = state.M; if (!M) return;
  const loc = state.loc;
  const c = M.current;
  $('#wxCard').innerHTML = wxCardHTML(M, loc); wireCard();
  // forecast page
  $('#fcHero').innerHTML = F.heroHTML(M, loc);
  $('#fcAlerts').innerHTML = F.alertsHTML(M);
  $('#fcNowcast').innerHTML = F.nowcastHTML(M);
  $('#fcDetails').innerHTML = F.detailsHTML(M);
  $('#fcHourly').innerHTML = F.hourlyHTML(M, 72);
  $('#hrSrc').textContent = M.hours[0]?.src === 'NWS' ? 'Official NWS hourly forecast' : 'Model forecast';
  $('#fcDaily').innerHTML = F.dailyHTML(M, 16);
  $('#fcAqi').innerHTML = F.aqHTML(M);
  $('#fcSun').innerHTML = F.sunHTML(M);
  $('#fcNws').innerHTML = F.nwsTextHTML(M);
  if (state.models?.length) $('#fcModels').innerHTML = F.modelsHTML(state.models);
  $('#fcSources').innerHTML = M.sources.map((s) => `<li>${esc(s)}</li>`).join('') + `<li>Updated ${timeAgo(Date.now())}</li>`;
  // alert banner
  const top = M.alerts[0];
  const ban = $('#alertBanner');
  if (top) { ban.hidden = false; ban.style.setProperty('--ac', alertColor(top.event)); ban.innerHTML = `<b>${esc(top.event)}</b><span>${esc(top.areaDesc?.split(';')[0] || '')}${M.alerts.length > 1 ? ` · +${M.alerts.length - 1} more` : ''}</span><em>Details ›</em>`; ban.onclick = () => showAlert(top); }
  else ban.hidden = true;
  wireAlertButtons(document);
  document.title = `${fmtT(c.temp)} ${loc.name} · ${APP_NAME}`;
  updateDashboard({ M, loc });
}
// MyRadar-style header card: temperature ring, next high/low, rain chance, next two days
function wxCardHTML(M, loc) {
  const c = M.current, hs = M.hours.slice(0, 24);
  let hiH = hs[0], loH = hs[0];
  for (const h of hs) { if (h.temp > hiH.temp) hiH = h; if (h.temp < loH.temp) loH = h; }
  const hi = Math.max(hiH.temp, c.temp), lo = Math.min(loH.temp, c.temp);
  const f = Math.max(0, Math.min(1, (c.temp - lo) / Math.max(0.5, hi - lo)));
  const R = 44, cx = 54, cy = 54, P = (a) => [cx + R * Math.cos(a * Math.PI / 180), cy + R * Math.sin(a * Math.PI / 180)].map((v) => v.toFixed(1));
  const [sx, sy] = P(135), [ex, ey] = P(45), [dx, dy] = P(135 + 270 * f);
  const ring = `<svg viewBox="0 0 108 108" class="ring"><defs><linearGradient id="rg" x1="0" x2="1" y1="0" y2="0"><stop offset="0" stop-color="${tempColor(lo)}"/><stop offset="1" stop-color="${tempColor(hi)}"/></linearGradient></defs>
    <path d="M${sx} ${sy} A${R} ${R} 0 1 1 ${ex} ${ey}" fill="none" stroke="url(#rg)" stroke-width="9" stroke-linecap="round"/>
    <circle cx="${dx}" cy="${dy}" r="7" fill="#fff" stroke="rgba(0,0,0,.35)" stroke-width="1.5"/>
    <g class="ring-tag"><circle cx="${sx}" cy="${sy}" r="8" fill="${tempColor(lo)}"/><text x="${sx}" y="${+sy + 3.5}">L</text><circle cx="${ex}" cy="${ey}" r="8" fill="${tempColor(hi)}"/><text x="${ex}" y="${+ey + 3.5}">H</text></g></svg>`;
  const hiFirst = hiH.time <= loH.time;
  const pill = (h, v) => `<div class="hl"><span style="background:${tempColor(v)}">${fmtT(v)}</span><small>${hourLabel(h.time)}</small></div>`;
  const days = [1, 2].map((i) => { const d = M.days[i]; if (!d) return ''; return `<div class="wx-day"><b>${dayName(d.date).toUpperCase()}</b>${icon(d.icon, 40)}<span>${fmtT(d.hi)} <em>${fmtT(d.lo)}</em></span><i style="background:linear-gradient(90deg,${tempColor(d.lo)},${tempColor(d.hi)})"></i></div>`; }).join('');
  const lockSvg = '<svg width="20" height="22" viewBox="0 0 20 22"><rect x="2" y="10" width="16" height="11" rx="2.5" fill="currentColor"/><path d="M5.5 10V6.5a4.5 4.5 0 0 1 9 0' + (watchId != null ? 'V10' : '') + '" fill="none" stroke="currentColor" stroke-width="2.4"/></svg>';
  return `<div class="wx-top"><button class="wx-ic${watchId != null ? ' on' : ''}" id="wxLock" title="Follow my location">${lockSvg}</button>
      <button class="wx-loc" id="wxLoc" title="Search places"><span>${esc(loc.name)}</span><span class="wx-mini">${fmtT(c.temp)} ${icon(c.icon, 22)}</span></button>
      <button class="wx-ic" id="wxPin" title="My places"><svg width="22" height="26" viewBox="0 0 22 26"><path d="M11 25S2 15 2 9.5a9 9 0 0 1 18 0C20 15 11 25 11 25z" fill="currentColor"/><path d="M11 4.8l1.5 3.1 3.4.5-2.5 2.4.6 3.4-3-1.6-3 1.6.6-3.4-2.5-2.4 3.4-.5z" fill="var(--card)"/></svg></button></div>
    <div class="wx-body">
      <a class="wx-ring" href="#forecast" title="Full forecast">${ring}<div class="wx-now"><b>${fmtT(c.temp)}</b><span>now</span></div></a>
      <div class="wx-hls">${hiFirst ? pill(hiH, hi) + pill(loH, lo) : pill(loH, lo) + pill(hiH, hi)}</div>
      <a class="wx-cond" href="#forecast" title="${esc(c.text)}">${icon(c.icon, 62)}<span>${M.days[0].pop ?? 0}% <svg width="16" height="16" viewBox="0 0 24 24"><path d="M12 3s-6 7-6 11a6 6 0 0 0 12 0c0-4-6-11-6-11z" fill="#38bdf8"/></svg></span></a>
      <div class="wx-days">${days}</div>
    </div>
    <button class="wx-grab" id="wxGrab" aria-label="Show or hide details"><span></span></button>`;
}
function wireCard() {
  $('#wxLock').onclick = toggleFollow;
  $('#wxPin').onclick = openPlaces;
  $('#wxLoc').onclick = () => { $('#q').focus(); };
  $('#wxGrab').onclick = () => { $('#wxCard').classList.toggle('collapsed'); store.set('cardCollapsed', $('#wxCard').classList.contains('collapsed')); };
}
function wireAlertButtons(root) {
  $$('#fcAlerts [data-alert]', root).forEach((b) => b.onclick = () => showAlert(state.M.alerts[+b.dataset.alert]));
}

// ---------- alert detail, modal, lightbox ----------
function showAlert(a) {
  if (!a) return;
  const html = `<div class="alert-detail" style="--ac:${alertColor(a.event)}">
    <div class="ad-head"><b>${esc(a.event)}</b><span>${esc(a.severity || '')} · ${esc(a.urgency || '')}</span></div>
    ${a.headline ? `<p class="ad-headline">${esc(a.headline)}</p>` : ''}
    <p class="muted small">Issued by ${esc(a.senderName || 'NWS')} · ${a.effective ? new Date(a.effective).toLocaleString() : ''} until ${a.ends || a.expires ? new Date(a.ends || a.expires).toLocaleString() : 'further notice'}</p>
    <h4>Areas</h4><p class="small">${esc(a.areaDesc || '')}</p>
    <h4>Details</h4><pre class="ad-text">${esc(a.description || '')}</pre>
    ${a.instruction ? `<h4>What to do</h4><pre class="ad-text">${esc(a.instruction)}</pre>` : ''}</div>`;
  openModal(a.event, html);
}
window.addEventListener('show-alert', (e) => showAlert(e.detail));
function openModal(title, html) { $('#modalTitle').textContent = title; $('#modalBody').innerHTML = html; $('#modal').hidden = false; $('#modalBody').scrollTop = 0; }
const closeModal = () => { $('#modal').hidden = true; };
$('#modalClose').onclick = closeModal;
$('#modal').onclick = (e) => { if (e.target.id === 'modal') closeModal(); };
window.addEventListener('modal', (e) => openModal(e.detail.title, e.detail.html));
window.addEventListener('modal-close', closeModal);
window.addEventListener('lightbox', (e) => { const lb = $('#lightbox'); $('img', lb).src = e.detail.src; $('img', lb).alt = e.detail.alt; lb.hidden = false; });
$('#lightbox').onclick = () => { $('#lightbox').hidden = true; };
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') { closeModal(); $('#lightbox').hidden = true; } });
window.addEventListener('storms', (e) => updateDashboard({ storms: e.detail }));


// ---------- settings sheet (MyRadar-style) ----------
const VERSION = '2.1.0';
const ATTRIB = [
  ['National Weather Service (NOAA)', 'Forecasts, observations, alerts, radar loops', 'https://www.weather.gov/'],
  ['NOAA NEXRAD via Iowa Environmental Mesonet', 'Radar mosaic, rain totals, GOES and lightning tiles', 'https://mesonet.agron.iastate.edu/'],
  ['NOAA NHC, SPC, WPC, CPC', 'Hurricanes, severe outlooks, fronts, rain and long-range outlooks', 'https://www.noaa.gov/'],
  ['NOAA NESDIS / GOES-East', 'Satellite imagery', 'https://www.star.nesdis.noaa.gov/GOES/'],
  ['NASA GIBS', 'True color satellite tiles', 'https://www.earthdata.nasa.gov/engage/open-data-services-software/earthdata-developer-portal/gibs-api'],
  ['Open-Meteo (CC BY 4.0)', 'Model forecasts, air quality, geocoding', 'https://open-meteo.com/'],
  ['RainViewer', 'Worldwide radar', 'https://www.rainviewer.com/'],
  ['U.S. Geological Survey', 'Earthquakes', 'https://earthquake.usgs.gov/'],
  ['National Interagency Fire Center', 'Wildfires', 'https://www.nifc.gov/'],
  ['U.S. Drought Monitor (UNL, USDA, NOAA)', 'Drought areas', 'https://droughtmonitor.unl.edu/'],
  ['Where The ISS At?', 'Space station position', 'https://wheretheiss.at/'],
  ['OpenFreeMap / OpenMapTiles / OpenStreetMap contributors', 'Map styles and map data', 'https://openfreemap.org/'],
  ['Esri', 'Satellite basemap imagery', 'https://www.esri.com/'],
  ['OSRM / OpenStreetMap', 'Driving routes', 'https://project-osrm.org/'],
  ['U.S. DOE Alternative Fuels Data Center', 'EV charging stations', 'https://afdc.energy.gov/'],
  ['TomTom', 'Traffic', 'https://developer.tomtom.com/'],
  ['NOAA SWPC, OPC, CIMSS, Tropical Tidbits', 'Space weather, marine, tropical analysis and spaghetti plots', 'https://www.swpc.noaa.gov/'],
  ['BigDataCloud', 'Place names for your location', 'https://www.bigdatacloud.com/'],
  ['MapLibre GL JS (BSD-3)', 'Map engine', 'https://maplibre.org/'],
  ['Leaflet (BSD-2), SortableJS (MIT)', 'Dashboard mini map and drag to reorder', 'https://leafletjs.com/'],
];
function openSettings(view = 'main') {
  if (view === 'attrib') {
    openSheet('Licenses & Attributions', `<button class="sheet-back" id="setBack">‹ Settings</button><div class="sheet-sub">Data and software</div>${ATTRIB.map(([n, d, u]) => `<a class="set-row" href="${u}" target="_blank" rel="noopener"><span><b>${esc(n)}</b><small>${esc(d)}</small></span><i class="chev">›</i></a>`).join('')}`, (b) => { $('#setBack', b).onclick = () => openSettings(); });
    return;
  }
  if (view === 'privacy') {
    openSheet('Privacy', `<button class="sheet-back" id="setBack">‹ Settings</button><div class="set-text"><p>Your location, saved places, layers and dashboard layout are stored only in this browser. There are no accounts and no tracking by Updraft.</p><p>On the free plan, ads may be shown by Google AdSense, which can use cookies to pick ads. Paid plans have no ads.</p><p>To show weather for a spot, its coordinates are sent to the weather services listed under Licenses & Attributions, the same way any weather site works.</p><p>Clearing this site's data in your browser removes everything.</p></div>`, (b) => { $('#setBack', b).onclick = () => openSettings(); });
    return;
  }
  const imp = units.system === 'imperial';
  openSheet('Settings', `<div class="set-pad"><div class="seg big" id="setUnits"><button data-v="metric" class="${imp ? '' : 'on'}">Celsius</button><button data-v="imperial" class="${imp ? 'on' : ''}">Fahrenheit</button></div></div>
    <div class="sheet-sub">Appearance</div>
    <div class="set-pad"><div class="seg big" id="setTheme">${['auto', 'dark', 'light'].map((t) => `<button data-v="${t}" class="${state.theme === t ? 'on' : ''}">${t === 'auto' ? 'Auto' : t[0].toUpperCase() + t.slice(1)}</button>`).join('')}</div></div>
    <div class="sheet-sub">Your plan</div>
    <button class="set-row" id="setPlan"><span><b>Updraft ${TIERS[plan()].name}</b><small>${plan() === 'free' ? 'Go ad-free and unlock every layer' : 'Thanks for supporting Updraft'}</small></span><i class="chev">›</i></button>
    <div class="set-pad"><small class="muted">Preview plan (testing only, until checkout is connected)</small><div class="seg" id="setPreview">${['free', 'plus', 'pro'].map((t) => `<button data-v="${t}" class="${plan() === t ? 'on' : ''}">${TIERS[t].name}</button>`).join('')}</div></div>
    <div class="sheet-sub">Location</div>
    <div class="lrow"><div class="lrow-main"><span>Follow My Location</span></div><label class="tg"><input type="checkbox" id="setFollow" ${watchId != null ? 'checked' : ''}><span></span></label></div>
    <p class="set-note">Keep the forecast and map centered on you as you move.</p>
    <button class="set-row" id="setPlaces"><span><b>My Places</b><small>${state.favs.length} saved</small></span><i class="chev">›</i></button>
    <div class="sheet-sub">Alerts</div>
    <div class="set-row static"><span><b>Severe weather notifications</b><small>Push alerts for your saved places arrive with the iPhone app. Until then, warnings show in the red banner and on the map.</small></span></div>
    <div class="sheet-sub">About</div>
    <button class="set-row" id="setAttrib"><span><b>Licenses & Attributions</b></span><i class="chev">›</i></button>
    <button class="set-row" id="setPrivacy"><span><b>Privacy</b></span><i class="chev">›</i></button>
    <button class="set-row" id="setReset"><span><b>Reset map layers</b><small>Back to the default layers and style</small></span><i class="chev">›</i></button>
    <p class="set-ver">${esc(APP_NAME)} ${VERSION}</p>`, (b) => {
    $$('#setUnits button', b).forEach((x) => x.onclick = () => { if (units.system !== x.dataset.v) $('#unitBtn').click(); openSettings(); });
    $$('#setTheme button', b).forEach((x) => x.onclick = () => { state.theme = x.dataset.v; store.set('theme', state.theme); applyTheme(); openSettings(); });
    $('#setFollow', b).onchange = () => toggleFollow();
    $('#setPlan', b).onclick = () => openPricing();
    $$('#setPreview button', b).forEach((x) => x.onclick = () => { setPlan(x.dataset.v); toast(`Previewing ${TIERS[x.dataset.v].name}`); openSettings(); });
    $('#setPlaces', b).onclick = openPlaces;
    $('#setAttrib', b).onclick = () => openSettings('attrib');
    $('#setPrivacy', b).onclick = () => openSettings('privacy');
    $('#setReset', b).onclick = () => { store.set('layers2', null); store.set('mapStyle', 'auto'); location.reload(); };
  });
}

// ---------- radar toolbar ----------
function wireTools() {
  $('#toolLocate').onclick = () => geolocate(false);
  $('#toolPlaces').onclick = openPlaces;
  $('#toolSettings').onclick = () => openSettings();
  $('#toolForecast').onclick = () => { location.hash = '#forecast'; };
  $('#toolDash').onclick = () => { location.hash = '#dashboard'; };
  if (store.get('cardCollapsed', false)) $('#wxCard').classList.add('collapsed');
}

// ---------- boot ----------
async function boot() {
  // wordmark is styled in index.html; APP_NAME drives titles
  applyUnits();
  const start = state.loc || DEFAULT_LOC;
  Map.initMap('map', start, effTheme, { onPick: pickPoint, onSavePlace: savePlace, getPlaces: () => state.favs });
  applyTheme();
  document.body.dataset.plan = plan();
  wireTools();
  initRoute(() => state.loc);
  initDashboard();
  ['#fcAd1', '#fcAd2', '#fcAd3'].forEach((id) => { $(id).innerHTML = adSlot('banner'); });
  $('#radarAd').innerHTML = adSlot('box');
  fillAds(document);
  window.addEventListener('plan', () => { ['#fcAd1', '#fcAd2', '#fcAd3'].forEach((id) => { $(id).innerHTML = adSlot('banner'); }); $('#radarAd').innerHTML = adSlot('box'); fillAds(document); Map.applyLayers(); if (state.M) hailHistory($('#fcHail')); });
  route();
  if (state.loc) { $('#locName').textContent = state.loc.name; updateFavBtn(); refresh(); }
  else { setLocation(DEFAULT_LOC, { fly: false, auto: true }); geolocate(true); }
  setInterval(refresh, 10 * 60e3);
  document.addEventListener('visibilitychange', () => { if (!document.hidden && state.M && Date.now() - (state.lastRefresh || 0) > 5 * 60e3) refresh(); });
  if ('serviceWorker' in navigator && location.protocol === 'https:') navigator.serviceWorker.register('/sw.js').catch(() => {});
}
boot();
