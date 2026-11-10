// Subscription tiers, feature gating and ad slots.
// Plans live in this browser for now. Real billing needs accounts + Stripe webhooks (next phase).
import { store, $, $$, esc, openSheet, toast } from './util.js';
import { ADS, CHECKOUT } from './config.js';

export const TIERS = {
  free: { name: 'Free', price: '$0', blurb: 'Radar, forecasts and alerts, with ads', features: ['Live radar and satellite', 'Forecasts and NWS alerts', 'Fronts and NHC tropical outlooks', 'Storm reports and outlooks', 'Dashboard with 1 page'] },
  plus: { name: 'Plus', price: '$2.99', per: '/mo', year: '$24.99', blurb: 'No ads, every map layer', features: ['Everything in Free, no ads', 'Hurricane tracker with live cones, tracks and spaghetti plots', 'All map layers: winds, temps, lightning, rain totals, rain rate, echo tops, road weather, air quality, hail', 'Dashboard with 5 pages', 'Severe weather and rain alerts for saved places'] },
  pro: { name: 'Pro', price: '$9.99', per: '/mo', year: '$59.99', blurb: 'For storm chasers, drivers and pros', features: ['Everything in Plus', 'Route weather planner, including EV charging stops', 'Hail history at any address', 'Marine & offshore: live buoys, seas and swell forecast, tides, NWS marine forecast', 'Live US traffic layer', 'Power outages map (partial US coverage, growing)', 'Doppler radar at any NEXRAD site: reflectivity and velocity at 4 tilts, dual-pol (hail and debris, precip type), VIL and echo tops', 'Unlimited dashboard pages and pro layouts', '50+ extra pro maps: tropical analysis, ocean heat, surface analyses, storm-top satellite, forecast maps, climatology', 'iPad and Mac pro workspace'] },
};
const RANK = { free: 0, plus: 1, pro: 2 };
export const LAYER_TIER = { rainrate: 'plus', echotops: 'plus', road: 'plus', winds: 'plus', temps: 'plus', aqi: 'plus', rain: 'plus', lightning: 'plus', drought: 'plus', hail: 'plus', tropics: 'plus', traffic: 'pro', outages: 'pro', twoutlook: 'plus', windprob: 'plus', surgerisk: 'plus', snowprob: 'plus', snowcover: 'plus', sites: 'pro', buoys: 'pro', waves: 'pro', sst: 'pro', charts: 'pro', rigs: 'pro', cams: 'pro', iss: 'pro' };
export const FEATURE_TIER = { route: 'pro', ev: 'pro', hailHistory: 'pro', hurricanes: 'plus', marine: 'pro', proLayouts: 'pro', noAds: 'plus' };
// One-time Pro Radar Pack: Doppler radar features only (not every layer), so it never undercuts a subscription.
export const RADAR_PACK = { name: 'Pro Radar Pack', price: '$6.99', blurb: 'One-time purchase. Any NEXRAD site, 4 tilts, velocity, dual-pol, VIL and echo tops. Yours forever.' };
export const TRIAL_DAYS = 7; // free trial on yearly plans (App Store introductory offer)
export const PAGE_LIMIT = { free: 1, plus: 5, pro: 99 };

// Test site: pro.weather.dialcheck.io always runs as Pro
const FORCED = /^pro\./.test(location.hostname) ? 'pro' : null;
const PACK_LAYERS = new Set(['sites']);
export const hasRadarPack = () => !!store.get('radarPack', false);
export const plan = () => FORCED ||  (RANK[store.get('plan', 'free')] != null ? store.get('plan', 'free') : 'free');
export const has = (tier = 'free') => RANK[plan()] >= RANK[tier];
export const canLayer = (id) => has(LAYER_TIER[id]) || (PACK_LAYERS.has(id) && hasRadarPack());
export const can = (f) => has(FEATURE_TIER[f]);
export const tierOf = (id) => LAYER_TIER[id] || FEATURE_TIER[id] || 'free';
export const badge = (tier) => (tier && tier !== 'free' ? `<span class="tier-badge t-${tier}">${tier.toUpperCase()}</span>` : '');

export function setPlan(p) {
  store.set('plan', p); document.body.dataset.plan = p;
  window.dispatchEvent(new CustomEvent('plan', { detail: p }));
  fillAds(document);
}

