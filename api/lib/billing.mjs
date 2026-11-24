// DopplerIQ accounts and billing (Stripe). Runs in Netlify functions on the doppleriq-api site.
// Accounts are keyed by email and stored in Netlify Blobs ("accounts"). Sign-in is a 6-digit email code.
// Env vars (doppleriq-api site): STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, AUTH_SECRET, RESEND_API_KEY, EMAIL_FROM
import { getStore } from '@netlify/blobs';
import Stripe from 'stripe';
import { createHmac, createHash, randomInt, timingSafeEqual } from 'node:crypto';

const env = (k) => (globalThis.Netlify?.env?.get(k) ?? process.env[k] ?? '');

// Prices in cents. Products and prices are created in Stripe automatically the first time they're needed.
export const ITEMS = {
  plus: { tier: 'plus', name: 'DopplerIQ Plus (monthly)', amount: 299, interval: 'month' },
  plusYearly: { tier: 'plus', name: 'DopplerIQ Plus (yearly)', amount: 2499, interval: 'year', trial: 7 },
  pro: { tier: 'pro', name: 'DopplerIQ Pro (monthly)', amount: 999, interval: 'month' },
  proYearly: { tier: 'pro', name: 'DopplerIQ Pro (yearly)', amount: 5999, interval: 'year', trial: 7 },
  pack: { name: 'DopplerIQ Pro Radar Pack', amount: 699 },
};
const RANK = { free: 0, plus: 1, pro: 2 };

// Websites allowed to call the account API from a browser.
const ORIGINS = [/^https:\/\/([a-z0-9-]+\.)*dialcheck\.io$/, /^https:\/\/doppleriq-api\.netlify\.app$/, /^http:\/\/localhost(:\d+)?$/];
export const allowedOrigin = (o) => (o && ORIGINS.some((r) => r.test(o)) ? o : '');
export const DEFAULT_SITE = 'https://weather.dialcheck.io';

let _stripe;
export const stripe = () => (_stripe ||= new Stripe(env('STRIPE_SECRET_KEY')));
const accounts = () => getStore({ name: 'accounts', consistency: 'strong' });
const codes = () => getStore({ name: 'signin-codes', consistency: 'strong' });

export const normEmail = (e) => String(e || '').trim().toLowerCase();
export const validEmail = (e) => /^[^\s@]{1,64}@[^\s@]{1,190}\.[a-z]{2,}$/i.test(e);
const key = (email) => createHash('sha256').update(email).digest('hex');

export async function getAccount(email) {
  return (await accounts().get(key(email), { type: 'json' })) || { email, plan: 'free', radarPack: false };
}
export async function saveAccount(a) { a.updated = Date.now(); await accounts().setJSON(key(a.email), a); return a; }

// ---------- sign-in tokens (HMAC signed, 180 days) ----------
const b64u = (s) => Buffer.from(s).toString('base64url');
const sign = (s) => createHmac('sha256', env('AUTH_SECRET')).update(s).digest('base64url');
export function makeToken(email) {
  const body = b64u(JSON.stringify({ e: email, x: Date.now() + 180 * 864e5 }));
  return `${body}.${sign(body)}`;
}
export function readToken(req) {
  const h = req.headers.get('authorization') || '';
  const t = h.startsWith('Bearer ') ? h.slice(7) : '';
  const [body, sig] = t.split('.');
  if (!body || !sig || !env('AUTH_SECRET')) return null;
  const want = Buffer.from(sign(body)), got = Buffer.from(sig);
  if (want.length !== got.length || !timingSafeEqual(want, got)) return null;
  try { const { e, x } = JSON.parse(Buffer.from(body, 'base64url').toString()); return x > Date.now() ? e : null; } catch { return null; }
}

