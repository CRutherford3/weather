import { APP_NAME, DEFAULT_LOC, alertColor } from './config.js';
import { store, units, $, $$, esc, debounce, toast, fmtT, fmtW, compass, icon, timeAgo } from './util.js';
import { geocode, reverseGeocode, loadPoint, loadModels, loadDiscussion } from './api.js';
import * as F from './forecast.js';
import * as Map from './map.js';
import { initDashboard, updateDashboard, showDashboard } from './dashboard.js';

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
  Map.setBase(t);
  if (state.M) updateDashboard({});
}
mq.addEventListener('change', applyTheme);
$('#themeBtn').onclick = () => { state.theme = { auto: 'dark', dark: 'light', light: 'auto' }[state.theme]; store.set('theme', state.theme); applyTheme(); toast(`Theme: ${state.theme === 'auto' ? 'matches your device' : state.theme}`); };

// ---------- units ----------
function applyUnits() { $('#unitBtn').textContent = units.system === 'imperial' ? '°F' : '°C'; }
$('#unitBtn').onclick = () => { units.system = units.system === 'imperial' ? 'metric' : 'imperial'; store.set('units', units.system); applyUnits(); renderAll(); Map.applyLayers(); };

// ---------- routing ----------
const VIEWS = ['radar', 'forecast', 'dashboard'];
function route() {
  const v = VIEWS.includes(location.hash.slice(1)) ? location.hash.slice(1) : 'radar';
  $('#modal').hidden = true;
  Map.getMap()?.closePopup();
  VIEWS.forEach((x) => { $(`#view-${x}`).hidden = x !== v; });
  $$('[data-view]').forEach((a) => a.classList.toggle('active', a.dataset.view === v));
  document.body.dataset.view = v;
  if (v === 'radar') setTimeout(Map.invalidate, 50);
  if (v === 'forecast' || v === 'dashboard') loadExtras();
  if (v === 'dashboard') showDashboard();
}
window.addEventListener('hashchange', route);

// ---------- location ----------
function setLocation(loc, { fly = true } = {}) {
  state.loc = loc; store.set('loc', loc);
  state.recent = [loc, ...state.recent.filter((r) => r.name !== loc.name)].slice(0, 6); store.set('recent', state.recent);
  $('#locName').textContent = loc.name; $('#q').value = '';
  updateFavBtn();
  Map.setHome(loc); if (fly) Map.flyTo(loc);
  state.models = null; state.afd = undefined;
  refresh();
}
async function pickPoint({ lat, lon }) {
  const name = await reverseGeocode(lat, lon);
  setLocation({ lat, lon, name }, { fly: false });
  location.hash = '#forecast';
}
function geolocate(silent) {
  if (!navigator.geolocation) { if (!silent) toast('Location is not available in this browser'); return Promise.resolve(false); }
  return new Promise((res) => navigator.geolocation.getCurrentPosition(async (p) => {
    const { latitude: lat, longitude: lon } = p.coords;
    setLocation({ lat, lon, name: await reverseGeocode(lat, lon), gps: true });
    res(true);
  }, () => { if (!silent) toast('Could not get your location. Check location permissions.'); res(false); }, { timeout: 10000, maximumAge: 300000 }));
}
$('#locBtn').onclick = () => geolocate(false);

// favorites
const isFav = () => state.favs.some((f) => f.name === state.loc?.name);
function updateFavBtn() { $('#favBtn').textContent = isFav() ? '★' : '☆'; $('#favBtn').classList.toggle('on', isFav()); }
$('#favBtn').onclick = () => {
  if (isFav()) state.favs = state.favs.filter((f) => f.name !== state.loc.name);
  else state.favs = [...state.favs, { lat: state.loc.lat, lon: state.loc.lon, name: state.loc.name }];
  store.set('favs', state.favs); updateFavBtn(); toast(isFav() ? `Saved ${state.loc.name}` : 'Removed from saved places');
};

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
async function refresh() {
  if (!state.loc) return;
  state.loading = true; document.body.classList.add('loading');
  try {
    const D = await loadPoint(state.loc);
    state.M = F.buildModel(D);
    state.lastRefresh = Date.now();
    renderAll();
    if (!$('#view-forecast').hidden || !$('#view-dashboard').hidden) loadExtras();
  } catch (e) {
    console.error(e); toast('Could not load the forecast. Retrying in a minute.'); setTimeout(refresh, 60e3);
  } finally { state.loading = false; document.body.classList.remove('loading'); }
}
async function loadExtras() {
  if (!state.loc || !state.M) return;
  if (!state.models) { state.models = []; loadModels(state.loc).then((m) => { state.models = m; $('#fcModels').innerHTML = F.modelsHTML(m); updateDashboard({ models: m }); }).catch(() => { $('#fcModels').innerHTML = '<div class="empty">Model data unavailable right now.</div>'; }); }
  if (state.afd === undefined && state.M.nws?.office) { state.afd = null; loadDiscussion(state.M.nws.office).then((a) => { state.afd = a; $('#fcAfd').innerHTML = F.afdHTML(a); updateDashboard({ afd: a }); }).catch(() => { $('#fcAfd').innerHTML = F.afdHTML(null); updateDashboard({ afd: null }); }); }
  else if (!state.M.nws) { $('#fcAfd').innerHTML = F.afdHTML(null); updateDashboard({ afd: null }); }
}

