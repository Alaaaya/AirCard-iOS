// HTML only. No cookies, scripts, credentials, or automatic redirects.
// DNS validation happens inside socket lookup, not in a racy preflight.
import { request } from "node:https";
import { lookup } from "node:dns";
import ipaddr from "npm:ipaddr.js@2.5.0";
import { Parser } from "npm:htmlparser2@10.0.0";
import { isSafeUrl, isAndroidHit, Result } from "./logic.ts";

export const MAX_HTML = 256 * 1024;
export function publicAddress(ip: string): boolean {
  try { return ipaddr.process(ip).range() === "unicast"; } catch { return false; }
}
export function publicAnswers(answers: {address: string; family: number}[]): boolean {
  return answers.length > 0 && answers.every(a => publicAddress(a.address));
}
export interface Page { status: number; location?: string; type: string; html: string }
export type Reader = (url: string, deadline: number) => Promise<Page>;

export const readPublicPage: Reader = (url, deadline) => new Promise((resolve, reject) => {
  if (!isSafeUrl(url)) { reject(new Error("unsafe URL")); return; }
  const remaining = deadline - Date.now();
  if (remaining <= 0) { reject(new Error("deadline")); return; }
  const req = request(url, {
    agent: false, method: "GET",
    headers: { Accept: "text/html", "Accept-Encoding": "identity", "User-Agent": "Mirsa-LinkResolver/1.0" },
    // all DNS answers must be public; only this vetted address is returned to the socket.
    lookup: (hostname, options, callback) => {
      lookup(hostname, { all: true }, (err, answers) => {
        if (err || !publicAnswers(answers)) { callback(err ?? new Error("nonpublic DNS"), "", 4); return; }
        // Modern Node/Deno can ask for all results.
        if (typeof options === "object" && options.all) callback(null, answers as never);
        else callback(null, answers[0].address, answers[0].family);
      });
    },
  }, res => {
    const status = res.statusCode ?? 0;
    const type = String(res.headers["content-type"] ?? "");
    if (status >= 300 && status < 400) {
      const location = res.headers.location; res.destroy();
      resolve({status, location, type, html: ""}); return;
    }
    if (status !== 200 || !/^text\/html\b/i.test(type) ||
        Number(res.headers["content-length"] ?? 0) > MAX_HTML ||
        (res.headers["content-encoding"] && res.headers["content-encoding"] !== "identity")) {
      res.destroy(); reject(new Error("not bounded HTML")); return;
    }
    let size = 0; const chunks: Uint8Array[] = [];
    res.on("data", (chunk: Uint8Array) => {
      size += chunk.length;
      if (size > MAX_HTML) { req.destroy(new Error("body limit")); return; }
      chunks.push(chunk);
    });
    res.on("error", reject);
    res.on("end", () => {
      const bytes = new Uint8Array(size); let offset = 0;
      for (const c of chunks) { bytes.set(c, offset); offset += c.length; }
      resolve({status, type, html: new TextDecoder().decode(bytes)});
    });
  });
  const timer = setTimeout(() => req.destroy(new Error("deadline")), remaining);
  req.on("close", () => clearTimeout(timer));
  req.on("error", reject);
  req.end();
});

export function ipaLinks(html: string, base: string): string[] {
  const links = new Set<string>();
  const parser = new Parser({onopentag(name, a) {
    if (name !== "a" || !a.href || links.size >= 12) return;
    try {
      const u = new URL(a.href, base);
      if (isSafeUrl(u.href) && /\.ipa$/i.test(u.pathname) && !isAndroidHit({title: "", url: u.href})) links.add(u.href);
    } catch { /* malformed href */ }
  }});
  parser.end(html);
  return [...links];
}

export async function resolvePage(url: string, reader: Reader = readPublicPage): Promise<string | undefined> {
  const deadline = Date.now() + 3500;
  try {
    for (let hop = 0; hop <= 2; hop++) {
      if (!isSafeUrl(url)) return;
      const page = await reader(url, deadline);
      if (page.status >= 300 && page.status < 400 && page.location && hop < 2) {
        url = new URL(page.location, url).href; continue;
      }
      if (page.status !== 200 || !/^text\/html\b/i.test(page.type) ||
          new TextEncoder().encode(page.html).length > MAX_HTML) return;
      // Do not pick an arbitrary app from an index page with multiple IPA links.
      const links = ipaLinks(page.html, url);
      return links.length === 1 ? links[0] : undefined;
    }
  } catch { /* blocked/timeout/captcha/etc stays a reference */ }
}
export async function resolveResults(results: Result[], reader: Reader = readPublicPage): Promise<Result[]> {
  const pages = results.filter(r => !r.downloadURL).slice(0, 4);
  const resolved = await Promise.all(pages.map(async r => ({r, link: await resolvePage(r.pageURL, reader)})));
  const links = new Map(resolved.filter(x => x.link).map(x => [x.r.pageURL, x.link!]));
  return results.map(r => links.has(r.pageURL) ? {...r, downloadURL: links.get(r.pageURL), kind: "direct-ipa"} : r);
}
