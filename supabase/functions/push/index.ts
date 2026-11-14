// PrimeZ · fonction « push » : envoie les notifications aux appareils abonnés.
// À créer dans Supabase > Edge Functions > « Deploy a new function » > « Via Editor », nom : push,
// coller ce fichier, puis dans les réglages de la fonction DÉSACTIVER « Verify JWT » (« Enforce JWT verification »).
// Elle est appelée par la base (supabase/notifications-PRIVE.sql), jamais par les joueurs : un code secret la protège.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
let cfg: Record<string, string> | null = null;

Deno.serve(async (req) => {
  if (!cfg) {
    const { data } = await sb.from("push_config").select("k,v");
    cfg = Object.fromEntries((data ?? []).map((r: { k: string; v: string }) => [r.k, r.v]));
    webpush.setVapidDetails("https://primez.fr", cfg.vapid_public, cfg.vapid_private);
  }
  if (!cfg.secret || req.headers.get("x-push-secret") !== cfg.secret) return new Response("non", { status: 401 });

  const { user_ids, title, body, link, tag } = await req.json();
  let q = sb.from("push_subs").select("endpoint,p256dh,auth");
  if (Array.isArray(user_ids)) q = q.in("user_id", user_ids);
  const { data: subs } = await q;

  const payload = JSON.stringify({ title, body, link, tag });
  const gone: string[] = [];
  let ok = 0;
  await Promise.all((subs ?? []).map(async (s: { endpoint: string; p256dh: string; auth: string }) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 86400 });
      ok++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) gone.push(s.endpoint);   // appareil désabonné : on l'oublie
    }
  }));
  if (gone.length) await sb.from("push_subs").delete().in("endpoint", gone);
  return Response.json({ ok, gone: gone.length });
});
