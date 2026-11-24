import type { Config } from "@netlify/functions";
// @ts-ignore plain JS module
import * as B from "../../lib/billing.mjs";

// Stripe tells us about payments here. Point a Stripe webhook at:
//   https://doppleriq-api.netlify.app/api/stripe-webhook
// Events: checkout.session.completed, customer.subscription.created, customer.subscription.updated,
//         customer.subscription.deleted, charge.refunded
export default async (req: Request) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });
  const secret = Netlify.env.get("STRIPE_WEBHOOK_SECRET") || "";
  const raw = await req.text();
  let event: any;
  try {
    event = await B.stripe().webhooks.constructEventAsync(raw, req.headers.get("stripe-signature") || "", secret);
  } catch (e: any) {
    return new Response(`Bad signature: ${e?.message}`, { status: 400 });
  }
  const o = event.data.object;
  // Only DopplerIQ payments (the Stripe account could be shared later)
  const ours = (m: any) => m?.app === "doppleriq";

  try {
    switch (event.type) {
      case "checkout.session.completed": {
        if (!ours(o.metadata)) break;
        const email = B.normEmail(o.metadata.email);
        const a = await B.getAccount(email);
        if (o.customer) a.customerId = typeof o.customer === "string" ? o.customer : o.customer.id;
        if (o.metadata.item === "pack" && o.payment_status === "paid") a.radarPack = true;
        await B.saveAccount(a);
        if (o.subscription) {
          const sub = await B.stripe().subscriptions.retrieve(typeof o.subscription === "string" ? o.subscription : o.subscription.id);
          await B.applySubscription(sub);
        }
        break;
      }
      case "customer.subscription.created":
      case "customer.subscription.updated":
      case "customer.subscription.deleted":
        if (ours(o.metadata)) await B.applySubscription(o);
        break;
      case "charge.refunded": {
        // A fully refunded Radar Pack is taken back
        if (!o.refunded || !o.payment_intent) break;
        const pi = await B.stripe().paymentIntents.retrieve(typeof o.payment_intent === "string" ? o.payment_intent : o.payment_intent.id);
        if (ours(pi.metadata) && pi.metadata.item === "pack") {
          const a = await B.getAccount(B.normEmail(pi.metadata.email));
          a.radarPack = false;
          await B.saveAccount(a);
        }
        break;
      }
    }
  } catch (e: any) {
    console.log("webhook error", event.type, e?.message);
    return new Response("error", { status: 500 }); // Stripe retries
  }
  return new Response("ok");
};

export const config: Config = { path: "/api/stripe-webhook" };
