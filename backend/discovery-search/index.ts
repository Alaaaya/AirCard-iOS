// Supabase Edge Function: public web discovery for Mirsa.
// Secrets (names only): DISCOVERY_TOKEN (shared bearer, >=24 chars), TAVILY_API_KEY or BRAVE_API_KEY.
// Only calls the configured search API (fixed https hosts). It never fetches result pages itself,
// so there is no SSRF surface. Results are metadata, never files.
import { buildSearchQuery, cleanBundle, cleanQuery, Hit, RateLimiter, toResults, tokenOk } from "./logic.ts";

const limiter = new RateLimiter(20, 60_000);
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });

async function tavily(q: string, key: string): Promise<Hit[]> {
  const r = await fetch("https://api.tavily.com/search", {
    method: "POST", signal: AbortSignal.timeout(10_000), redirect: "error",
    headers: { "content-type": "application/json", authorization: "Bearer " + key },
    body: JSON.stringify({ query: q, max_results: 10, search_depth: "basic" }),
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
  if (!tokenOk(req.headers.get("authorization"), Deno.env.get("DISCOVERY_TOKEN"))) return json({ error: "unauthorized" }, 401);
  if (!limiter.allow("global")) return json({ error: "rate_limited" }, 429);
  const p = new URL(req.url).searchParams;
  const name = cleanQuery(p.get("q")); const bundle = cleanBundle(p.get("bundle"));
  if (!name && !bundle) return json({ error: "bad_query" }, 400);
  const tk = Deno.env.get("TAVILY_API_KEY"), bk = Deno.env.get("BRAVE_API_KEY");
  if (!tk && !bk) return json({ error: "provider_not_configured" }, 503);
  try {
    const q = buildSearchQuery(name, bundle);
    const hits = tk ? await tavily(q, tk) : await brave(q, bk!);
    return json({ results: toResults(hits, bundle), provider: tk ? "tavily" : "brave" });
  } catch { return json({ error: "provider_failed" }, 502); }
});
