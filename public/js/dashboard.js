// Customizable dashboard: widgets can be added, removed, resized and dragged into any order. Saved per browser.
import { store, esc, $, $$, toast, getData } from './util.js';
import * as F from './forecast.js';
import { TILES } from './config.js';

const L = window.L;
const NESDIS = 'https://cdn.star.nesdis.noaa.gov/GOES19/ABI';

// Image products (NOAA/NWS, public domain). refresh = minutes between reloads.
const IMG = (title, cat, src, link, refresh = 15, note = '') => ({ title, cat, kind: 'image', src, link, refresh, note });
export const WIDGETS = {
  // ---- local, live data ----
  now: { title: 'Current Conditions', cat: 'Your Location', size: 'm', kind: 'local' },
  alerts: { title: 'Alerts', cat: 'Your Location', size: 'm', kind: 'local' },
  nowcast: { title: 'Next 3 Hours', cat: 'Your Location', size: 'm', kind: 'local' },
  hourly: { title: 'Hourly Forecast', cat: 'Your Location', size: 'xl', kind: 'local' },
  daily: { title: '16-Day Forecast', cat: 'Your Location', size: 'l', kind: 'local' },
  details: { title: 'Conditions Detail', cat: 'Your Location', size: 'l', kind: 'local' },
  minimap: { title: 'Live Radar', cat: 'Your Location', size: 'l', kind: 'local' },
  nwsloop: { title: 'Local NWS Radar Loop', cat: 'Your Location', size: 'm', kind: 'local' },
  aqi: { title: 'Air Quality', cat: 'Your Location', size: 's', kind: 'local' },
  sun: { title: 'Sun & Moon', cat: 'Your Location', size: 's', kind: 'local' },
  nwstext: { title: 'NWS Forecast Text', cat: 'Your Location', size: 'l', kind: 'local' },
  models: { title: 'Model Comparison', cat: 'Your Location', size: 'xl', kind: 'local' },
  afd: { title: 'Forecast Discussion', cat: 'Your Location', size: 'xl', kind: 'local' },
  // ---- tropics ----
  storms: { title: 'Active Tropical Systems', cat: 'Tropics', size: 'l', kind: 'local' },
  nhc_atl7: IMG('Atlantic 7-Day Outlook', 'Tropics', 'https://www.nhc.noaa.gov/xgtwo/two_atl_7d0.png', 'https://www.nhc.noaa.gov/gtwo.php?basin=atlc&fdays=7', 30),
  nhc_atl2: IMG('Atlantic 2-Day Outlook', 'Tropics', 'https://www.nhc.noaa.gov/xgtwo/two_atl_2d0.png', 'https://www.nhc.noaa.gov/gtwo.php?basin=atlc&fdays=2', 30),
  nhc_epac7: IMG('East Pacific 7-Day Outlook', 'Tropics', 'https://www.nhc.noaa.gov/xgtwo/two_pac_7d0.png', 'https://www.nhc.noaa.gov/gtwo.php?basin=epac&fdays=7', 30),
  goes_taw: IMG('Tropical Atlantic Satellite', 'Tropics', `${NESDIS}/SECTOR/taw/GEOCOLOR/900x540.jpg`, 'https://www.star.nesdis.noaa.gov/GOES/sector.php?sat=G19&sector=taw', 10),
  goes_gm: IMG('Gulf Satellite', 'Tropics', `${NESDIS}/SECTOR/gm/GEOCOLOR/1000x1000.jpg`, 'https://www.star.nesdis.noaa.gov/GOES/sector.php?sat=G19&sector=gm', 10),
  goes_car: IMG('Caribbean Satellite', 'Tropics', `${NESDIS}/SECTOR/car/GEOCOLOR/1000x1000.jpg`, 'https://www.star.nesdis.noaa.gov/GOES/sector.php?sat=G19&sector=car', 10),
  // ---- severe ----
  spc_d1: IMG('SPC Day 1 Severe Outlook', 'Severe Weather', 'https://www.spc.noaa.gov/partners/outlooks/national/swody1.png', 'https://www.spc.noaa.gov/products/outlook/day1otlk.html', 15),
  spc_d2: IMG('SPC Day 2 Severe Outlook', 'Severe Weather', 'https://www.spc.noaa.gov/partners/outlooks/national/swody2.png', 'https://www.spc.noaa.gov/products/outlook/day2otlk.html', 30),
  spc_d3: IMG('SPC Day 3 Severe Outlook', 'Severe Weather', 'https://www.spc.noaa.gov/partners/outlooks/national/swody3.png', 'https://www.spc.noaa.gov/products/outlook/day3otlk.html', 60),
  spc_torn: IMG('SPC Day 1 Tornado Risk', 'Severe Weather', 'https://www.spc.noaa.gov/partners/outlooks/national/swody1_TORN.png', 'https://www.spc.noaa.gov/products/outlook/day1probotlk.html', 15),
  spc_ww: IMG('Active Watches', 'Severe Weather', 'https://www.spc.noaa.gov/products/watch/validww.png', 'https://www.spc.noaa.gov/products/watch/', 5),
  spc_md: IMG('Mesoscale Discussions', 'Severe Weather', 'https://www.spc.noaa.gov/products/md/validmd.png', 'https://www.spc.noaa.gov/products/md/', 5),
  // ---- radar & satellite ----
  radar_conus: IMG('US Radar Loop', 'Radar & Satellite', 'https://radar.weather.gov/ridge/standard/CONUS-LARGE_loop.gif', 'https://radar.weather.gov/', 5),
  radar_se: IMG('Southeast Radar Loop', 'Radar & Satellite', 'https://radar.weather.gov/ridge/standard/SOUTHEAST_loop.gif', 'https://radar.weather.gov/', 5),
  goes_conus: IMG('US Satellite (GeoColor)', 'Radar & Satellite', `${NESDIS}/CONUS/GEOCOLOR/1250x750.jpg`, 'https://www.star.nesdis.noaa.gov/GOES/conus.php?sat=G19', 10),
  goes_conus_loop: IMG('US Satellite Loop', 'Radar & Satellite', `${NESDIS}/CONUS/GEOCOLOR/GOES19-CONUS-GEOCOLOR-625x375.gif`, 'https://www.star.nesdis.noaa.gov/GOES/conus.php?sat=G19', 10),
  goes_se: IMG('Southeast Satellite', 'Radar & Satellite', `${NESDIS}/SECTOR/se/GEOCOLOR/1200x1200.jpg`, 'https://www.star.nesdis.noaa.gov/GOES/sector.php?sat=G19&sector=se', 10),
  goes_se_loop: IMG('Southeast Satellite Loop', 'Radar & Satellite', `${NESDIS}/SECTOR/se/GEOCOLOR/GOES19-SE-GEOCOLOR-600x600.gif`, 'https://www.star.nesdis.noaa.gov/GOES/sector.php?sat=G19&sector=se', 10),
  goes_wv: IMG('US Water Vapor', 'Radar & Satellite', `${NESDIS}/CONUS/09/1250x750.jpg`, 'https://www.star.nesdis.noaa.gov/GOES/conus.php?sat=G19', 10),
  // ---- rain & fronts ----
  wpc_sfc: IMG('Surface Analysis (Fronts)', 'Rain & Fronts', 'https://www.wpc.ncep.noaa.gov/sfc/namussfcwbg.gif', 'https://www.wpc.ncep.noaa.gov/html/sfc-zoom.php', 60),
  wpc_d1: IMG('Fronts: Tomorrow', 'Rain & Fronts', 'https://www.wpc.ncep.noaa.gov/basicwx/92fwbg.gif', 'https://www.wpc.ncep.noaa.gov/basicwx/basicwx_ndfd.php', 120),
  wpc_qpf1: IMG('Rain Forecast: Day 1', 'Rain & Fronts', 'https://www.wpc.ncep.noaa.gov/qpf/fill_94qwbg.gif', 'https://www.wpc.ncep.noaa.gov/qpf/qpf2.shtml', 120),
  wpc_qpf7: IMG('Rain Forecast: 7 Days', 'Rain & Fronts', 'https://www.wpc.ncep.noaa.gov/qpf/p168i.gif', 'https://www.wpc.ncep.noaa.gov/qpf/qpf2.shtml', 120),
  wpc_ero: IMG('Flash Flood Risk: Day 1', 'Rain & Fronts', 'https://www.wpc.ncep.noaa.gov/qpf/94ewbg.gif', 'https://www.wpc.ncep.noaa.gov/qpf/excessive_rainfall_outlook_ero.php', 120),
  // ---- outlooks ----
  cpc_610t: IMG('6-10 Day Temperature Outlook', 'Long Range', 'https://www.cpc.ncep.noaa.gov/products/predictions/610day/610temp.new.gif', 'https://www.cpc.ncep.noaa.gov/products/predictions/610day/', 360),
  cpc_610p: IMG('6-10 Day Rain Outlook', 'Long Range', 'https://www.cpc.ncep.noaa.gov/products/predictions/610day/610prcp.new.gif', 'https://www.cpc.ncep.noaa.gov/products/predictions/610day/', 360),
  cpc_814t: IMG('8-14 Day Temperature Outlook', 'Long Range', 'https://www.cpc.ncep.noaa.gov/products/predictions/814day/814temp.new.gif', 'https://www.cpc.ncep.noaa.gov/products/predictions/814day/', 360),
  cpc_814p: IMG('8-14 Day Rain Outlook', 'Long Range', 'https://www.cpc.ncep.noaa.gov/products/predictions/814day/814prcp.new.gif', 'https://www.cpc.ncep.noaa.gov/products/predictions/814day/', 360),
  // ---- links & custom ----
  links: { title: 'Weather Links', cat: 'Links & Custom', size: 'm', kind: 'local' },
  custom_image: { title: 'Custom Image or Loop', cat: 'Links & Custom', size: 'm', kind: 'custom' },
  custom_link: { title: 'Custom Link', cat: 'Links & Custom', size: 's', kind: 'custom' },
};

