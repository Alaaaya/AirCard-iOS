import { assertEquals } from "jsr:@std/assert@1";
import { publicAddress, publicAnswers, ipaLinks, resolvePage, resolveResults, MAX_HTML } from "./resolver.ts";
import { toResults, buildSearchQuery } from "./logic.ts";
Deno.test("Android excluded, requested bundle never asserted", () => {
 const hits = ["https://apkpure.com/x", "https://example.com/a.apk", "https://example.com/ios"].map(url=>({title:"App",url}));
 assertEquals(toResults(hits,"com.requested.app").length,1);
 assertEquals(toResults(hits,"com.requested.app")[0].bundleId,"");
 assertEquals(toResults([{title:"APK for Android",url:"https://example.com/page"}],null).length,0);
 assertEquals(buildSearchQuery("App",null).includes("-android -apk"),true);
});
Deno.test("public DNS only, including mapped IPv6 and mixed answer sets", () => {
 for(const ip of ["127.0.0.1","10.0.0.1","169.254.169.254","100.64.0.1","192.168.0.1","::1","fc00::1","fe80::1","::ffff:127.0.0.1","0.0.0.0","192.0.2.1"]) assertEquals(publicAddress(ip),false,ip);
 assertEquals(publicAddress("8.8.8.8"),true);
 assertEquals(publicAnswers([{address:"8.8.8.8",family:4},{address:"127.0.0.1",family:4}]),false);
 assertEquals(publicAnswers([]),false);
});
Deno.test("HTML entities, relative IPA links, unsafe excluded; scripts not executed", () => {
 assertEquals(ipaLinks('<script>fetch("evil")</script><a href="/app.ipa?a=1&amp;b=2">x</a><a href="http://evil.com/x.ipa">x</a>',"https://example.com/page"),["https://example.com/app.ipa?a=1&b=2"]);
});
Deno.test("resolution supports bounded redirects, rejects private redirect before request", async () => {
 let count=0;
 const link=await resolvePage("https://example.com/page",async(url)=>{count++; return count===1?{status:302,location:"/next",type:"",html:""}:{status:200,type:"text/html",html:'<a href="/a.ipa">IPA</a>'}});
 assertEquals(link,"https://example.com/a.ipa"); assertEquals(count,2);
 count=0;
 assertEquals(await resolvePage("https://example.com/page",async()=>{count++;return {status:302,location:"https://127.0.0.1/x",type:"",html:""}}),undefined);
 assertEquals(count,1);
});
Deno.test("no link, ambiguous links, oversized, errors and login stay references", async () => {
 for(const page of [
 {status:200,type:"text/html",html:"Login required"},
 {status:403,type:"text/html",html:'<a href="/a.ipa">x</a>'},
 {status:200,type:"text/html",html:'<a href="/a.ipa">a</a><a href="/b.ipa">b</a>'},
 {status:200,type:"text/html",html:"x".repeat(MAX_HTML+1)}
 ]) assertEquals(await resolvePage("https://example.com/p",async()=>page),undefined);
 assertEquals(await resolvePage("https://example.com/p",async()=>{throw Error("timeout")}),undefined);
});
Deno.test("only four pages resolved, existing direct downloads preserved",async()=>{
 let calls=0; const r=toResults(Array.from({length:8},(_,i)=>({title:"App",url:"https://example.com/p"+i})),null);
 const out=await resolveResults(r,async()=>{calls++;return {status:200,type:"text/html",html:'<a href="/a.ipa">x</a>'}});
 assertEquals(calls,4); assertEquals(out.filter(x=>x.downloadURL).length,4);
});
