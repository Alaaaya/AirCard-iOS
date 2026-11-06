import { assertEquals } from "jsr:@std/assert@1";
import { cleanBundle, cleanQuery, isSafeUrl, toResults, bearerJwt, limitFromError, ipBucket } from "./logic.ts";

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
  const hits = [{title:"A",url:"https://downloads.example.com/a.IPA"},{title:"B",url:"https://downloads.example.com/page"},{title:"C",url:"http://evil.com/c.ipa"},{title:"A2",url:"https://downloads.example.com/a.IPA"}];
  const r = toResults(hits, "com.a.b");
  assertEquals(r.length, 2); assertEquals(r[0].downloadURL, "https://downloads.example.com/a.IPA"); assertEquals(r[1].downloadURL, undefined);
  assertEquals(toResults(Array.from({length:50},(_,i)=>({title:"t",url:"https://h"+i+".com/a"})), null).length, 12);
});
Deno.test("bearer jwt shape", () => {
  const j = "aaaaaaaaaa.bbbbbbbbbb.cccccccccc";
  assertEquals(bearerJwt("Bearer " + j), j);
  for (const h of [null, "", "Bearer x", "Bearer a.b", "Basic " + j, "Bearer " + j + " extra", "bearer " + j]) assertEquals(bearerJwt(h), null, String(h));
});
Deno.test("limit error mapping", () => {
  assertEquals(limitFromError("limit:global-month"), "global-month");
  assertEquals(limitFromError("connection refused"), null); assertEquals(limitFromError(undefined), null);
});
Deno.test("ip bucket hashed, stable, salted, trusted header only", async () => {
  const s = "saltsaltsaltsalt1";
  const a = await ipBucket("1.2.3.4", s);
  assertEquals(a, await ipBucket(" 1.2.3.4 ", s));
  assertEquals(a.includes("1.2.3.4"), false); assertEquals(a.length, 24);
  assertEquals(a === await ipBucket("1.2.3.4", "othersaltothersalt"), false);
  const unknown = await ipBucket(null, s);
  for (const bad of ["1.2.3.4, 9.9.9.9", "evil host", "", "x".repeat(100)]) assertEquals(await ipBucket(bad, s), unknown, bad);
});

Deno.test("strict identity tokens reject owner junk results", () => {
  const hits = [
    {title:"DramaWave official IPA",url:"https://downloads.example.com/dramawave.ipa"},
    {title:"DramaWave hashtags",url:"https://instagram.com/explore/tags/dramawave"},
    {title:"DramaWave",url:"https://commons.wikimedia.org/wiki/Billboard_1922"},
    {title:"DramaWaves unrelated",url:"https://example.com/other.ipa"},
    {title:"DramaWave decrypted",url:"https://decrypt.day/app/id6670430706"},
    {title:"Billboard 1922",url:"https://example.com/archive"},
  ];
  assertEquals(toResults(hits,"com.dramabuzz.app","DramaWave").map(x=>x.pageURL),
    ["https://downloads.example.com/dramawave.ipa"]);
  assertEquals(toResults(hits,"com.dramabuzz.app","DramaWave")[0].bundleId,"");
});
Deno.test("blocked destinations cannot hide in subdomains or redirects", () => {
 for (const u of ["https://decrypt.day/a.ipa","https://cdn.decrypt.day/a.ipa",
   "https://instagram.com/a.ipa","https://commons.wikimedia.org/a.ipa",
   "https://apps.apple.com.evil.local/a.ipa","https://u:p@example.com/a.ipa"])
   assertEquals(isSafeUrl(u),false,u);
 assertEquals(isSafeUrl("https://mydecrypt.example.com/app.ipa"),true);
});