const DEFAULT_LAYOUT = [
  ['now', 'm'], ['alerts', 'm'], ['nowcast', 'm'], ['hourly', 'xl'], ['minimap', 'l'], ['daily', 'l'],
  ['nhc_atl7', 'm'], ['spc_d1', 'm'], ['goes_se_loop', 'm'], ['wpc_qpf7', 'm'], ['nwsloop', 'm'], ['links', 'm'],
].map(([type, size]) => ({ id: uid(), type, size }));

function uid() { return Math.random().toString(36).slice(2, 9); }
let layout = store.get('dash', null) || DEFAULT_LAYOUT;
let editing = false, ctx = {}, sortable, miniMaps = [], refreshTimer;
const SIZES = ['s', 'm', 'l', 'xl'];
const save = () => store.set('dash', layout);

export function initDashboard() {
  $('#dashEdit').onclick = () => { editing = !editing; $('#dashEdit').textContent = editing ? 'Done' : 'Customize'; $('#dashboard').classList.toggle('editing', editing); $('#dashAdd').hidden = !editing; $('#dashReset').hidden = !editing; sortable?.option('disabled', !editing); };
  $('#dashAdd').onclick = openCatalog;
  $('#dashReset').onclick = () => { if (confirmInline('#dashReset', 'Reset layout?')) { layout = DEFAULT_LAYOUT.map((w) => ({ ...w, id: uid() })); save(); render(); } };
  $('#dashGrid').addEventListener('click', onGridClick);
  if (window.Sortable) {
    sortable = window.Sortable.create($('#dashGrid'), { animation: 180, handle: '.w-head', disabled: true, ghostClass: 'w-ghost',
      onEnd: () => { const order = $$('#dashGrid > .widget').map((e) => e.dataset.id); layout.sort((a, b) => order.indexOf(a.id) - order.indexOf(b.id)); save(); } });
  }
  clearInterval(refreshTimer);
  refreshTimer = setInterval(refreshImages, 60e3);
}
// Two-click confirm without browser dialogs
function confirmInline(sel, label) {
  const b = $(sel); if (b.dataset.armed) { delete b.dataset.armed; b.textContent = 'Reset'; return true; }
  b.dataset.armed = 1; b.textContent = label; setTimeout(() => { delete b.dataset.armed; b.textContent = 'Reset'; }, 3000); return false;
}

