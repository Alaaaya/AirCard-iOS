//! Conservative nested signing plan. Pure policy helpers are separately testable.
use super::{Options, matches_id};
use std::{path::{Path, PathBuf}, collections::{BTreeMap, BTreeSet}, fs};
use plist::{Value, Dictionary};
type Result<T> = std::result::Result<T, String>;
fn error(e: impl std::fmt::Display) -> String { e.to_string() }
pub(super) struct Node { pub path: PathBuf, pub id: String, pub framework: bool, pub info: Value }
impl Node {
    pub fn executable(&self) -> Result<PathBuf> {
        let name = self.info.as_dictionary().and_then(|d| d.get("CFBundleExecutable"))
            .and_then(Value::as_string).ok_or("اسم الملف التنفيذي مو موجود.")?;
        if name.is_empty() || name.contains(['/', '\\', ':']) || name == "." || name == ".." {
            return Err("مسار الملف التنفيذي غير آمن.".into());
        }
        Ok(self.path.join(name))
    }
}
pub(super) fn removed(root: &Path, path: &Path, o: &Options) -> bool {
    let Ok(p) = path.strip_prefix(root) else { return false };
    p.components().any(|c| {
        let s = c.as_os_str().to_str().unwrap_or("");
        (o.remove_extensions && s == "PlugIns") || (o.remove_watch && s == "Watch")
            || (o.remove_app_clips && s == "AppClips")
    })
}
pub(super) fn inventory(root: &Path, o: &Options) -> Result<Vec<Node>> {
    let mut files = vec![]; crate::ipa_editor::walk(root, &mut files)?;
    let paths = std::iter::once(root.to_path_buf()).chain(files.into_iter().filter(|p|
        p.is_dir() && matches!(p.extension().and_then(|s| s.to_str()), Some("app" | "appex" | "framework"))));
    let mut nodes = vec![]; let mut ids = BTreeSet::new();
    for path in paths.filter(|p| !removed(root, p, o)) {
        let info = Value::from_file(path.join("Info.plist")).map_err(|_| "معلومات تطبيق مضمّن غير صالحة.")?;
        let id = info.as_dictionary().and_then(|d| d.get("CFBundleIdentifier"))
            .and_then(Value::as_string).ok_or("معرّف تطبيق مضمّن مو موجود.")?.to_owned();
        if !valid_id(&id) || !ids.insert(id.clone()) { return Err("معرّف تطبيق غير صالح أو مكرر.".into()); }
        let framework = path.extension().and_then(|s| s.to_str()) == Some("framework");
        let node = Node { path, id, framework, info }; node.executable()?; nodes.push(node);
        if nodes.len() > 256 { return Err("عدد التطبيقات المضمّنة كبير جداً.".into()); }
    }
    Ok(nodes)
}
pub(super) fn valid_id(id: &str) -> bool { !id.is_empty() && id.len() <= 255 && id.split('.').all(|s|
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')) }
pub(super) fn id_map(nodes: &[Node], old: &str, new: &str) -> Result<BTreeMap<String,String>> {
    let mut map = BTreeMap::new(); let mut seen = BTreeSet::new();
    for n in nodes {
        let id = if n.framework || old == new { n.id.clone() }
        else if n.id == old { new.to_owned() }
        else if let Some(suffix) = n.id.strip_prefix(&format!("{old}.")) { format!("{new}.{suffix}") }
        else { return Err(format!("معرّف الإضافة {} مو تابع للتطبيق الرئيسي. استخدم بروفايل بنفس معرّف التطبيق الأصلي.", n.id)); };
        if !valid_id(&id) || !seen.insert(id.clone()) { return Err("تعارض معرّفات التطبيقات بعد التعديل.".into()); }
        map.insert(n.id.clone(), id);
    }
    Ok(map)
}
pub(super) fn select_profile(patterns: &[&str], id: &str) -> Option<usize> {
    let mut candidates = vec![];
    for (i,p) in patterns.iter().enumerate() {
        let Some((prefix,scope)) = p.split_once('.') else { continue };
        if !valid_id(prefix) { continue; }
        let valid = if let Some(s) = scope.strip_suffix('*') {
            s.is_empty() || (s.ends_with('.') && valid_id(s.trim_end_matches('.')))
        } else { valid_id(scope) };
        if !valid || scope.matches('*').count() > 1 { continue; }
        if matches_id(p, &format!("{prefix}.{id}")) {
            candidates.push((!scope.contains('*'), scope.len(), std::cmp::Reverse(i), i));
        }
    }
    candidates.sort(); candidates.last().map(|c| c.3)
}
// Only documented identifier-bearing keys are changed, never arbitrary strings.
fn rewrite_refs(v: &mut Value, map: &BTreeMap<String,String>) {
    match v {
        Value::Dictionary(d) => for (k,v) in d.iter_mut() {
            if matches!(k.as_str(), "CFBundleIdentifier" | "WKCompanionAppBundleIdentifier" | "WKAppBundleIdentifier" | "NSExtensionContainingAppBundleIdentifier") {
                if let Some(new) = v.as_string().and_then(|s| map.get(s)) { *v = Value::String(new.clone()); }
            } else { rewrite_refs(v,map); }
        },
        Value::Array(a) => for v in a { rewrite_refs(v,map); },
        _ => ()
    }
}
pub(super) fn rewrite(n: &mut Node, map: &BTreeMap<String,String>) -> Result<()> {
    rewrite_refs(&mut n.info,map);
    n.info.to_file_xml(n.path.join("Info.plist")).map_err(error)?;
    // A framework must not carry an old app provisioning profile.
    let p = n.path.join("embedded.mobileprovision");
    if n.framework && p.exists() { fs::remove_file(p).map_err(error)?; }
    Ok(())
}
pub(super) fn apply_removals(root: &Path, o: &Options) -> Result<()> {
    let mut files = vec![]; crate::ipa_editor::walk(root,&mut files)?;
    files.sort_by_key(|p| p.components().count());
    for path in files {
        if removed(root,&path,o) && path.exists() {
            if path.is_dir() { fs::remove_dir_all(path).map_err(error)?; } else { fs::remove_file(path).map_err(error)?; }
        }
    }
    Ok(())
}
fn authorized(request: &Value, allowed: &Value) -> bool {
    match (request,allowed) {
        (Value::String(r),Value::String(a)) => matches_id(a,r),
        (Value::Array(rs),Value::Array(as_)) => rs.iter().all(|r| as_.iter().any(|a| authorized(r,a))),
        (Value::Dictionary(rs),Value::Dictionary(as_)) => rs.iter().all(|(k,r)| as_.get(k).is_some_and(|a| authorized(r,a))),
        _ => request == allowed
    }
}
pub(super) fn constrain(request: &Dictionary, allowed: &Dictionary, prefix: &str, id: &str, team: &str,
    map: &BTreeMap<String,String>) -> Result<Dictionary> {
    let mut out = Dictionary::new();
    // Never copy the full profile grant into the executable. Preserve requested
    // entitlements only if authorized; unknown/essential unsupported keys fail.
    for (k,v) in request {
        if matches!(k.as_str(), "application-identifier" | "com.apple.developer.team-identifier" ) { continue; }
        let mut v = v.clone();
        if k == "keychain-access-groups" {
            if let Value::Array(groups) = &mut v {
                for group in groups {
                    if let Some(s) = group.as_string() {
                        if let Some((_,old)) = s.split_once('.') {
                            if let Some(new) = map.get(old) { *group = format!("{prefix}.{new}").into(); }
                        }
                    }
                }
            }
        }
        if !allowed.get(k).is_some_and(|a| authorized(&v,a)) {
            return Err(format!("الصلاحية المطلوبة {k} مو موجودة بالبروفايل. استورد بروفايل يدعمها."));
        }
        out.insert(k.clone(),v);
    }
    out.insert("application-identifier".into(), format!("{prefix}.{id}").into());
    out.insert("com.apple.developer.team-identifier".into(), team.into());

    Ok(out)
}
fn be(d: &[u8], at: usize) -> Result<u32> { d.get(at..at+4).and_then(|s| s.try_into().ok()).map(u32::from_be_bytes).ok_or("توقيع Mach-O غير صالح.".into()) }
fn le(d: &[u8], at: usize) -> Result<u32> { d.get(at..at+4).and_then(|s| s.try_into().ok()).map(u32::from_le_bytes).ok_or("ملف Mach-O غير صالح.".into()) }
fn signature_entitlements(d: &[u8]) -> Result<Dictionary> {
    if be(d,0)? != 0xfade0cc0 { return Err("صيغة توقيع التطبيق غير مدعومة.".into()); }
    let len = be(d,4)? as usize; let count = be(d,8)? as usize;
    if len > d.len() || count > 1024 || 12+count*8 > len { return Err("جدول توقيع غير صالح.".into()); }
    let d = &d[..len]; let mut result = None; let mut der_only = false;
    for i in 0..count {
        let kind = be(d,12+i*8)?;
        let offset = be(d,16+i*8)? as usize;
        let magic = be(d,offset)?; let size = be(d,offset+4)? as usize;
        if offset < 12+count*8 || size < 8 || size > d.len().saturating_sub(offset) { return Err("حدود توقيع غير صالحة.".into()); }
        if kind == 5 {
            if magic != 0xfade7171 || result.is_some() { return Err("صلاحيات توقيع غير صالحة.".into()); }
            let value = Value::from_reader(std::io::Cursor::new(&d[offset+8..offset+size])).map_err(|_| "تعذّر قراءة صلاحيات التطبيق.")?;
            result = Some(value.into_dictionary().ok_or("صلاحيات التطبيق غير صالحة.")?);
        }
        if kind == 7 { der_only = true; }
    }
    if der_only && result.is_none() { return Err("صلاحيات DER فقط غير مدعومة بأمان حالياً.".into()); }
    Ok(result.unwrap_or_default())
}
pub(super) fn read_entitlements(d: &[u8]) -> Result<Dictionary> {
    crate::ipa_editor::unencrypted(d).map_err(|_| "ملف IPA مشفّر أو ملف Mach-O غير مدعوم. استخدم IPA غير مشفّر.")?;
    let magic = be(d,0)?;
    if magic == 0xcafebabe || magic == 0xcafebabf {
        let stride = if magic == 0xcafebabf {32} else {20}; let count = be(d,4)? as usize;
        let mut result = None;
        for i in 0..count {
            let a = 8+i*stride;
            let (off,len) = if stride == 20 { (be(d,a+8)? as usize,be(d,a+12)? as usize) }
                else { (usize::try_from(u64::from_be_bytes(d[a+8..a+16].try_into().unwrap())).map_err(error)?,
                        usize::try_from(u64::from_be_bytes(d[a+16..a+24].try_into().unwrap())).map_err(error)?) };
            let ent = read_entitlements(&d[off..off+len])?;
            if result.as_ref().is_some_and(|r| r != &ent) { return Err("صلاحيات شرائح التطبيق مختلفة.".into()); }
            result = Some(ent);
        }
        return Ok(result.unwrap_or_default());
    }
    let mut at = 32; let mut found = None;
    for _ in 0..le(d,16)? {
        let size = le(d,at+4)? as usize;
        if le(d,at)? == 0x1d {
            if size < 16 || found.is_some() { return Err("أمر توقيع غير صالح.".into()); }
            let off = le(d,at+8)? as usize; let len = le(d,at+12)? as usize;
            let sig = d.get(off..off.checked_add(len).ok_or("تجاوز حدود التوقيع.")?).ok_or("حدود التوقيع غير صالحة.")?;
            found = Some(signature_entitlements(sig)?);
        }
        at += size;
    }
    Ok(found.unwrap_or_default())
}
pub(super) fn check_macho_file(path: &Path) -> Result<()> {
    use std::io::Read;
    let mut file = fs::File::open(path).map_err(error)?; let mut magic = [0;4];
    if file.read_exact(&mut magic).is_ok() && matches!(magic,
        [0xcf,0xfa,0xed,0xfe] | [0xfe,0xed,0xfa,0xcf] | [0xce,0xfa,0xed,0xfe] | [0xfe,0xed,0xfa,0xce] |
        [0xca,0xfe,0xba,0xbe] | [0xbe,0xba,0xfe,0xca] | [0xca,0xfe,0xba,0xbf] | [0xbf,0xba,0xfe,0xca]) {
        crate::ipa_editor::unencrypted(&fs::read(path).map_err(error)?)
            .map_err(|_| "ملف IPA مشفّر أو غير مدعوم. استخدم نسخة غير مشفّرة، ما منقدر نفك التشفير.".to_string())?;
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn exact_then_scoped_wildcard() {
        assert_eq!(select_profile(&["TEAM.*","TEAM.com.test.*","TEAM.com.test.app"],"com.test.app"),Some(2));
        assert_eq!(select_profile(&["TEAM.*","TEAM.com.test.*"],"com.test.app"),Some(1));
        assert_eq!(select_profile(&["TEAM.com.test.*"],"com.other.app"),None);
    }
    #[test] fn unauthorized_entitlements_fail() {
        let mut r=Dictionary::new(); r.insert("essential".into(),true.into());
        assert!(constrain(&r,&Dictionary::new(),"TEAM","com.test","TEAM",&BTreeMap::new()).is_err());
    }
    #[test] fn references_only_rewrite_known_keys() {
        let mut v=Value::Dictionary(Dictionary::new()); let d=v.as_dictionary_mut().unwrap();
        d.insert("WKCompanionAppBundleIdentifier".into(),"com.old".into()); d.insert("arbitrary".into(),"com.old".into());
        rewrite_refs(&mut v,&BTreeMap::from([("com.old".into(),"com.new".into())]));
        assert_eq!(v.as_dictionary().unwrap()["WKCompanionAppBundleIdentifier"].as_string(),Some("com.new"));
        assert_eq!(v.as_dictionary().unwrap()["arbitrary"].as_string(),Some("com.old"));
    }
}
#[cfg(test)]
mod removal_tests {
    use super::*;
    #[test] fn explicit_removal_scope() {
        let root=Path::new("/test/Main.app");
        let o=Options { remove_extensions:true,..Default::default() };
        assert!(removed(root,&root.join("PlugIns/A.appex/main"),&o));
        assert!(!removed(root,&root.join("Watch/A.app/main"),&o));
        assert!(!removed(root,&root.join("Frameworks/F.framework/main"),&o));
        assert!(!removed(root,Path::new("/other/PlugIns/A.appex"),&o));
    }
}
