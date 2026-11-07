//! Read-only display metadata. Presence is never certificate trust or install eligibility.
use std::{fs, path::Path};
use plist::{Dictionary, Value};
use serde_json::{json, Value as Json};
use apple_codesign_quick::ProvisioningProfile;
use x509_cert::der::{Decode, Encode};
type Result<T> = std::result::Result<T, String>;
fn error(e: impl std::fmt::Display) -> String { e.to_string() }
fn read(path: &Path, limit: u64) -> Result<Vec<u8>> {
    let m = fs::symlink_metadata(path).map_err(error)?;
    if !m.is_file() || m.len() > limit { return Err("Preview file exceeds limits".into()); }
    fs::read(path).map_err(error)
}
fn u32be(d: &[u8], at: usize) -> Result<usize> {
    Ok(u32::from_be_bytes(d.get(at..at+4).ok_or("Truncated signature")?.try_into().map_err(error)?) as usize)
}
fn u32le(d: &[u8], at: usize) -> Result<usize> {
    Ok(u32::from_le_bytes(d.get(at..at+4).ok_or("Truncated Mach-O")?.try_into().map_err(error)?) as usize)
}
// Existing archive/Mach-O validator runs first. Preflight entitlement plist depth
// before the existing signing reader builds a recursive plist Value.
fn preflight(d: &[u8]) -> Result<bool> {
    crate::ipa_editor::unencrypted(d)?;
    let magic = u32be(d,0)?;
    if magic == 0xcafebabe || magic == 0xcafebabf {
        let stride = if magic == 0xcafebabf {32} else {20};
        let mut present = true;
        for i in 0..u32be(d,4)? {
            let a = 8+i*stride;
            let (off,len) = if stride == 20 {(u32be(d,a+8)?,u32be(d,a+12)?)} else {
                let num = |p| -> Result<usize> { usize::try_from(u64::from_be_bytes(d.get(p..p+8).ok_or("Invalid FAT")?.try_into().map_err(error)?)).map_err(error) };
                (num(a+8)?,num(a+16)?)
            };
            present &= preflight(d.get(off..off.checked_add(len).ok_or("FAT overflow")?).ok_or("Invalid FAT")?)?;
        }
        return Ok(present);
    }
    let mut at = 32; let mut present = false;
    for _ in 0..u32le(d,16)? {
        if u32le(d,at)? == 0x1d {
            if present || u32le(d,at+4)? < 16 { return Err("Invalid signature command".into()); }
            let off = u32le(d,at+8)?; let len = u32le(d,at+12)?;
            if len > 16*1024*1024 { return Err("Signature exceeds preview limit".into()); }
            let sig = d.get(off..off.checked_add(len).ok_or("Signature overflow")?).ok_or("Invalid signature bounds")?;
            if u32be(sig,0)? != 0xfade0cc0 { return Err("Unsupported signature".into()); }
            let total = u32be(sig,4)?; let n = u32be(sig,8)?;
            if total > sig.len() || n > 1024 || 12+n*8 > total { return Err("Invalid signature index".into()); }
            let sig = &sig[..total];
            for i in 0..n {
                let kind = u32be(sig,12+i*8)?; let p = u32be(sig,16+i*8)?;
                let size = u32be(sig,p+4)?;
                if p < 12+n*8 || size < 8 || size > sig.len().saturating_sub(p) { return Err("Invalid signature slot".into()); }
                if kind == 5 {
                    if size > 256*1024 { return Err("Entitlements exceed preview limit".into()); }
                    super::pairing_structure(&sig[p+8..p+size])?;
                }
            }
            present = true;
        }
        at += u32le(d,at+4)?;
    }
    Ok(present)
}
fn rows(dict: &Dictionary) -> Result<Json> {
    if dict.len() > 512 { return Err("Too many entitlements".into()); }
    let rows: Vec<Json> = dict.iter().map(|(k,v)| {
        let value = match v { Value::String(s) => s.clone(), _ => serde_json::to_string(v).unwrap_or_default() };
        json!({"key":k,"value":value})
    }).collect();
    Ok(json!(rows))
}
fn profile(bytes: &[u8]) -> Result<Json> {
    if bytes.len() > 256*1024 { return Err("Profile exceeds preview limit".into()); }
    // Reuse maintained CMS and profile parsers, bounded stream before Value.
    let ci = cms::content_info::ContentInfo::from_der(bytes).map_err(error)?;
    let sd = cms::signed_data::SignedData::from_der(&ci.content.to_der().map_err(error)?).map_err(error)?;
    let content = sd.encap_content_info.econtent.ok_or("No embedded profile plist")?;
    super::pairing_structure(content.value())?;
    let p = ProvisioningProfile::parse(bytes).map_err(error)?;
    let text = |key| p.plist().get(key).and_then(Value::as_string).unwrap_or("").to_owned();
    let names: Vec<String> = p.plist().get("DeveloperCertificates").and_then(Value::as_array).into_iter().flatten().filter_map(|v| {
        let cert = x509_cert::Certificate::from_der(v.as_data()?).ok()?;
        cert.tbs_certificate.subject.0.iter().flat_map(|rdn| rdn.0.iter()).find_map(|a| {
            if a.oid.to_string() == "2.5.4.3" { std::str::from_utf8(a.value.value()).ok().map(str::to_owned) } else { None }
        })
    }).collect();
    let uuid = text("UUID");
    let chars: Vec<char> = uuid.chars().collect();
    let short = if chars.len()>12 { format!("{}…{}", chars[..6].iter().collect::<String>(), chars[chars.len()-4..].iter().collect::<String>()) } else { uuid };
    Ok(json!({"name":text("Name"),"shortID":short,"certificateNames":names,"entitlements":rows(p.entitlements())?}))
}
pub(crate) fn inspect_profile(input: &Path, output: &Path) -> Result<()> {
    let p = profile(&read(input,256*1024)?)?;
    fs::write(output,serde_json::to_vec(&p).map_err(error)?).map_err(error)
}
pub(crate) fn inspect(app: &Path, output: &Path) -> Result<()> {
    let info_data = read(&app.join("Info.plist"),4*1024*1024)?;
    super::pairing_structure(&info_data)?;
    let info = Value::from_reader(std::io::Cursor::new(info_data)).map_err(error)?;
    let exe = info.as_dictionary().and_then(|p|p.get("CFBundleExecutable")).and_then(Value::as_string).ok_or("Missing executable")?;
    if exe.is_empty() || exe.contains(['/', '\\', ':']) || exe=="." || exe==".." { return Err("Unsafe executable".into()); }
    let data = read(&app.join(exe),512*1024*1024)?;
    let result = (|| -> Result<Json> {
        crate::ipa_editor::unencrypted(&data)?;
        let present = preflight(&data)?;
        let ent = super::nested::read_entitlements(&data)?;
        Ok(json!({"signaturePresent":present,"entitlements":rows(&ent)?}))
    })();
    let mut out = result.unwrap_or_else(|_| json!({"signaturePresent":null,"entitlements":[],"entitlementsUnavailable":true}));
    let path = app.join("embedded.mobileprovision");
    if path.exists() {
        match read(&path,256*1024).and_then(|d|profile(&d)) {
            Ok(p) => out["embeddedProfile"]=p,
            Err(_) => out["profileUnavailable"]=json!(true)
        }
    }
    let bytes = serde_json::to_vec(&out).map_err(error)?;
    if bytes.len()>2*1024*1024 { return Err("Preview exceeds limits".into()); }
    fs::write(output,bytes).map_err(error)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn truncated_signature_fails() { for n in 0..40 { assert!(preflight(&vec![0;n]).is_err()); } }
    #[test] fn profile_fixture_is_real_and_short() {
        let p=profile(include_bytes!("../tests/cms-fixtures/valid-test.der")).unwrap();
        assert!(p["entitlements"].is_array());
        assert!(p["shortID"].as_str().unwrap().chars().count()<=12);
        assert!(!p.to_string().contains("ProvisionedDevices"));
    }
    #[test] fn real_signed_macho_entitlements() {
        let d=include_bytes!("../tests/fixtures/incoming/SignedFixture.macho").to_vec();
        assert!(preflight(&d).unwrap());
        let e=super::super::nested::read_entitlements(&d).unwrap();
        assert_eq!(e.get("application-identifier").and_then(Value::as_string),Some("MIRSATEST.com.mirsa.loader.fixture"));
    }
    #[test] fn unsigned_header_and_signature_bounds() {
        let mut d=vec![0u8;32]; d[..4].copy_from_slice(&0xfeedfacfu32.to_le_bytes());
        assert!(!preflight(&d).unwrap());
        d[16..20].copy_from_slice(&1u32.to_le_bytes());
        d[20..24].copy_from_slice(&16u32.to_le_bytes());d.resize(48,0);
        d[32..36].copy_from_slice(&0x1du32.to_le_bytes());d[36..40].copy_from_slice(&16u32.to_le_bytes());
        d[40..44].copy_from_slice(&u32::MAX.to_le_bytes());d[44..48].copy_from_slice(&32u32.to_le_bytes());
        assert!(preflight(&d).is_err());
    }
    #[test] fn extracted_real_fixture_preview_preserves_input() {
        let root=std::env::temp_dir().join(format!("incoming-fixture-{}",std::process::id()));
        let _=fs::remove_dir_all(&root);fs::create_dir_all(&root).unwrap();
        let macho=include_bytes!("../tests/fixtures/incoming/SignedFixture.macho");
        fs::write(root.join("Main"),macho).unwrap();
        let info: Dictionary=[("CFBundleExecutable".to_string(),Value::String("Main".into()))].into_iter().collect();
        Value::Dictionary(info).to_file_xml(root.join("Info.plist")).unwrap();
        fs::write(root.join("embedded.mobileprovision"),include_bytes!("../tests/cms-fixtures/valid-test.der")).unwrap();
        let out=root.join("preview.json");inspect(&root,&out).unwrap();
        let json:Json=serde_json::from_slice(&fs::read(&out).unwrap()).unwrap();
        assert_eq!(json["signaturePresent"],true);
        assert!(json["embeddedProfile"]["entitlements"].is_array());
        assert!(json["entitlements"].as_array().unwrap().iter().any(|r|r["key"]=="application-identifier"));
        assert_eq!(fs::read(root.join("Main")).unwrap(),macho);
        fs::remove_dir_all(root).unwrap();
    }
    #[test] #[cfg(unix)] fn preview_rejects_symlink_source() {
        let root=std::env::temp_dir().join(format!("incoming-link-{}",std::process::id()));
        let _=fs::remove_dir_all(&root);fs::create_dir_all(&root).unwrap();
        fs::write(root.join("real"),b"data").unwrap();
        std::os::unix::fs::symlink(root.join("real"),root.join("link")).unwrap();
        assert!(read(&root.join("link"),100).is_err());fs::remove_dir_all(root).unwrap();
    }
    #[test] fn malformed_profile_rejected() { assert!(profile(b"not cms").is_err()); assert!(profile(&vec![0;256*1024+1]).is_err()); }
    #[test] fn malicious_deep_entitlements_rejected() {
        let xml=format!("<?xml version=\"1.0\"?><plist version=\"1.0\">{}<true/>{}</plist>","<array>".repeat(40),"</array>".repeat(40));
        assert!(super::super::pairing_structure(xml.as_bytes()).is_err());
    }
}