export function updateDashboard(newCtx) { ctx = { ...ctx, ...newCtx }; if (!$('#view-dashboard').hidden) render(); }
export function showDashboard() { render(); }

function render() {
  miniMaps.forEach((m) => m.remove()); miniMaps = [];
  $('#dashGrid').innerHTML = layout.map(widgetHTML).join('');
  layout.forEach((w) => { if (w.type === 'minimap') mountMiniMap(w); });
  wireAlerts($('#dashGrid'));
}

function widgetHTML(w) {
  const def = WIDGETS[w.type]; if (!def) return '';
  const title = w.params?.title || def.title;
  const link = def.link || w.params?.link;
  return `<section class="widget w-${w.size}" data-id="${w.id}">
    <header class="w-head"><span class="w-grip" aria-hidden="true">⋮⋮</span><h3>${esc(title)}</h3>
      <div class="w-tools">${link ? `<a class="w-btn" href="${esc(link)}" target="_blank" rel="noopener" title="Open source">↗</a>` : ''}
      <button class="w-btn edit-only" data-act="size" title="Change size">${w.size.toUpperCase()}</button>
      <button class="w-btn edit-only" data-act="remove" title="Remove">✕</button></div></header>
    <div class="w-body">${bodyHTML(w, def)}</div></section>`;
}

