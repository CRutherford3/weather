// DopplerIQ accounts: email-code sign-in, Stripe checkout, manage subscription.
// The account API runs on the doppleriq-api site so the website and the apps share one set of accounts.
import { store, $, esc, openSheet, closeSheet, toast } from './util.js';
import { ACCOUNT_API } from './config.js';

const tok = () => store.get('acctToken', null);
export const account = () => (tok() ? store.get('acct', null) : null);
export const signedIn = () => !!account();

function setAcct(a) {
  store.set('acct', a);
  window.dispatchEvent(new CustomEvent('account', { detail: a }));
}

async function call(path, body) {
  const r = await fetch(ACCOUNT_API + path, {
    method: body ? 'POST' : 'GET',
    headers: { 'Content-Type': 'application/json', ...(tok() ? { Authorization: `Bearer ${tok()}` } : {}) },
    body: body ? JSON.stringify({ ...body, site: location.origin }) : undefined,
  });
  const d = await r.json().catch(() => ({}));
  if (r.status === 401 && d.error === 'signin') signOut(true);
  if (!r.ok) throw Object.assign(new Error(d.error || `HTTP ${r.status}`), { code: d.error });
  return d;
}

export async function refreshAccount() {
  if (!tok()) return null;
  try { const d = await call('/api/account/me'); setAcct(d.account); return d.account; } catch { return account(); }
}

export function signOut(silent) {
  store.set('acctToken', null); setAcct(null);
  if (!silent) toast('Signed out');
}

// Sign in (or create an account) with a code sent by email. then() runs after a successful sign-in.
export function openSignIn(then, reason) {
  let email = store.get('acctEmail', '');
  const step1 = () => openSheet('Sign in', `<div class="set-pad acct">
      ${reason ? `<p class="pc-reason">${esc(reason)}</p>` : ''}
      <p>Enter your email and we'll send you a 6-digit code. No password needed. New here? This creates your account.</p>
      <input class="acct-in" id="acEmail" type="email" inputmode="email" autocomplete="email" placeholder="you@example.com" value="${esc(email)}">
      <button class="btn wide" id="acSend">Email me a code</button>
      <p class="muted small">Your plan works on the DopplerIQ website and apps when you sign in with the same email.</p></div>`, (b) => {
    const inp = $('#acEmail', b), btn = $('#acSend', b);
    inp.focus();
    const go = async () => {
      email = inp.value.trim().toLowerCase();
      if (!/^[^\s@]+@[^\s@]+\.[a-z]{2,}$/i.test(email)) { toast('Enter a valid email'); return; }
      btn.disabled = true; btn.textContent = 'Sending...';
      try { await call('/api/account/start', { email }); store.set('acctEmail', email); step2(); }
      catch { btn.disabled = false; btn.textContent = 'Email me a code'; toast('Could not send the code. Try again.'); }
    };
    btn.onclick = go; inp.onkeydown = (e) => { if (e.key === 'Enter') go(); };
  });
  const step2 = () => openSheet('Enter your code', `<div class="set-pad acct">
      <p>We sent a 6-digit code to <b>${esc(email)}</b>. It can take a minute, and check your spam folder.</p>
      <input class="acct-in code" id="acCode" inputmode="numeric" autocomplete="one-time-code" maxlength="6" placeholder="123456">
      <button class="btn wide" id="acVerify">Sign in</button>
      <button class="btn wide ghost" id="acBack">Use a different email</button></div>`, (b) => {
    const inp = $('#acCode', b), btn = $('#acVerify', b);
    inp.focus();
    const go = async () => {
      const code = inp.value.replace(/\D/g, '');
      if (code.length !== 6) { toast('Enter the 6-digit code'); return; }
      btn.disabled = true; btn.textContent = 'Signing in...';
      try {
        const d = await call('/api/account/verify', { email, code });
        store.set('acctToken', d.token); setAcct(d.account);
        closeSheet(); toast(`Signed in as ${email}`);
        then?.();
      } catch { btn.disabled = false; btn.textContent = 'Sign in'; toast('That code did not work. Check it or send a new one.'); }
    };
    btn.onclick = go; inp.oninput = () => { if (inp.value.replace(/\D/g, '').length === 6) go(); };
    $('#acBack', b).onclick = step1;
  });
  step1();
}

const NAMES = { plus: 'Plus monthly', plusYearly: 'Plus yearly', pro: 'Pro monthly', proYearly: 'Pro yearly', pack: 'Pro Radar Pack' };

// Start checkout for: plus, plusYearly, pro, proYearly, pack
export async function buy(item, btn) {
  if (!signedIn()) { openSignIn(() => buy(item), 'Sign in first so your purchase is saved to your account.'); return; }
  const a = account();
  const subscribed = a.plan !== 'free' && ['active', 'trialing', 'past_due'].includes(a.status);
  if (item !== 'pack' && subscribed && !confirm(`Switch your subscription to ${NAMES[item]}? The price difference is charged to your card on file now.`)) return;
  const label = btn?.textContent;
  if (btn) { btn.disabled = true; btn.textContent = 'Opening checkout...'; }
  try {
    const d = await call('/api/account/checkout', { item });
    if (d.url) { location.href = d.url; return; }
    if (d.upgraded) { setAcct(d.account); closeSheet(); toast(`You're now on ${NAMES[item]}`); }
  } catch (e) {
    toast(e.code === 'owned' ? 'You already own the Radar Pack.' : e.code === 'current' ? 'That is already your plan.' : 'Checkout could not start. Please try again.');
  }
  if (btn) { btn.disabled = false; btn.textContent = label; }
}

// Stripe customer portal: cancel, change card, switch billing, receipts
export async function manage() {
  try { const d = await call('/api/account/portal', {}); location.href = d.url; }
  catch { toast('Could not open your billing page. Try again.'); }
}

// Coming back from Stripe Checkout (?billing=success / cancel)
export async function handleReturn() {
  const q = new URLSearchParams(location.search);
  const b = q.get('billing');
  if (!b) { refreshAccount(); return; }
  q.delete('billing');
  history.replaceState(null, '', location.pathname + (q.toString() ? `?${q}` : '') + location.hash);
  if (b !== 'success') { refreshAccount(); return; }
  toast('Thanks! Unlocking your plan...', 6000);
  const before = JSON.stringify(account());
  for (let i = 0; i < 8; i++) { // the payment webhook can take a few seconds
    const a = await refreshAccount();
    if (JSON.stringify(a) !== before) { toast(`You're all set: DopplerIQ ${a.radarPack && a.plan === 'free' ? 'Radar Pack' : a.plan === 'pro' ? 'Pro' : 'Plus'} is unlocked.`); return; }
    await new Promise((r) => setTimeout(r, 2000));
  }
  toast('Payment received. If your plan does not unlock in a minute, reload the page.', 8000);
}
