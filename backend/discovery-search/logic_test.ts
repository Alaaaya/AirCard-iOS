import { assertEquals } from "jsr:@std/assert@1";
import { cleanBundle, cleanQuery, isSafeUrl, RateLimiter, toResults, tokenOk } from "./logic.ts";

Deno.test("unsafe urls rejected", () => {
  for (const u of ["http://a.com/x","https://127.0.0.1/x","https://localhost/x","https://2130706433/x","https://[::1]/x","https://a.local/x",
    "https://u:p@a.com/x","https://a.com:8443/x","https://169.254.169.254/x","https://printer/x","file:///etc/passwd","not a url"]) assertEquals(isSafeUrl(u), false, u);
  assertEquals(isSafeUrl("https://example.com/a.ipa"), true);
});
Deno.test("query cleaning", () => {
  assertEquals(cleanQuery("  Drama   Wave\n"), "Drama Wave");
  assertEquals(cleanQuery("x"), null); assertEquals(cleanQuery("a".repeat(500)), null); assertEquals(cleanQuery(5), null);
  assertEquals(cleanBundle("com.a.b"), "com.a.b"); assertEquals(cleanBundle("../x"), null);
});
Deno.test("only .ipa links are downloadable, unsafe dropped, deduped, bounded", () => {
  const hits = [{title:"A",url:"https://x.com/a.IPA"},{title:"B",url:"https://x.com/page"},{title:"C",url:"http://evil.com/c.ipa"},{title:"A2",url:"https://x.com/a.IPA"}];
  const r = toResults(hits, "com.a.b");
  assertEquals(r.length, 2); assertEquals(r[0].downloadURL, "https://x.com/a.IPA"); assertEquals(r[1].downloadURL, undefined);
  assertEquals(toResults(Array.from({length:50},(_,i)=>({title:"t",url:"https://h"+i+".com/a"})), null).length, 12);
});
Deno.test("token check", () => {
  const s = "s".repeat(32);
  assertEquals(tokenOk("Bearer " + s, s), true); assertEquals(tokenOk("Bearer x", s), false);
  assertEquals(tokenOk(null, s), false); assertEquals(tokenOk("Bearer short", "short"), false); assertEquals(tokenOk("Bearer " + s, undefined), false);
});
Deno.test("rate limiter", () => {
  let t = 0; const l = new RateLimiter(2, 1000, () => t);
  assertEquals([l.allow("a"), l.allow("a"), l.allow("a")], [true, true, false]);
  t = 1500; assertEquals(l.allow("a"), true);
});
