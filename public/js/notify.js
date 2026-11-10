// Plus: browser notifications for saved places while DopplerIQ is open in a tab.
// - New NWS warnings (tornado, severe thunderstorm, flash flood, and other warnings) for any saved place or your location
// - "Rain starting soon" for your location, from the 15-minute forecast
// The iPhone, iPad and Mac apps do the same in the background.
import { store, getData, toast } from './util.js';
import { has } from './plan.js';

const NWS = { headers: { Accept: 'application/geo+json' } };
const SEVERE = /Tornado|Severe Thunderstorm|Flash Flood|Hurricane|Tropical Storm|Storm Surge|Extreme Wind|Blizzard|Ice Storm|Winter Storm Warning|Extreme Heat Warning|Extreme Cold Warning|Special Marine/;
let timer = null, getPlaces = () => [], getHere = () => null;

export const enabled = () => !!store.get('notify', false) && has('plus') && 'Notification' in window && Notification.permission === 'granted';

export async function setEnabled(on) {
  if (!on) { store.set('notify', false); stop(); return false; }
  if (!('Notification' in window)) { toast('This browser does not support notifications'); return false; }
  const p = Notification.permission === 'granted' ? 'granted' : await Notification.requestPermission();
  if (p !== 'granted') { toast('Notifications are blocked for this site in your browser settings'); return false; }
  store.set('notify', true); start(); check();
  return true;
}

export function initNotify(places, here) {
  getPlaces = places; getHere = here;
  if (enabled()) start();
  window.addEventListener('plan', () => (enabled() ? start() : stop()));
}
function start() { stop(); timer = setInterval(check, 3 * 60e3); setTimeout(check, 4000); }
function stop() { clearInterval(timer); timer = null; }

const seen = () => new Set(store.get('notifySeen', []));
function remember(ids) { store.set('notifySeen', [...ids].slice(-300)); }
function show(title, body, tag) {
  try { const n = new Notification(title, { body, tag, icon: '/icons/icon.svg' }); n.onclick = () => { window.focus(); n.close(); }; } catch { /* some browsers need a service worker */ }
}

export async function check() {
  if (!enabled()) return;
  const places = [...getPlaces()];
  const here = getHere();
  if (here && !places.some((p) => Math.abs(p.lat - here.lat) < 0.02 && Math.abs(p.lon - here.lon) < 0.02)) places.unshift({ ...here, name: here.name || 'Your location' });
  const ids = seen();
  for (const p of places.slice(0, 10)) {
    try {
      const j = await getData(`https://api.weather.gov/alerts/active?point=${(+p.lat).toFixed(4)},${(+p.lon).toFixed(4)}`, { ...NWS, cache: 60e3 });
      for (const f of j.features || []) {
        const a = f.properties; if (!SEVERE.test(a.event) || ids.has(a.id)) continue;
        ids.add(a.id);
        show(`${a.event} · ${p.name}`, a.headline || a.description?.slice(0, 160) || '', a.id);
      }
    } catch { /* try again next round */ }
  }
  // Rain starting within 30 minutes at your location (once per dry spell)
  if (here) {
    try {
      const j = await getData(`https://api.open-meteo.com/v1/forecast?latitude=${here.lat}&longitude=${here.lon}&minutely_15=precipitation&forecast_minutely_15=3&past_minutely_15=1`, { cache: 5 * 60e3 });
      const pr = j.minutely_15?.precipitation || [];
      const now = pr[0] || 0, soon = pr.slice(1).findIndex((x) => x >= 0.1);
      const wasRaining = store.get('notifyRain', false);
      if (now < 0.1 && soon >= 0 && !wasRaining) { show(`Rain starting soon · ${here.name || 'your location'}`, `Rain is expected within about ${(soon + 1) * 15} minutes.`, 'rain'); store.set('notifyRain', true); }
      if (now < 0.1 && soon < 0) store.set('notifyRain', false);
    } catch { /* ignore */ }
  }
  remember(ids);
}