// ---------- email codes ----------
export async function startSignIn(email) {
  const prev = await codes().get(key(email), { type: 'json' });
  if (prev && Date.now() - prev.sent < 30e3) return { ok: true }; // don't resend within 30 seconds
  const code = String(randomInt(0, 1e6)).padStart(6, '0');
  await codes().setJSON(key(email), { h: sign(`${email}:${code}`), exp: Date.now() + 15 * 6e4, tries: 0, sent: Date.now() });
  const r = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${env('RESEND_API_KEY')}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      from: env('EMAIL_FROM') || 'DopplerIQ <signin@dialcheck.io>',
      to: [email],
      subject: `${code} is your DopplerIQ sign-in code`,
      text: `Your DopplerIQ sign-in code is ${code}\n\nIt expires in 15 minutes. If you didn't ask for this, you can ignore this email.`,
      html: `<div style="font-family:system-ui,sans-serif;font-size:16px"><p>Your DopplerIQ sign-in code is</p><p style="font-size:32px;font-weight:700;letter-spacing:6px">${code}</p><p style="color:#666">It expires in 15 minutes. If you didn't ask for this, you can ignore this email.</p></div>`,
    }),
  });
  if (!r.ok) { console.log('email failed', r.status, await r.text()); return { ok: false, error: 'email_failed' }; }
  return { ok: true };
}
export async function finishSignIn(email, code) {
  const c = await codes().get(key(email), { type: 'json' });
  if (!c || c.exp < Date.now() || c.tries >= 5) return null;
  if (sign(`${email}:${String(code).trim()}`) !== c.h) { c.tries++; await codes().setJSON(key(email), c); return null; }
  await codes().delete(key(email));
  const a = await getAccount(email);
  if (!a.created) { a.created = Date.now(); await saveAccount(a); }
  return makeToken(email);
}

// ---------- Stripe prices (found by lookup key, created on first use) ----------
export async function priceFor(id) {
  const it = ITEMS[id];
  const lookup = `doppleriq_${id}_${it.amount}`;
  const s = stripe();
  const found = await s.prices.list({ lookup_keys: [lookup], active: true, limit: 1 });
  if (found.data[0]) return found.data[0].id;
  const product = await s.products.create({ name: it.name, metadata: { app: 'doppleriq', item: id } });
  const price = await s.prices.create({ product: product.id, currency: 'usd', unit_amount: it.amount, lookup_key: lookup,
    ...(it.interval ? { recurring: { interval: it.interval } } : {}), metadata: { app: 'doppleriq', item: id } });
  return price.id;
}

// What the apps and website get back for a signed-in user.
export const publicAccount = (a) => ({
  email: a.email, plan: a.plan || 'free', radarPack: !!a.radarPack,
  status: a.subStatus || null, interval: a.interval || null, renews: a.periodEnd || null, cancelAt: a.cancelAt || null,
  manage: !!a.customerId,
});

// Apply a Stripe subscription to its account.
export async function applySubscription(sub) {
  const email = normEmail(sub.metadata?.email);
  if (!email) return;
  const a = await getAccount(email);
  const item = sub.items?.data?.[0];
  const id = item?.price?.metadata?.item || sub.metadata?.item;
  const tier = ITEMS[id]?.tier || sub.metadata?.tier || 'plus';
  const live = ['active', 'trialing', 'past_due'].includes(sub.status);
  // A newer subscription wins; ignore events for an old one we've already replaced
  if (a.subId && a.subId !== sub.id && !live) return;
  a.customerId = typeof sub.customer === 'string' ? sub.customer : sub.customer?.id || a.customerId;
  a.subId = sub.id;
  a.subStatus = sub.status;
  a.plan = live ? tier : 'free';
  a.interval = item?.price?.recurring?.interval || null;
  a.periodEnd = (item?.current_period_end || sub.current_period_end || 0) * 1000 || null;
  a.cancelAt = sub.cancel_at ? sub.cancel_at * 1000 : null;
  if (sub.trial_start) a.hadTrial = true;
  await saveAccount(a);
}

export const rank = (p) => RANK[p] ?? 0;
