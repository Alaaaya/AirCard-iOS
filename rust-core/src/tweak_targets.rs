//! Explicit, bounded per-target injection. No host execution of package code.
use super::*;
use serde::Serialize;
#[derive(Serialize)]
struct Target { id: String, kind: String, label: String }
#[derive(Deserialize,Clone)]
pub(super) struct Injection { id: String, library: String, target: String }
fn json(out: &Path, value: &impl Serialize)->Result<()> { fs::write(out,serde_json::to_vec(value).map_err(err)?).map_err(err) }
fn executable(bundle:&Path)->Result<String>{
 let value=plist::Value::from_file(bundle.join("Info.plist")).map_err(err)?;
 let s=value.as_dictionary().and_then(|d|d.get("CFBundleExecutable")).and_then(|v|v.as_string()).ok_or("Bundle missing executable")?;
 if relative(s)?.components().count()!=1 {return Err("Invalid bundle executable".into())} Ok(s.into())
}
fn targets(app:&Path)->Result<Vec<Target>>{
 checked_tree(app)?;let app=fs::canonicalize(app).map_err(err)?;
 let mut files=Vec::new();walk(&app,&mut files)?;
 let main=executable(&app)?;
 let mut result=Vec::new();
 for p in std::iter::once(app.clone()).chain(files.into_iter().filter(|p|p.is_dir() && matches!(p.extension().and_then(|s|s.to_str()),Some("appex"|"framework")))) {
  let ex=executable(&p)?;let path=p.join(&ex);
  macho(read_macho(&path)?,p.extension().and_then(|s|s.to_str())==Some("framework"))?;
  let id=path.strip_prefix(&app).map_err(err)?.to_str().ok_or("Non UTF8 target")?.to_owned();
  result.push(Target{id,kind:if p==app{"main"}else if p.extension().and_then(|s|s.to_str())==Some("appex"){"extension"}else{"framework"}.into(),label:ex});
 }
 result.sort_by(|a,b|a.id.cmp(&b.id));
 if !result.iter().any(|t|t.id==main){return Err("Missing main target".into())} Ok(result)
}
pub(super) fn list_targets(app:&Path,out:&Path)->Result<()> {json(out,&targets(app)?)}
pub(super) fn package_roots(root:&Path,out:&Path)->Result<()> {
 checked_tree(root)?;
 if fs::symlink_metadata(root).map_err(err)?.file_type().is_symlink(){return Err("Package root cannot be a symlink".into())}
 let mut files=Vec::new();walk(root,&mut files)?;
 let mut total=0u64;
 for p in &files {let m=fs::symlink_metadata(p).map_err(err)?;if m.is_file(){total=total.checked_add(m.len()).ok_or("Package size overflow")?;if m.len()>FILE_LIMIT||total>TOTAL_LIMIT{return Err("Package root size limit exceeded".into())}}}
 let mut result=Vec::new();let mut names=HashSet::new();
 for p in files {
  let rel=p.strip_prefix(root).map_err(err)?;
  if rel.ancestors().skip(1).any(|p|p.extension().and_then(|s|s.to_str())==Some("framework")){continue}
  let kind=match p.extension().and_then(|s|s.to_str()){Some("dylib") if p.is_file()=>"dylib",Some("framework") if p.is_dir()=>"framework",_=>continue};
  let id=rel.to_str().ok_or("Non UTF8 package path")?.to_owned();relative(&id)?;
  if !names.insert(id.to_lowercase()){return Err("Case colliding package roots".into())}
  let code=if kind=="framework"{p.join(framework_executable(&p)?)}else{p.clone()};macho(read_macho(&code)?,true)?;
  result.push(serde_json::json!({"id":id,"path":id,"kind":kind}));
 }
 result.sort_by(|a,b|a["id"].as_str().cmp(&b["id"].as_str()));json(out,&result)
}
fn inject_plan_inner(app:&Path,items:&[Injection],order:&[String],loader:bool,first:bool)->Result<()> {
 if items.is_empty() || items.len()>64 || order.len()>4096{return Err("Injection plan exceeds limits or is empty".into())}
 let available=targets(app)?;let mut ids=HashSet::new();let mut groups:BTreeMap<String,Vec<String>>=BTreeMap::new();let mut destinations=HashSet::new();
 let mut sorted=items.to_vec();
 sorted.sort_by(|a,b|order.iter().position(|x|x==&a.id).unwrap_or(usize::MAX).cmp(&order.iter().position(|x|x==&b.id).unwrap_or(usize::MAX)).then(a.id.cmp(&b.id)));
 for item in sorted {
  if item.id.is_empty() || item.id.len()>4096 || !ids.insert(item.id){return Err("Duplicate or invalid stable tweak id".into())}
  let target=available.iter().find(|t|t.id==item.target).ok_or("Unknown injection target")?;
  if loader && target.kind!="main" {return Err("LoadControl supports the main executable only".into())}
  let source=Path::new(&item.library);let code=if source.extension().and_then(|s|s.to_str())==Some("framework"){source.join(framework_executable(source)?)}else{source.to_path_buf()};
  macho(read_macho(&code)?,true)?;
  let name=source.file_name().and_then(|s|s.to_str()).ok_or("Invalid tweak name")?;
  let parent=Path::new(&item.target).parent().ok_or("Invalid target")?;
  let destination=parent.join("Frameworks").join(name);
  let key=destination.to_string_lossy().to_lowercase();
  if !destinations.insert(key){return Err("Tweak destination filename collision for selected target; rename library first".into())}
  let dir=app.join(parent).join("Frameworks");
  if dir.exists(){for e in fs::read_dir(&dir).map_err(err)?{if e.map_err(err)?.file_name().to_string_lossy().eq_ignore_ascii_case(name){return Err("Existing target Frameworks filename collision".into())}}}
  groups.entry(item.target).or_default().push(item.library);
 }
 // Work on caller-owned disposable app copy. Existing signer signs nested libraries
 // before hashing resources and enclosing frameworks/extensions before outer app.
 for (id,libraries) in groups {
  let t=available.iter().find(|t|t.id==id).unwrap();
  let target=app.join(&id);let scope=target.parent().ok_or("Missing target parent")?;
  if loader {load_control::inject_loader(app,&id,&libraries,first)?}else{
   // Scope is the selected bundle, not the outer app. Cross-bundle dependencies
   // therefore fail closed instead of silently using another extension's code.
   if t.kind=="framework" {
    for lib in &libraries {let src=Path::new(lib);let code=if src.extension().and_then(|s|s.to_str())==Some("framework"){src.join(framework_executable(src)?)}else{src.to_owned()};for dep in dependencies(&code)?{if dep.starts_with("@executable_path/"){return Err("Framework target cannot resolve executable-relative tweak dependencies".into())}}}
   }
   inject_scoped(scope,target.file_name().and_then(|s|s.to_str()).ok_or("Invalid target")?,&libraries,first,true)?;
  }
 }
 Ok(())
}
/// Transactional private sibling copy. No original app mutations on validation or
/// injection error. Rename rollback handles commit failure. Caller must serialize
/// edits to its app workspace; this is not a cross-process filesystem lock.
pub(super) fn inject_plan(app:&Path,items:&[Injection],order:&[String],loader:bool,first:bool)->Result<()> {
 if items.is_empty()||items.len()>64||order.len()>4096{return Err("Injection plan exceeds limits or is empty".into())}
 use std::sync::atomic::{AtomicU64,Ordering};static NEXT:AtomicU64=AtomicU64::new(0);
 if fs::symlink_metadata(app).map_err(err)?.file_type().is_symlink(){return Err("App root cannot be a symlink".into())}
 let app=fs::canonicalize(app).map_err(err)?;let parent=app.parent().ok_or("Invalid app path")?;
 let suffix=format!("{}-{}",std::process::id(),NEXT.fetch_add(1,Ordering::Relaxed));
 let temp=parent.join(format!(".mirsa-plan-{suffix}.app"));let backup=parent.join(format!(".mirsa-backup-{suffix}.app"));
 if temp.exists()||backup.exists(){return Err("Plan transaction collision".into())}
 let result=(||{
  checked_tree(&app)?;copy_tree(&app,&temp)?;
  // Snapshot selected libraries so validation and edits never revisit caller paths.
  let imports=parent.join(format!(".mirsa-imports-{suffix}"));fs::create_dir(&imports).map_err(err)?;
  let work=(||{let mut snapshots=Vec::new();for(i,item)in items.iter().enumerate(){let source=Path::new(&item.library);checked_tree(source)?;let slot=imports.join(i.to_string());fs::create_dir(&slot).map_err(err)?;let name=source.file_name().ok_or("Invalid library filename")?;let dest=slot.join(name);copy_tree(source,&dest)?;let mut copy=item.clone();copy.library=dest.to_string_lossy().into();snapshots.push(copy)}inject_plan_inner(&temp,&snapshots,order,loader,first)})();
  let _=fs::remove_dir_all(&imports);work?;
  // Recheck original immediately before swap; reject new symlinks/case aliases.
  checked_tree(&app)?;fs::rename(&app,&backup).map_err(err)?;
  if let Err(e)=fs::rename(&temp,&app){let restore=fs::rename(&backup,&app);return Err(format!("Plan commit failed: {e}; rollback: {restore:?}"))}
  let _=fs::remove_dir_all(&backup);Ok(())
 })();if result.is_err(){let _=fs::remove_dir_all(&temp);}result
}
fn checked_tree(root:&Path)->Result<()> {
 let m=fs::symlink_metadata(root).map_err(err)?;if m.file_type().is_symlink()||!(m.is_file()||m.is_dir()){return Err("Links or special files not supported".into())}
 if m.is_file(){if m.len()>FILE_LIMIT{return Err("Library too large".into())}return Ok(())}
 let mut files=Vec::new();walk(root,&mut files)?;let mut names=BTreeMap::new();let mut total=0u64;
 for p in files {let rel=p.strip_prefix(root).map_err(err)?.to_str().ok_or("Non UTF8 tree path")?.to_owned();relative(&rel)?;if names.insert(rel.to_lowercase(),rel).is_some(){return Err("Case aliased tree path".into())}let m=fs::symlink_metadata(&p).map_err(err)?;if m.is_file(){total=total.checked_add(m.len()).ok_or("Tree size overflow")?;if m.len()>FILE_LIMIT||total>TOTAL_LIMIT{return Err("Tree resource limit".into())}}}Ok(())
}
#[cfg(test)]mod tests{
 use super::*;
 fn fixture(kind:u32)->Vec<u8>{let mut d=vec![0;4096];for(o,v)in[(0,0xfeedfacf),(4,0x100000c),(12,kind),(16,1),(20,152),(32,0x19),(36,152),(96,1),(152,1024)]{put32(&mut d,o,v)}d[80..88].copy_from_slice(&4096u64.to_le_bytes());d[144..152].copy_from_slice(&16u64.to_le_bytes());d}
 fn bundle(p:&Path,exe:&str,kind:u32){fs::create_dir_all(p).unwrap();fs::write(p.join(exe),fixture(kind)).unwrap();let mut d=plist::Dictionary::new();d.insert("CFBundleExecutable".into(),plist::Value::String(exe.into()));plist::Value::Dictionary(d).to_file_xml(p.join("Info.plist")).unwrap()}
 fn setup(tag:&str)->(PathBuf,PathBuf){let p=std::env::temp_dir().join(format!("mirsa-targets-{}-{tag}",std::process::id()));let _=fs::remove_dir_all(&p);let app=p.join("A.app");bundle(&app,"Main",2);(p,app)}
 fn item(id:&str,lib:&Path,target:&str)->Injection{Injection{id:id.into(),library:lib.to_string_lossy().into(),target:target.into()}}
 #[test]fn mixed_targets_and_stable_order(){let(p,a)=setup("mixed");bundle(&a.join("PlugIns/X.appex"),"X",2);bundle(&a.join("Frameworks/F.framework"),"F",6);for n in["A","B","C","D"]{fs::write(p.join(format!("{n}.dylib")),fixture(6)).unwrap()}
 let items=vec![item("a",&p.join("A.dylib"),"Main"),item("b",&p.join("B.dylib"),"Main"),item("c",&p.join("C.dylib"),"PlugIns/X.appex/X"),item("d",&p.join("D.dylib"),"Frameworks/F.framework/F")];
 inject_plan(&a,&items,&["missing".into(),"b".into()],false,false).unwrap();let deps=dependencies(&a.join("Main")).unwrap();assert!(deps[0].ends_with("B.dylib"));assert!(deps[1].ends_with("A.dylib"));assert!(dependencies(&a.join("PlugIns/X.appex/X")).unwrap()[0].ends_with("C.dylib"));assert!(dependencies(&a.join("Frameworks/F.framework/F")).unwrap()[0].ends_with("D.dylib"));fs::remove_dir_all(p).unwrap();}
 #[test]fn unsupported_and_duplicate_fail(){let(p,a)=setup("reject");bundle(&a.join("PlugIns/X.appex"),"X",2);let lib=p.join("T.dylib");fs::write(&lib,fixture(6)).unwrap();assert!(inject_plan(&a,&[item("a",&lib,"PlugIns/X.appex/X")],&[],true,false).is_err());assert!(inject_plan(&a,&[item("a",&lib,"Main"),item("a",&lib,"Main")],&[],false,false).is_err());assert!(inject_plan(&a,&[item("a",&lib,"../outside")],&[],false,false).is_err());let mut d=fixture(6);put32(&mut d,8,2);fs::write(&lib,d).unwrap();assert!(inject_plan(&a,&[item("a",&lib,"Main")],&[],false,false).is_err());fs::remove_dir_all(p).unwrap();}
 #[test]fn roots_separate_same_basename_and_symlink_reject(){let(p,_)=setup("roots");let r=p.join("pkg");fs::create_dir_all(r.join("a")).unwrap();fs::create_dir_all(r.join("b")).unwrap();for n in["a/T.dylib","b/T.dylib"]{fs::write(r.join(n),fixture(6)).unwrap()}let out=p.join("roots.json");package_roots(&r,&out).unwrap();let v:serde_json::Value=serde_json::from_slice(&fs::read(&out).unwrap()).unwrap();assert_eq!(v[0]["id"],"a/T.dylib");assert_eq!(v[1]["id"],"b/T.dylib");#[cfg(unix)]{std::os::unix::fs::symlink("/tmp",r.join("escape")).unwrap();assert!(package_roots(&r,&out).is_err());}fs::remove_dir_all(p).unwrap();}
 #[test]fn missing_dependency_and_colliding_roots_fail(){let(p,a)=setup("deps");let l=p.join("A.dylib");let m=macho(fixture(6),true).unwrap();let mut cs:Vec<_>=m.commands.iter().map(|c|c.data.clone()).collect();cs.push(dylib_command(0xc,"@rpath/Missing.dylib",None).unwrap());fs::write(&l,write_commands(m,cs).unwrap()).unwrap();assert!(inject_plan(&a,&[item("a",&l,"Main")],&[],false,false).is_err());fs::remove_dir_all(p).unwrap();}
 #[test]fn transaction_rolls_back_after_late_failure(){let(p,a)=setup("transaction");bundle(&a.join("PlugIns/Z.appex"),"Z",2);let good=p.join("Good.dylib");let bad=p.join("Bad.dylib");fs::write(&good,fixture(6)).unwrap();let m=macho(fixture(6),true).unwrap();let mut cs:Vec<_>=m.commands.iter().map(|c|c.data.clone()).collect();cs.push(dylib_command(0xc,"@rpath/DoesNotExist.dylib",None).unwrap());fs::write(&bad,write_commands(m,cs).unwrap()).unwrap();let before=fs::read(a.join("Main")).unwrap();assert!(inject_plan(&a,&[item("good",&good,"Main"),item("bad",&bad,"PlugIns/Z.appex/Z")],&[],false,false).is_err());assert_eq!(fs::read(a.join("Main")).unwrap(),before);assert!(!a.join("Frameworks").exists());assert!(!a.join("PlugIns/Z.appex/Frameworks").exists());assert!(!fs::read_dir(&p).unwrap().any(|e|e.unwrap().file_name().to_string_lossy().starts_with(".mirsa-")));fs::remove_dir_all(p).unwrap();}
 #[test]fn target_tree_case_alias_and_symlink_reject(){let(p,a)=setup("alias");fs::create_dir(a.join("Foo")).unwrap();
 // APFS on macOS runners is case-insensitive: it rejects the alias at creation.
 // Case-sensitive volumes must instead reject both entries in our tree validator.
 match fs::create_dir(a.join("foo")) {
  Ok(()) => { assert!(targets(&a).is_err()); fs::remove_dir(a.join("foo")).unwrap(); }
  Err(e) => { assert_eq!(e.kind(),std::io::ErrorKind::AlreadyExists); assert_eq!(fs::canonicalize(a.join("Foo")).unwrap(),fs::canonicalize(a.join("foo")).unwrap()); }
 }
 fs::remove_dir(a.join("Foo")).unwrap();#[cfg(unix)]{std::os::unix::fs::symlink("/tmp",a.join("escape")).unwrap();assert!(targets(&a).is_err());}fs::remove_dir_all(p).unwrap();}

 #[test]fn identical_names_different_bundles_are_supported(){let(p,a)=setup("same-name");bundle(&a.join("PlugIns/X.appex"),"X",2);bundle(&a.join("Frameworks/F.framework"),"F",6);let lib=p.join("T.dylib");fs::write(&lib,fixture(6)).unwrap();inject_plan(&a,&[item("a",&lib,"Main"),item("b",&lib,"PlugIns/X.appex/X"),item("c",&lib,"Frameworks/F.framework/F")],&[],false,false).unwrap();for ex in["Main","PlugIns/X.appex/X","Frameworks/F.framework/F"]{assert!(dependencies(&a.join(ex)).unwrap()[0].ends_with("T.dylib"))}fs::remove_dir_all(p).unwrap();}

}
