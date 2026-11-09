// Plat & Plant: verstuurt elke paar minuten de meldingen die op dit moment aan de beurt zijn.
// Plak deze code in Supabase bij Edge Functions, met als naam: plat-push
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 1 });

const b64u = (buf: ArrayBuffer | Uint8Array) =>
  btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const part = (o: unknown) => b64u(new TextEncoder().encode(JSON.stringify(o)));

let signKey: CryptoKey | null = null;

// VAPID: bewijst aan Google, Apple en Mozilla dat de melding van jullie eigen app komt.
async function vapidHeader(endpoint: string, cfg: Record<string, any>) {
  if (!signKey) {
    const { kty, crv, x, y, d } = cfg.vapid_private;
    signKey = await crypto.subtle.importKey("jwk", { kty, crv, x, y, d }, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  }
  const unsigned = part({ typ: "JWT", alg: "ES256" }) + "." +
    part({ aud: new URL(endpoint).origin, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: cfg.subject });
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, signKey, new TextEncoder().encode(unsigned));
  return `vapid t=${unsigned}.${b64u(sig)}, k=${cfg.vapid_public}`;
}

const CORS = { "Access-Control-Allow-Origin": "*" };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: { ...CORS, "Access-Control-Allow-Headers": "*" } });
  try {
    const [cfg] = await sql`select * from public.push_config where id = 1`;
    if (!cfg || !cfg.vapid_private || req.headers.get("x-plat-secret") !== cfg.secret) {
      return new Response("forbidden", { status: 403, headers: CORS });
    }
    const targets = await sql`select * from public.push_targets()`;
    let sent = 0, removed = 0, failed = 0;
    for (const t of targets) {
      if (!t.due && !t.test) continue;
      // Een lege melding: de app haalt zelf op welke planten water nodig hebben.
      const r = await fetch(t.endpoint, {
        method: "POST",
        headers: { Authorization: await vapidHeader(t.endpoint, cfg), TTL: "14400", Urgency: "normal", "Content-Length": "0" }
      });
      if (r.status === 404 || r.status === 410) {
        await sql`delete from public.push_subscriptions where id = ${t.id}`;
        removed++;
      } else if (r.ok) sent++;
      else { failed++; console.log("push mislukt", r.status, await r.text()); }
    }
    return Response.json({ gecontroleerd: targets.length, verstuurd: sent, verwijderd: removed, mislukt: failed }, { headers: CORS });
  } catch (e) {
    console.error(e);
    return new Response("error", { status: 500, headers: CORS });
  }
});
