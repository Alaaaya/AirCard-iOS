// Pure logic for the discovery search backend. No I/O, fully unit tested.

export const MAX_QUERY = 120;
export const MAX_RESULTS = 12;

const BLOCKED_SUFFIXES = ["local","localhost","internal","lan","home","intranet","corp","private","localdomain","arpa"];

/** HTTPS, public DNS names only, no IP literals, no credentials, no odd ports. */
export function isSafeUrl(raw: string): boolean {
  let u: URL;
  try { u = new URL(raw); } catch { return false; }
  if (u.protocol !== "https:" || raw.length > 2048) return false;
  if (u.username || u.password) return false;
  if (u.port && u.port !== "443") return false;
  const host = u.hostname.toLowerCase().replace(/\.+$/, "");
  if (!host || host.includes(":") || host.startsWith("[")) return false;
  const labels = host.split(".");
  if (labels.length < 2 || labels.some((l) => l === "")) return false;
  const tld = labels[labels.length - 1];
  if (/^\d+$/.test(tld) || tld.startsWith("0x")) return false;
  if (BLOCKED_SUFFIXES.some((s) => tld === s || host.endsWith("." + s))) return false;
  return /^[a-z0-9.-]+$/.test(host);
}

export function cleanQuery(q: unknown): string | null {
  if (typeof q !== "string") return null;
  const s = q.replace(/[\u0000-\u001f]/g, " ").trim().replace(/\s+/g, " ");
  if (s.length < 2 || s.length > MAX_QUERY) return null;
  return s;
}

export function cleanBundle(b: unknown): string | null {
  if (typeof b !== "string") return null;
  return /^[A-Za-z0-9]([A-Za-z0-9.\-]{0,126}[A-Za-z0-9])?$/.test(b) ? b : null;
}

export interface Hit { title: string; url: string; snippet?: string; }
export interface Result {
  name: string; bundleId: string; developer: string; version: string;
  downloadURL?: string; pageURL: string; sourceName: string; sourceURL: string;
  kind: "direct-ipa" | "page";
}

/** Only links that really end in .ipa become download candidates. Everything else is a page reference. */
export function toResults(hits: Hit[], bundle: string | null): Result[] {
  const out: Result[] = [];
  const seen = new Set<string>();
  for (const h of hits) {
    if (!h || typeof h.url !== "string" || !isSafeUrl(h.url) || seen.has(h.url)) continue;
    seen.add(h.url);
    const u = new URL(h.url);
    const direct = u.pathname.toLowerCase().endsWith(".ipa");
    out.push({
      name: String(h.title ?? u.hostname).slice(0, 120),
      bundleId: bundle ?? "unknown." + u.hostname,
      developer: "", version: "",
      downloadURL: direct ? h.url : undefined,
      pageURL: h.url,
      sourceName: u.hostname, sourceURL: h.url,
      kind: direct ? "direct-ipa" : "page",
    });
    if (out.length >= MAX_RESULTS) break;
  }
  return out;
}

/** Constant-time compare for the shared bearer token. */
export function tokenOk(header: string | null, secret: string | undefined): boolean {
  if (!secret || secret.length < 24 || !header) return false;
  const m = /^Bearer (.+)$/.exec(header);
  if (!m) return false;
  const a = new TextEncoder().encode(m[1]), b = new TextEncoder().encode(secret);
  let d = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) d |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return d === 0;
}

/** Fixed-window limiter (per instance). */
export class RateLimiter {
  private hits = new Map<string, { n: number; t: number }>();
  constructor(private limit: number, private windowMs: number, private now: () => number = Date.now) {}
  allow(key: string): boolean {
    const t = this.now();
    const e = this.hits.get(key);
    if (!e || t - e.t >= this.windowMs) {
      if (this.hits.size > 5000) this.hits.clear();
      this.hits.set(key, { n: 1, t }); return true;
    }
    if (e.n >= this.limit) return false;
    e.n++; return true;
  }
}

export function buildSearchQuery(name: string | null, bundle: string | null): string {
  const base = name ?? bundle ?? "";
  return (base + " ipa download").slice(0, MAX_QUERY + 20);
}