// ---------- rendering ----------
function renderAll() {
  const M = state.M; if (!M) return;
  const loc = state.loc;
  // radar side panel
  const c = M.current, t = M.days[0];
  $('#rpNow').innerHTML = `<a class="rp-card" href="#forecast">${icon(c.icon, 56)}<div class="rp-main"><div class="rp-temp">${fmtT(c.temp)}</div><div class="rp-cond">${esc(c.text)}</div></div>
    <div class="rp-side"><div>H ${fmtT(t.hi)} · L ${fmtT(t.lo)}</div><div>Feels ${fmtT(c.feels)}</div><div>${compass(c.dir)} ${fmtW(c.wind)}</div></div></a>
    <div class="rp-next">${nextHoursText(M)}</div>`;
  $('#rpAlerts').innerHTML = M.alerts.length ? F.alertsHTML(M, true) : '';
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
function nextHoursText(M) {
  const h = M.hours.slice(0, 12); const wet = h.find((x) => x.pop >= 40);
  if (!wet) return 'Low rain chances for the next 12 hours.';
  const idx = h.indexOf(wet);
  return idx === 0 ? `${esc(wet.text)} likely now (${wet.pop}%).` : `${esc(wet.text)} possible in about ${idx} hr (${wet.pop}%).`;
}
function wireAlertButtons(root) {
  $$('#rpAlerts [data-alert], #fcAlerts [data-alert]', root).forEach((b) => b.onclick = () => showAlert(state.M.alerts[+b.dataset.alert]));
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

// ---------- radar panel controls ----------
function buildPanel() {
  $('#layerList').innerHTML = Map.LAYER_INFO.map((l) => `<label class="layer"><input type="checkbox" data-layer="${l.id}" ${Map.S.layers[l.id] ? 'checked' : ''}><span class="sw"></span><div><b>${l.name}</b><small>${l.desc}</small></div></label>`).join('');
  $$('[data-layer]').forEach((cb) => cb.onchange = () => { Map.S.layers[cb.dataset.layer] = cb.checked; Map.applyLayers(); });
  const seg = (sel, cur, fn) => { $$(`${sel} button`).forEach((b) => { b.classList.toggle('on', b.dataset.v === cur); b.onclick = () => { $$(`${sel} button`).forEach((x) => x.classList.toggle('on', x === b)); fn(b.dataset.v); }; }); };
  seg('#baseSeg', Map.S.base, (v) => Map.setBaseMode(v, effTheme()));
  seg('#srcSeg', Map.S.radarSrc, Map.setRadarSrc);
  seg('#satSeg', Map.S.sat, (v) => { Map.setSat(v); if (!Map.S.layers.sat) { Map.S.layers.sat = true; $('[data-layer="sat"]').checked = true; Map.applyLayers(); } });
  $('#opacity').value = Map.S.opacity; $('#opacity').oninput = (e) => Map.setOpacity(+e.target.value);
  $('#speed').value = 1150 - Map.S.speed; $('#speed').oninput = (e) => Map.setSpeed(1150 - +e.target.value);
  const toggle = () => { document.body.classList.toggle('panel-open'); setTimeout(Map.invalidate, 260); };
  $('#panelToggle').onclick = toggle; $('#panelHandle').onclick = toggle;
  if (innerWidth >= 1000 && store.get('panelOpen', true)) document.body.classList.add('panel-open');
  $('#panelToggle').addEventListener('click', () => store.set('panelOpen', document.body.classList.contains('panel-open')));
}

// ---------- boot ----------
async function boot() {
  $('#appName').textContent = APP_NAME;
  applyUnits();
  const start = state.loc || DEFAULT_LOC;
  Map.initMap('map', start, effTheme, pickPoint);
  applyTheme();
  buildPanel();
  initDashboard();
  route();
  if (state.loc) { $('#locName').textContent = state.loc.name; updateFavBtn(); refresh(); }
  else { setLocation(DEFAULT_LOC, { fly: false }); geolocate(true); }
  setInterval(refresh, 10 * 60e3);
  document.addEventListener('visibilitychange', () => { if (!document.hidden && state.M && Date.now() - (state.lastRefresh || 0) > 5 * 60e3) refresh(); });
  if ('serviceWorker' in navigator && location.protocol === 'https:') navigator.serviceWorker.register('/sw.js').catch(() => {});
}
boot();
