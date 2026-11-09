// Subscription tiers, feature gating and ad slots.
// Plans live in this browser for now. Real billing needs accounts + Stripe webhooks (next phase).
import { store, $, $$, esc, openSheet, toast } from './util.js';
import { ADS, CHECKOUT } from './config.js';

export const TIERS = {
  free: { name: 'Free', price: '$0', blurb: 'Radar, forecasts and alerts, with ads', features: ['Live radar and satellite', 'Forecasts and NWS alerts', 'Fronts and NHC tropical outlooks', 'Storm reports and outlooks', 'Dashboard with 1 page'] },
  plus: { name: 'Plus', price: '$2.99', per: '/mo', blurb: 'No ads, every map layer', features: ['Everything in Free, no ads', 'Hurricane tracker with live cones, tracks and spaghetti plots', 'All map layers: winds, temps, lightning, rain totals, air quality, hail', 'Dashboard with 5 pages', 'Severe alerts for saved places (apps)'] },
  pro: { name: 'Pro', price: '$9.99', per: '/mo', blurb: 'For storm chasers, drivers and pros', features: ['Everything in Plus', 'Route weather planner, including EV charging stops', 'Hail history at any address', 'Marine & offshore: live buoys, seas and swell forecast, tides, NWS marine forecast', 'Live US traffic layer', 'Doppler radar: pick any NEXRAD site on the map or dashboard, reflectivity or velocity', 'Unlimited dashboard pages and pro layouts', '50+ extra pro maps: tropical analysis, ocean heat, surface analyses, storm-top satellite, forecast maps, climatology', 'iPad and Mac pro workspace'] },
};
const RANK = { free: 0, plus: 1, pro: 2 };
export const LAYER_TIER = { winds: 'plus', temps: 'plus', aqi: 'plus', rain: 'plus', lightning: 'plus', drought: 'plus', hail: 'plus', tropics: 'plus', traffic: 'pro', sites: 'pro', buoys: 'pro', waves: 'pro', sst: 'pro', charts: 'pro', rigs: 'pro', cams: 'pro' };
export const FEATURE_TIER = { route: 'pro', ev: 'pro', hailHistory: 'pro', hurricanes: 'plus', marine: 'pro', proLayouts: 'pro', noAds: 'plus' };
export const PAGE_LIMIT = { free: 1, plus: 5, pro: 99 };

// Test site: pro.weather.dialcheck.io always runs as Pro
const FORCED = /^pro\./.test(location.hostname) ? 'pro' : null;
export const plan = () => FORCED ||  (RANK[store.get('plan', 'free')] != null ? store.get('plan', 'free') : 'free');
export const has = (tier = 'free') => RANK[plan()] >= RANK[tier];
export const canLayer = (id) => has(LAYER_TIER[id]);
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
  const card = (k) => { const t = TIERS[k];
    return `<div class="price-card${k === 'pro' ? ' hot' : ''}${cur === k ? ' cur' : ''}">
      <div class="pc-head"><b>${t.name}</b>${k === 'pro' ? '<span class="pc-pop">Best value</span>' : ''}</div>
      <div class="pc-price">${t.price}<small>${t.per || ''}</small></div><p class="muted small">${esc(t.blurb)}</p>
      <ul>${t.features.map((f) => `<li>${esc(f)}</li>`).join('')}</ul>
      ${k === 'free' ? '' : `<button class="btn wide${cur === k ? ' ghost' : ''}" data-buy="${k}">${cur === k ? 'Current plan' : `Get ${t.name}`}</button>`}</div>`; };
  openSheet('Updraft plans', `${reason ? `<div class="pc-reason">${esc(reason)}</div>` : ''}<div class="price-grid">${['free', 'plus', 'pro'].map(card).join('')}</div>
    <p class="muted small sheet-foot">Cancel any time. On iPhone, iPad and Mac, plans are billed through the App Store.</p>`, (b) => {
    $$('[data-buy]', b).forEach((x) => x.onclick = () => {
      const k = x.dataset.buy; if (plan() === k) return;
      if (CHECKOUT[k]) { window.open(CHECKOUT[k], '_blank', 'noopener'); return; }
      toast('Checkout is not connected yet. Use Settings → Preview plan to try it.');
    });
  });
}

// Gate helper: returns true if allowed, otherwise opens pricing.
export function gate(feature, label) {
  if (has(tierOf(feature))) return true;
  openPricing(`${label} is part of Updraft ${TIERS[tierOf(feature)].name}.`);
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
      el.innerHTML = `<span class="ad-label">Advertisement</span><button class="house-ad" data-house><b>Go ad-free with Updraft Plus</b><span>Every map layer, no ads. $2.99/mo</span></button>`;
      $('[data-house]', el).onclick = () => openPricing();
    }
  });
}
