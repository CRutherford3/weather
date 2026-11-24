import type { Config } from "@netlify/functions";
// @ts-ignore plain JS module
import * as B from "../../lib/billing.mjs";

// DopplerIQ accounts and checkout. Used by the website and (later) the iPhone, iPad, Mac and Android apps.
//   POST /api/account/start     { email }          -> emails a 6-digit code
//   POST /api/account/verify    { email, code }    -> { token, account }
//   GET  /api/account/me        (Bearer token)     -> { account }
//   POST /api/account/checkout  { item, site }     -> { url } Stripe Checkout, or { upgraded: true } when switching plans
//   POST /api/account/portal    { site }           -> { url } Stripe customer portal (cancel, change card, receipts)
export default async (req: Request) => {
  const origin = B.allowedOrigin(req.headers.get("origin"));
  const cors: Record<string, string> = origin
    ? { "Access-Control-Allow-Origin": origin, "Access-Control-Allow-Headers": "Content-Type, Authorization", "Access-Control-Allow-Methods": "GET, POST, OPTIONS", Vary: "Origin" }
    : {};
  const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...cors } });
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });

  const action = new URL(req.url).pathname.split("/").pop();
  const body: any = req.method === "POST" ? await req.json().catch(() => ({})) : {};
  // Where to send people back after Stripe: the site they came from, if it's one of ours
  const site = B.allowedOrigin(body.site) || origin || B.DEFAULT_SITE;

  try {
    if (action === "start") {
      const email = B.normEmail(body.email);
      if (!B.validEmail(email)) return json({ error: "bad_email" }, 400);
      const r = await B.startSignIn(email);
      return json(r, r.ok ? 200 : 502);
    }
    if (action === "verify") {
      const email = B.normEmail(body.email);
      const token = await B.finishSignIn(email, body.code);
      if (!token) return json({ error: "bad_code" }, 401);
      return json({ token, account: B.publicAccount(await B.getAccount(email)) });
    }

    const email = B.readToken(req);
    if (!email) return json({ error: "signin" }, 401);
    const a = await B.getAccount(email);

    if (action === "me") return json({ account: B.publicAccount(a) });

    if (action === "checkout") {
      const id = String(body.item || "");
      const it = B.ITEMS[id];
      if (!it) return json({ error: "bad_item" }, 400);
      const s = B.stripe();
      const price = await B.priceFor(id);

      if (id === "pack") {
        if (a.radarPack) return json({ error: "owned" }, 409);
        const session = await s.checkout.sessions.create({
          mode: "payment",
          line_items: [{ price, quantity: 1 }],
          ...(a.customerId ? { customer: a.customerId } : { customer_email: email, customer_creation: "always" }),
          metadata: { app: "doppleriq", email, item: id },
          payment_intent_data: { metadata: { app: "doppleriq", email, item: id } },
          success_url: `${site}/?billing=success`,
          cancel_url: `${site}/?billing=cancel`,
        });
        return json({ url: session.url });
      }

      // Already subscribed: switch the existing subscription instead of starting a second one
      const live = a.subId && ["active", "trialing", "past_due"].includes(a.subStatus);
      if (live) {
        const sub = await s.subscriptions.retrieve(a.subId);
        const cur = sub.items.data[0];
        if (cur.price.id === price) return json({ error: "current" }, 409);
        const updated = await s.subscriptions.update(a.subId, {
          items: [{ id: cur.id, price }],
          proration_behavior: "always_invoice",
          cancel_at_period_end: false,
          metadata: { ...sub.metadata, item: id, tier: it.tier },
        });
        await B.applySubscription(updated);
        return json({ upgraded: true, account: B.publicAccount(await B.getAccount(email)) });
      }

      const session = await s.checkout.sessions.create({
        mode: "subscription",
        line_items: [{ price, quantity: 1 }],
        ...(a.customerId ? { customer: a.customerId } : { customer_email: email }),
        metadata: { app: "doppleriq", email, item: id },
        subscription_data: {
          metadata: { app: "doppleriq", email, item: id, tier: it.tier },
          ...(it.trial && !a.hadTrial ? { trial_period_days: it.trial } : {}),
        },
        allow_promotion_codes: true,
        success_url: `${site}/?billing=success`,
        cancel_url: `${site}/?billing=cancel`,
      });
      return json({ url: session.url });
    }

    if (action === "portal") {
      if (!a.customerId) return json({ error: "no_customer" }, 404);
      const p = await B.stripe().billingPortal.sessions.create({ customer: a.customerId, return_url: `${site}/` });
      return json({ url: p.url });
    }

    return json({ error: "not_found" }, 404);
  } catch (e: any) {
    console.log("account error", action, e?.message);
    return json({ error: "server", message: e?.message }, 500);
  }
};

export const config: Config = {
  path: ["/api/account/start", "/api/account/verify", "/api/account/me", "/api/account/checkout", "/api/account/portal"],
  rateLimit: { action: "rate_limit", aggregateBy: ["ip", "domain"], windowSize: 60, windowLimit: 30 },
};
