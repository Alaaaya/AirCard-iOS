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

/** Extracts the bearer JWT (three base64url parts). Anything else is rejected. */
export function bearerJwt(header: string | null): string | null {
  const m = /^Bearer ([A-Za-z0-9_-]{10,2048}\.[A-Za-z0-9_-]{10,4096}\.[A-Za-z0-9_-]{10,2048})$/.exec(header ?? "");
  return m ? m[1] : null;
}

/** Maps the database limit error to its bucket name. */
export function limitFromError(message: string | undefined): string | null {
  const m = /limit:([a-z-]+)/.exec(message ?? "");
  return m ? m[1] : null;
}

/** Client IP must come from the platform-set header (cf-connecting-ip, set by the Cloudflare edge in front of Supabase).
 *  X-Forwarded-For is client-appendable and is never used. Anything that is not a plain IP maps to one shared "unknown" bucket (fail closed). */
export async function ipBucket(trustedIp: string | null, salt: string): Promise<string> {
  const ip = trustedIp && /^[0-9a-fA-F:.]{3,45}$/.test(trustedIp.trim()) ? trustedIp.trim() : "unknown";
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(salt + "|" + ip));
  return Array.from(new Uint8Array(d).slice(0, 12)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function buildSearchQuery(name: string | null, bundle: string | null): string {
  const base = name ?? bundle ?? "";
  return (base + " ipa download").slice(0, MAX_QUERY + 20);
}