function bodyHTML(w, def) {
  const { M, loc, models, afd } = ctx;
  if (def.kind === 'image' || w.type === 'custom_image') {
    const src = def.src || w.params?.src; const refresh = def.refresh || 10;
    return `<img class="w-img" loading="lazy" data-src="${esc(src)}" data-refresh="${refresh}" src="${esc(bust(src, refresh))}" alt="${esc(def.title || w.params?.title || '')}" onerror="this.replaceWith(Object.assign(document.createElement('div'),{className:'empty',textContent:'Image unavailable right now'}))">${def.note ? `<div class="muted small">${esc(def.note)}</div>` : ''}`;
  }
  if (w.type === 'custom_link') return `<a class="big-link" href="${esc(w.params?.link)}" target="_blank" rel="noopener">${esc(w.params?.title || w.params?.link)} ↗</a>`;
  if (w.type === 'links') return linksHTML();
  if (w.type === 'storms') return stormsHTML(ctx.storms);
  if (!M) return '<div class="empty">Loading…</div>';
  switch (w.type) {
    case 'now': return F.heroHTML(M, loc);
    case 'alerts': return `<div class="alert-list">${F.alertsHTML(M, true)}</div>`;
    case 'nowcast': return F.nowcastHTML(M);
    case 'hourly': return F.hourlyHTML(M, 48);
    case 'daily': return F.dailyHTML(M, 16);
    case 'details': return F.detailsHTML(M);
    case 'aqi': return F.aqHTML(M);
    case 'sun': return F.sunHTML(M);
    case 'nwstext': return `<div class="scroll-box">${F.nwsTextHTML(M)}</div>`;
    case 'models': return models ? F.modelsHTML(models) : '<div class="empty">Loading models…</div>';
    case 'afd': return afd === undefined ? '<div class="empty">Loading…</div>' : `<div class="scroll-box">${F.afdHTML(afd)}</div>`;
    case 'minimap': return '<div class="mini-map"></div>';
    case 'nwsloop': {
      const st = M.nws?.radar; if (!st) return '<div class="empty">Local NWS radar loops cover US locations only.</div>';
      return `<img class="w-img" data-src="https://radar.weather.gov/ridge/standard/${st}_loop.gif" data-refresh="5" src="${bust(`https://radar.weather.gov/ridge/standard/${st}_loop.gif`, 5)}" alt="${st} radar loop"><div class="muted small">Radar site ${esc(st)}</div>`;
    }
    default: return '';
  }
}
const bust = (src, min) => `${src}${src.includes('?') ? '&' : '?'}t=${Math.floor(Date.now() / (min * 60e3))}`;
function refreshImages() {
  $$('#dashGrid img.w-img').forEach((img) => { const n = bust(img.dataset.src, +img.dataset.refresh || 10); if (img.src !== n && !img.src.endsWith(n)) img.src = n; });
}

