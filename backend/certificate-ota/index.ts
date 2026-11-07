import { createClient } from "npm:@supabase/supabase-js@2.106.2";
import { unzipSync } from "npm:fflate@0.8.3";
import { validateMetadata, manifest, MAX_IPA_BYTES, isExpired } from "./contract.mjs";

const root = Deno.env.get("SUPABASE_URL")!;
const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(root, key, { auth: { persistSession: false } });
const bucket = db.storage.from("mirsa-ota-private");
const base = root + "/functions/v1/certificate-ota";
const headers = { "cache-control": "no-store, max-age=0", "x-content-type-options": "nosniff", "referrer-policy": "no-referrer" };
const json = (data: unknown, status = 200) => new Response(JSON.stringify(data), {status, headers:{...headers,"content-type":"application/json"}});
const freshToken = () => Array.from(crypto.getRandomValues(new Uint8Array(32)), b => b.toString(16).padStart(2,"0")).join("");
async function user(req: Request) {
 const auth = req.headers.get("authorization") ?? "";
 if (!/^Bearer [A-Za-z0-9._-]+$/.test(auth)) return null;
 const {data,error} = await db.auth.getUser(auth.slice(7));
 return !error && data.user ? data.user : null;
}
async function cleanup() {
 const {data,error} = await db.from("mirsa_ota_jobs").select("token").lte("expires_at",new Date().toISOString()).limit(100);
 if(error) throw Error("cleanup_db");
 for(const job of data ?? []) {
  const {error:e} = await bucket.remove([job.token+".ipa"]);
  if(e) throw Error("cleanup_storage");
  // Keep rows one day so quotas cannot be reset by expiry.
  await db.from("mirsa_ota_jobs").update({ready:false}).eq("token",job.token);
 }
 await db.from("mirsa_ota_jobs").delete().lt("created_at",new Date(Date.now()-86400000).toISOString());
}
function validateArchive(bytes: Uint8Array) {
 if(bytes[0]!==80 || bytes[1]!==75 || bytes[2]!==3 || bytes[3]!==4) throw Error("zip");
 let total=0, count=0; const names=new Set<string>(); let info=0, signature=0;
 unzipSync(bytes, {filter: file => {
  if(++count>10000 || names.has(file.name)) throw Error("entries");
  names.add(file.name);
  if(file.name.startsWith("/") || file.name.includes("\\") || file.name.split("/").includes("..") || /[\x00-\x1f]/.test(file.name)) throw Error("path");
  if(/\.(p12|pfx|key|pem)$/i.test(file.name)) throw Error("signing_secret");
  total+=file.originalSize;
  if(total>200*1024*1024 || file.originalSize>100*1024*1024 || file.originalSize>Math.max(1024*1024,file.size*200)) throw Error("expanded_size");
  if(/^Payload\/[^/]+\.app\/Info.plist$/.test(file.name)) info++;
  if(/^Payload\/[^/]+\.app\/_CodeSignature\/CodeResources$/.test(file.name)) signature++;
  return false; // Never inflate untrusted executable content in the Edge process.
 }});
 if(info!==1 || signature!==1) throw Error("signed_app_required");
}
Deno.serve(async req => {
 try {
  const u=new URL(req.url);
  if(req.method==="POST" && u.searchParams.get("action")==="cleanup") {
   if(req.headers.get("authorization")!=="Bearer "+Deno.env.get("MIRSA_OTA_CLEANUP_SECRET")) return json({error:"unauthorized"},401);
   await cleanup(); return json({ok:true});
  }
  if(req.method==="GET") {
   const token=u.searchParams.get("token") ?? "";
   const kind=u.searchParams.get("kind");
   if(!/^[0-9a-f]{64}$/.test(token) || !["manifest","ipa"].includes(kind ?? "")) return json({error:"not_found"},404);
   const {data,error}=await db.rpc("mirsa_ota_download",{p_token:token});
   const job=data?.[0];
   if(error || !job || isExpired(job.expires_at)) return json({error:"expired_or_unavailable"},410);
   if(kind==="manifest") {
    return new Response(manifest(job.metadata,base+"?kind=ipa&token="+token),{headers:{...headers,"content-type":"application/xml"}});
   }
   const {data:body,error:downloadError}=await bucket.download(token+".ipa");
   if(downloadError || !body || isExpired(job.expires_at)) return json({error:"unavailable"},410);
   return new Response(body,{headers:{...headers,"content-type":"application/octet-stream","content-disposition":'attachment; filename="Mirsa.ipa"'}});
  }
  if(req.method!=="POST") return json({error:"method"},405);
  const who=await user(req); if(!who) return json({error:"unauthorized"},401);
  const length=Number(req.headers.get("content-length"));
  if(!Number.isSafeInteger(length) || length<4 || length>MAX_IPA_BYTES) return json({error:"size"},413);
  if(req.headers.get("content-type")!=="application/octet-stream") return json({error:"content_type"},415);
  let metadata;
  try {
   const raw=req.headers.get("x-mirsa-metadata") ?? "";
   if(raw.length>2048) throw Error("metadata");
   metadata=validateMetadata(JSON.parse(decodeURIComponent(raw)));
   if(metadata.bytes!==length) throw Error("size");
  } catch { return json({error:"metadata"},400); }
  const token=freshToken();
  const {error:quota}=await db.rpc("mirsa_ota_reserve",{p_owner:who.id,p_token:token,p_bytes:length,p_metadata:metadata});
  if(quota) return json({error:"quota"},429);
  if(!req.body) return json({error:"body"},400);
  const reader=req.body.getReader(); const chunks:Uint8Array[]=[]; let size=0;
  while(true) {
   const {done,value}=await reader.read(); if(done) break;
   size+=value.length;
   if(size>length || size>MAX_IPA_BYTES) {await reader.cancel();return json({error:"size"},413);}
   chunks.push(value);
  }
  if(size!==length) return json({error:"size"},400);
  const bytes=new Uint8Array(size); let offset=0;
  for(const c of chunks) {bytes.set(c,offset);offset+=c.length;}
  try {validateArchive(bytes);} catch {return json({error:"invalid_signed_ipa"},400);}
  const {error:upload}=await bucket.upload(token+".ipa",bytes,{contentType:"application/octet-stream",upsert:false,cacheControl:"0"});
  if(upload) return json({error:"storage"},503);
  const {data:job,error:ready}=await db.from("mirsa_ota_jobs").update({ready:true}).eq("token",token).select("expires_at").single();
  if(ready || !job || isExpired(job.expires_at)) {await bucket.remove([token+".ipa"]);return json({error:"expired"},410);}
  const manifestURL=base+"?kind=manifest&token="+token;
  return json({manifestURL, installURL:"itms-services://?action=download-manifest&url="+encodeURIComponent(manifestURL), expiresAt:job.expires_at});
 } catch {return json({error:"unavailable"},503);}
});
