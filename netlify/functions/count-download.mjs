import { getStore } from "@netlify/blobs";

// One empty blob per download, keyed by its timestamp (plus a random suffix
// so two clicks in the same millisecond don't collide). Nothing about the
// visitor is stored — the key is the whole record. Count = number of keys.
export default async (req) => {
  if (req.method !== "POST") return new Response(null, { status: 405 });
  const key = new Date().toISOString() + "-" + crypto.randomUUID().slice(0, 8);
  await getStore("downloads").set(key, "");
  return new Response(null, { status: 204 });
};

// The endpoint is public, so cap how fast any one visitor can bump it.
// Netlify enforces this at its edge (excess requests get a 429) — the IP
// is used only for that check and is never written to the store.
export const config = {
  path: "/api/count-download",
  rateLimit: { windowLimit: 5, windowSize: 60, aggregateBy: ["ip", "domain"] },
};