function linksHTML() {
  const office = ctx.M?.nws?.office;
  const links = [
    office && ['Your NWS Office', `https://www.weather.gov/${office.toLowerCase()}`],
    ['National Hurricane Center', 'https://www.nhc.noaa.gov/'],
    ['Storm Prediction Center', 'https://www.spc.noaa.gov/'],
    ['Weather Prediction Center', 'https://www.wpc.ncep.noaa.gov/'],
    ['Tropical Tidbits (models, spaghetti)', 'https://www.tropicaltidbits.com/'],
    ['Pivotal Weather (models)', 'https://www.pivotalweather.com/'],
    ['College of DuPage Models', 'https://weather.cod.edu/forecast/'],
    ['GOES Satellite Viewer', 'https://www.star.nesdis.noaa.gov/GOES/'],
    ['Mike\'s Weather Page', 'https://www.mikesweatherpage.com/'],
    ['Windy', 'https://www.windy.com/'],
  ].filter(Boolean);
  return `<div class="link-list">${links.map(([t, u]) => `<a href="${u}" target="_blank" rel="noopener">${esc(t)}<span>↗</span></a>`).join('')}</div>`;
}

function stormsHTML(storms) {
  if (!storms) return '<div class="empty">Loading tropical data…</div>';
  if (!storms.length) return '<div class="empty ok">✓ No active tropical systems right now.</div><img class="w-img" data-src="https://www.nhc.noaa.gov/xgtwo/two_atl_7d0.png" data-refresh="30" src="' + bust('https://www.nhc.noaa.gov/xgtwo/two_atl_7d0.png', 30) + '" alt="NHC Atlantic outlook">';
  return storms.map((s) => {
    const n = s.id?.slice(2, 4), basin = s.id?.slice(0, 2).toUpperCase(), yr = s.id?.slice(4);
    const code = `${basin}${n}${yr}`;
    const cone = `https://www.nhc.noaa.gov/storm_graphics/${basin}${n}/${code}_5day_cone_with_line_and_wind.png`;
    const mph = Math.round((s.intensity || 0) * 1.15078);
    return `<div class="storm"><h4>${esc(s.classification === 'HU' ? 'Hurricane' : s.classification === 'TS' ? 'Tropical Storm' : 'Tropical System')} ${esc(s.name)}</h4>
      <div class="muted small">${mph} mph · ${esc(s.pressure)} mb · Updated ${esc(s.lastUpdate ? new Date(s.lastUpdate).toLocaleString() : '')}</div>
      <img class="w-img" data-src="${cone}" data-refresh="30" src="${bust(cone, 30)}" alt="${esc(s.name)} forecast cone">
      <div class="link-row"><a href="https://www.nhc.noaa.gov/" target="_blank" rel="noopener">NHC advisory ↗</a><a href="https://www.tropicaltidbits.com/storminfo/" target="_blank" rel="noopener">Spaghetti models ↗</a></div></div>`;
  }).join('');
}

