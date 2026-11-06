// Supabase Edge Function: public web discovery for Mirsa.
// Auth: each app install signs in anonymously (Supabase Auth) and sends its own user JWT; verified server-side.
// No shared token is embedded in the app. Abuse limits are durable and global (Postgres, see schema.sql).
// Secrets (names only): TAVILY_API_KEY or BRAVE_API_KEY, IP_SALT. SUPABASE_* are provided by the platform.
// Never fetches result pages (no SSRF surface). Results are metadata, never files.
import { createClient } from "npm:@supabase/supabase-js@2";
import { bearerJwt, buildSearchQuery, cleanBundle, cleanQuery, Hit, ipBucket, limitFromError, toResults } from "./logic.ts";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });

async function tavily(q: string, key: string): Promise<Hit[]> {
  const r = await fetch("https://api.tavily.com/search", {
    method: "POST", signal: AbortSignal.timeout(10_000), redirect: "error",
    headers: { "content-type": "application/json", authorization: "Bearer " + key },
    body: JSON.stringify({ query: q, max_results: 10, search_depth: "basic", include_raw_content: false, include_answer: false, include_images: false }),
  });
  if (!r.ok) throw new Error("provider " + r.status);
  const d = await r.json();
  return (d.results ?? []).map((x: any) => ({ title: x.title, url: x.url, snippet: x.content }));
}

async function brave(q: string, key: string): Promise<Hit[]> {
  const r = await fetch("https://api.search.brave.com/res/v1/web/search?count=10&q=" + encodeURIComponent(q), {
    signal: AbortSignal.timeout(10_000), redirect: "error",
    headers: { "x-subscription-token": key, accept: "application/json" },
  });
  if (!r.ok) throw new Error("provider " + r.status);
  const d = await r.json();
  return (d.web?.results ?? []).map((x: any) => ({ title: x.title, url: x.url, snippet: x.description }));
}

Deno.serve(async (req) => {
  if (req.method !== "GET") return json({ error: "method" }, 405);
  const jwt = bearerJwt(req.headers.get("authorization"));
  if (!jwt) return json({ error: "unauthorized" }, 401);
  const { data: u, error: ue } = await admin.auth.getUser(jwt);
  if (ue || !u?.user) return json({ error: "unauthorized" }, 401);
  const salt = Deno.env.get("IP_SALT");
  if (!salt || salt.length < 16) return json({ error: "not_configured" }, 503);
  const p = new URL(req.url).searchParams;
  const name = cleanQuery(p.get("q")); const bundle = cleanBundle(p.get("bundle"));
  if (!name && !bundle) return json({ error: "bad_query" }, 400);
  const tk = Deno.env.get("TAVILY_API_KEY"), bk = Deno.env.get("BRAVE_API_KEY");
  if (!tk && !bk) return json({ error: "provider_not_configured" }, 503);
  // Reserve ONE credit atomically BEFORE the provider call. Never refunded (a timeout may still have been billed).
  const ip = await ipBucket(req.headers.get("cf-connecting-ip"), salt);
  const { error: le } = await admin.rpc("discovery_take", { p_user: u.user.id, p_ip: ip });
  if (le) return limitFromError(le.message) ? json({ error: "rate_limited" }, 429) : json({ error: "limiter_failed" }, 503);
  try {
    const q = buildSearchQuery(name, bundle);
    const hits = tk ? await tavily(q, tk) : await brave(q, bk!);
    return json({ results: toResults(hits, bundle), provider: tk ? "tavily" : "brave" });
  } catch { return json({ error: "provider_failed" }, 502); }
});