// Pricing sheet. reason = what the user tried to open.
export function openPricing(reason) {
  const cur = plan();
  let yearly = store.get('billYearly', true);
  const save = (t) => { const m = parseFloat(t.price.slice(1)) * 12, y = parseFloat(t.year.slice(1)); return Math.round((1 - y / m) * 100); };
  const card = (k) => { const t = TIERS[k];
    const price = k === 'free' ? t.price : yearly ? t.year : t.price;
    const per = k === 'free' ? '' : yearly ? '/yr' : t.per;
    const sub = k === 'free' ? '' : yearly ? `<div class="pc-sub">About $${(parseFloat(t.year.slice(1)) / 12).toFixed(2)}/mo · save ${save(t)}% · ${TRIAL_DAYS}-day free trial</div>` : `<div class="pc-sub">or ${t.year}/yr and save ${save(t)}%</div>`;
    return `<div class="price-card${k === 'pro' ? ' hot' : ''}${cur === k ? ' cur' : ''}">
      <div class="pc-head"><b>${t.name}</b>${k === 'pro' ? '<span class="pc-pop">Best value</span>' : ''}</div>
      <div class="pc-price">${price}<small>${per}</small></div>${sub}<p class="muted small">${esc(t.blurb)}</p>
      <ul>${t.features.map((f) => `<li>${esc(f)}</li>`).join('')}</ul>
      ${k === 'free' ? '' : `<button class="btn wide${cur === k ? ' ghost' : ''}" data-buy="${k}">${cur === k ? 'Current plan' : yearly ? `Start ${TRIAL_DAYS}-day free trial` : `Get ${t.name}`}</button>`}</div>`; };
  const html = () => `${reason ? `<div class="pc-reason">${esc(reason)}</div>` : ''}
    <div class="seg pc-bill"><button data-bill="m" class="${yearly ? '' : 'on'}">Monthly</button><button data-bill="y" class="${yearly ? 'on' : ''}">Yearly <span class="pc-save">save up to 50%</span></button></div>
    <div class="price-grid">${['free', 'plus', 'pro'].map(card).join('')}</div>
    <div class="price-card pack"><div class="pc-head"><b>${RADAR_PACK.name}</b></div><div class="pc-price">${RADAR_PACK.price}<small> once</small></div><p class="muted small">${esc(RADAR_PACK.blurb)}</p>
      <button class="btn wide ghost" data-buy="pack">${hasRadarPack() ? 'Owned' : `Buy for ${RADAR_PACK.price}`}</button></div>
    <p class="muted small sheet-foot">Cancel any time. Yearly plans start with a ${TRIAL_DAYS}-day free trial. On iPhone, iPad and Mac, plans are billed through the App Store.</p>`;
  openSheet('DopplerIQ plans', html(), function wire(b) {
    $$('[data-bill]', b).forEach((x) => x.onclick = () => { yearly = x.dataset.bill === 'y'; store.set('billYearly', yearly); b.innerHTML = html(); wire(b); });
    $$('[data-buy]', b).forEach((x) => x.onclick = () => {
      const k = x.dataset.buy;
      if (k === 'pack') { if (hasRadarPack()) return; const u = CHECKOUT.pack; if (u) { window.open(u, '_blank', 'noopener'); return; } toast('Checkout is not connected yet.'); return; }
      if (plan() === k) return;
      const u = CHECKOUT[`${k}${yearly ? 'Yearly' : ''}`] || CHECKOUT[k];
      if (u) { window.open(u, '_blank', 'noopener'); return; }
      toast('Checkout is not connected yet. Use Settings → Preview plan to try it.');
    });
  });
}

// Gate helper: returns true if allowed, otherwise opens pricing.
export function gate(feature, label) {
  if (has(tierOf(feature))) return true;
  openPricing(`${label} is part of DopplerIQ ${TIERS[tierOf(feature)].name}.`);
  return false;
}

// ---------- ads ----------
// kind: banner (320x50 / 728x90), box (300x250), inline (fluid card), tall (160x600)
export const adSlot = (kind) => (has('plus') ? '' : `<div class="ad ad-${kind}" data-ad="${kind}"></div>`);
let adsLoaded = false;
export function fillAds(root = document) {
  const off = has('plus');
  $$('.ad', root).forEach((el) => {
    el.hidden = off; if (off || el.dataset.filled) return;
    el.dataset.filled = 1;
    if (ADS.client && ADS.slots[el.dataset.ad]) {
      if (!adsLoaded) { adsLoaded = true; const s = document.createElement('script'); s.async = true; s.crossOrigin = 'anonymous'; s.src = `https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js?client=${ADS.client}`; document.head.appendChild(s); }
      el.innerHTML = `<span class="ad-label">Advertisement</span><ins class="adsbygoogle" style="display:block" data-ad-client="${ADS.client}" data-ad-slot="${ADS.slots[el.dataset.ad]}" data-ad-format="auto" data-full-width-responsive="true"></ins>`;
      try { (window.adsbygoogle = window.adsbygoogle || []).push({}); } catch { /* blocked */ }
    } else {
      el.innerHTML = `<span class="ad-label">Advertisement</span><button class="house-ad" data-house><b>Go ad-free with DopplerIQ Plus</b><span>Every map layer, no ads. From $24.99/yr</span></button>`;
      $('[data-house]', el).onclick = () => openPricing();
    }
  });
}