function mountMiniMap(w) {
  const el = $(`.widget[data-id="${w.id}"] .mini-map`); if (!el || !ctx.loc) return;
  const m = L.map(el, { zoomControl: false, attributionControl: false, scrollWheelZoom: false }).setView([ctx.loc.lat, ctx.loc.lon], 7);
  const dark = document.documentElement.dataset.theme !== 'light';
  L.tileLayer(dark ? TILES.dark : TILES.light, { subdomains: 'abcd' }).addTo(m);
  L.tileLayer(`https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/nexrad-n0q-900913/{z}/{x}/{y}.png?_=${Math.floor(Date.now() / 300e3)}`, { opacity: 0.8, maxNativeZoom: 12 }).addTo(m);
  L.tileLayer(dark ? TILES.darkLabels : TILES.lightLabels, { subdomains: 'abcd' }).addTo(m);
  L.circleMarker([ctx.loc.lat, ctx.loc.lon], { radius: 6, color: '#fff', weight: 2, fillColor: '#38bdf8', fillOpacity: 1 }).addTo(m);
  el.addEventListener('dblclick', () => location.hash = '#radar');
  miniMaps.push(m);
}

function onGridClick(e) {
  const b = e.target.closest('[data-act]'); const wEl = e.target.closest('.widget');
  if (b && wEl) {
    const w = layout.find((x) => x.id === wEl.dataset.id);
    if (b.dataset.act === 'remove') layout = layout.filter((x) => x !== w);
    if (b.dataset.act === 'size') w.size = SIZES[(SIZES.indexOf(w.size) + 1) % SIZES.length];
    save(); render(); return;
  }
  const img = e.target.closest('img.w-img');
  if (img && !editing) window.dispatchEvent(new CustomEvent('lightbox', { detail: { src: img.src, alt: img.alt } }));
}
function wireAlerts(root) {
  $$('[data-alert]', root).forEach((b) => b.onclick = () => window.dispatchEvent(new CustomEvent('show-alert', { detail: ctx.M.alerts[+b.dataset.alert] })));
}

// ---------- add-widget catalog ----------
function openCatalog() {
  const cats = {};
  for (const [id, d] of Object.entries(WIDGETS)) (cats[d.cat] ||= []).push([id, d]);
  const used = new Set(layout.map((w) => w.type));
  const html = `<div class="catalog">${Object.entries(cats).map(([c, list]) => `<h4>${esc(c)}</h4><div class="cat-grid">${list.map(([id, d]) => `
    <button class="cat-item${used.has(id) && d.kind !== 'custom' ? ' used' : ''}" data-add="${id}"><b>${esc(d.title)}</b><span>${used.has(id) && d.kind !== 'custom' ? 'On dashboard · add another' : 'Add'}</span></button>`).join('')}</div>`).join('')}
    <div id="customForm" hidden class="custom-form"><h4>Custom widget</h4>
      <label>Title<input id="cfTitle" placeholder="e.g. Euro ensemble"></label>
      <label id="cfSrcL">Image or GIF address<input id="cfSrc" placeholder="https://…/image.png"></label>
      <label>Click-through link (optional)<input id="cfLink" placeholder="https://…"></label>
      <button class="btn" id="cfSave">Add to dashboard</button></div></div>`;
  window.dispatchEvent(new CustomEvent('modal', { detail: { title: 'Add a widget', html } }));
  $$('[data-add]').forEach((b) => b.onclick = () => {
    const type = b.dataset.add, d = WIDGETS[type];
    if (d.kind === 'custom') {
      $('#customForm').hidden = false; $('#cfSrcL').hidden = type === 'custom_link'; $('#customForm').scrollIntoView({ behavior: 'smooth' });
      $('#cfSave').onclick = () => {
        const params = { title: $('#cfTitle').value.trim(), src: $('#cfSrc').value.trim(), link: $('#cfLink').value.trim() };
        if (type === 'custom_image' && !/^https:\/\//.test(params.src)) return toast('Enter an image address starting with https://');
        if (type === 'custom_link' && !/^https?:\/\//.test(params.link)) return toast('Enter a link starting with https://');
        add(type, params);
      };
      return;
    }
    add(type);
  });
}
function add(type, params) {
  layout.push({ id: uid(), type, size: WIDGETS[type].size || 'm', params });
  save(); render(); window.dispatchEvent(new CustomEvent('modal-close'));
  toast(`Added ${params?.title || WIDGETS[type].title}`);
  setTimeout(() => $('#dashGrid > .widget:last-child')?.scrollIntoView({ behavior: 'smooth', block: 'center' }), 50);
}
