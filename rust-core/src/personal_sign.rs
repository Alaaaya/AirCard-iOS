//! Profile-constrained personal signing. No network or Apple-ID mutation.
use apple_codesign_quick::{ProvisioningProfile, BundleSigningSettings, RustCryptoCmsSigner};
use base64::Engine;
use x509_cert::der::Decode;
use std::{path::{Path, PathBuf}, collections::BTreeMap, time::{SystemTime, UNIX_EPOCH}};
#[path = "personal_nested.rs"]
mod nested;
#[path = "personal_cms.rs"]
mod cms_verify;
fn err(e: impl std::fmt::Display) -> String { e.to_string() }
pub fn matches_id(pattern: &str, id: &str) -> bool {
    if let Some(prefix) = pattern.strip_suffix('*') {
        !prefix.contains('*') && id.starts_with(prefix)
    } else { pattern == id }
}
// Explicit profiles can sign exactly one bundle ID. Wildcards never rewrite.
fn resolved_bundle_id(pattern: &str, original: &str) -> Result<String, String> {
    let (prefix, allowed) = pattern.split_once('.')
        .ok_or("معرّف التطبيق في البروفايل غير صالح.")?;
    let valid = |value: &str| !value.is_empty() && value.split('.').all(|part|
        !part.is_empty() && part.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-'));
    if !valid(prefix) || !valid(original) {
        return Err("معرّف التطبيق أو البروفايل غير صالح.".into());
    }
    if pattern.contains('*') {
        let scope = allowed.strip_suffix('*').ok_or("نمط معرّف البروفايل غير مدعوم.")?;
        if scope.contains('*') || (!scope.is_empty() &&
            (!scope.ends_with('.') || !valid(scope.trim_end_matches('.')))) {
            return Err("نمط معرّف البروفايل غير مدعوم.".into());
        }
        if !matches_id(pattern, &format!("{prefix}.{original}")) {
            return Err("البروفايل ما بيسمح بمعرّف هالتطبيق.".into());
        }
        Ok(original.to_owned())
    } else if valid(allowed) {
        Ok(allowed.to_owned())
    } else {
        Err("معرّف التطبيق في البروفايل غير صالح.".into())
    }
}

// CMS authenticity is best effort per owner policy. Authorization is checked
// separately and remains mandatory. No request flag can fabricate verification.
#[derive(Default, serde::Serialize)]
pub(crate) struct Verification {
    pub profile_verification: String,
    pub device_authorization: String,
    pub warnings: Vec<serde_json::Value>,
}
pub(crate) fn profile_with_verification(bytes: &[u8], index: usize) -> Result<(ProvisioningProfile, Verification), String> {
    if bytes.is_empty() || bytes.len() > 256*1024 { return Err("حجم البروفايل غير صالح.".into()); }
    let parsed = ProvisioningProfile::parse(bytes).map_err(|_| "البروفايل غير صالح.")?;
    let verified = cms_verify::verify(bytes).ok().filter(|v| {
        plist::Value::from_reader(std::io::Cursor::new(&v.content)).ok()
            .and_then(|p| p.as_dictionary().cloned()).as_ref() == Some(parsed.plist())
    });
    let trusted = verified.as_ref().is_some_and(|v| {
        #[cfg(target_os = "ios")]
        unsafe {
            extern "C" { fn mirsa_verify_profile_signer_chain(signer: *const u8, signer_len: usize, chain: *const u8, chain_len: usize) -> i32; }
            mirsa_verify_profile_signer_chain(v.signer.as_ptr(),v.signer.len(),v.chain.as_ptr(),v.chain.len()) == 1
        }
        #[cfg(not(target_os = "ios"))]
        { let _ = v; false }
    });
    let mut status = Verification { profile_verification: if trusted { "verified" } else { "unverified" }.into(), warnings: vec![], device_authorization: "not_checked".into() };
    if !trusted { status.warnings.push(serde_json::json!({"code":"profile_cms_unverified", "message":"تحذير: ما قدرنا نتحقق من توقيع البروفايل وثقة Apple. التوقيع رح يكمل، بس البروفايل غير موثّق.","profile_index":index})); }
    Ok((parsed,status))
}
#[derive(Default, serde::Deserialize)]
pub(crate) struct Options {
    #[serde(default)] pub profiles: Vec<String>,
    #[serde(default)] pub pairing_path: String,
    #[serde(default)] pub remove_extensions: bool,
    #[serde(default)] pub remove_watch: bool,
    #[serde(default)] pub remove_app_clips: bool,
}
struct Profile { data: Vec<u8>, parsed: ProvisioningProfile }
pub(crate) fn validate_profile(p: &ProvisioningProfile, cert: &[u8], udid: &str, now: SystemTime) -> Result<(), String> {
    if udid.is_empty() || udid.len() > 128 || !udid.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
        return Err("وصل الجهاز الحقيقي أولاً للحصول على UDID والتحقق من البروفايل.".into());
    }
    let expiry: SystemTime = p.plist().get("ExpirationDate").and_then(plist::Value::as_date)
        .ok_or("البروفايل بلا تاريخ صلاحية.")?.into();
    if expiry <= now { return Err("انتهت صلاحية البروفايل.".into()); }
    let created: SystemTime = p.plist().get("CreationDate").and_then(plist::Value::as_date)
        .ok_or("البروفايل بلا تاريخ إنشاء.")?.into();
    if created > now { return Err("البروفايل لسا ما بلشت صلاحيته.".into()); }
    if !p.plist().get("ProvisionedDevices").and_then(plist::Value::as_array)
            .is_some_and(|ds| ds.iter().any(|d| d.as_string() == Some(udid))) {
        return Err("هالجهاز مو مضاف بالبروفايل. أضف UDID الجهاز واستورد البروفايل الجديد.".into());
    }
    if !p.plist().get("DeveloperCertificates").and_then(plist::Value::as_array)
        .is_some_and(|cs| cs.iter().any(|c| c.as_data() == Some(cert))) {
        return Err("الشهادة ما بتطابق هالبروفايل.".into());
    }
    if p.entitlements().get("com.apple.developer.team-identifier").and_then(plist::Value::as_string)
        .is_some_and(|t| t != p.team_id()) { return Err("فريق البروفايل غير متطابق.".into()); }
    Ok(())
}
fn validate_key_certificate(key: &[u8], cert: &x509_cert::Certificate) -> Result<(),String> {
    use rsa::{pkcs8::DecodePrivateKey, pkcs1::{DecodeRsaPrivateKey, DecodeRsaPublicKey}};
    let private = rsa::RsaPrivateKey::from_pkcs8_der(key)
        .or_else(|_| rsa::RsaPrivateKey::from_pkcs1_der(key)).map_err(|_| "المفتاح الخاص RSA غير صالح.")?;
    let algorithm = &cert.tbs_certificate.subject_public_key_info.algorithm;
    if algorithm.oid.to_string() != "1.2.840.113549.1.1.1" || algorithm.parameters.as_ref().is_some_and(|p| {
        use x509_cert::der::Encode;
        p.to_der().ok().as_deref() != Some(&[5,0])
    }) { return Err("نوع المفتاح العام بالشهادة غير مدعوم. استخدم شهادة RSA.".into()); }
    let bits = cert.tbs_certificate.subject_public_key_info.subject_public_key.as_bytes().ok_or("الشهادة غير صالحة.")?;
    let public = rsa::RsaPublicKey::from_pkcs1_der(bits).map_err(|_| "شهادة RSA غير صالحة.")?;
    if public != rsa::RsaPublicKey::from(&private) { return Err("المفتاح الخاص ما بيطابق الشهادة المختارة.".into()); }
    Ok(())
}
fn actual_udid(pairing_path: &str) -> Result<String,String> {
    // This API is blocking. Swift calls it on a detached worker, but direct
    // callers must not nest block_on in an active Tokio runtime. Return an
    // actionable error instead of relying on the outer FFI panic handler.
    if tokio::runtime::Handle::try_current().is_ok() {
        return Err("تعذّر التحقق من الجهاز ضمن مهمة شبكة شغّالة. أعد المحاولة من عامل توقيع مستقل.".into());
    }
    if pairing_path.is_empty() { return Err("وصل الجهاز وفعّل الاقتران أولاً للتحقق من UDID الحقيقي.".into()); }
    let bytes = std::fs::read(pairing_path).map_err(|_| "تعذّر قراءة ملف الاقتران.")?;
    let logger = crate::exploit::Logger { cb: None, ctx: std::ptr::null_mut() };
    let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build().map_err(err)?;
    rt.block_on(async {
        let tunnel = crate::exploit::connect_tunnel(&bytes,&logger).await?;
        let id = match &tunnel {
            crate::exploit::AppDeviceTunnel::Rsd { handshake,.. } => handshake.properties.get("UniqueDeviceID").and_then(|v|v.as_string()).map(str::to_owned).ok_or("الجهاز ما رجّع UDID حقيقي.".to_owned())?,
            crate::exploit::AppDeviceTunnel::Lockdown { provider,.. } => isideload::util::device::IdeviceInfo::from_device(provider).await.map_err(err)?.udid,
        };
        if id.is_empty() { return Err("الجهاز ما رجّع UDID حقيقي.".into()); }
        Ok(id)
    })
}
pub fn sign(app: &Path, profile_path: &Path, key: &str, cert: &str) -> Result<(), String> {
    sign_with_options(app, profile_path, key, cert, &Options::default()).map(|_| ())
}
pub(crate) fn sign_with_options(app: &Path, profile_path: &Path, key: &str, cert: &str, opts: &Options) -> Result<Verification, String> {
    // Reject links even for direct local requests, before trusting app paths.
    if std::fs::symlink_metadata(app).map_err(err)?.file_type().is_symlink() {
        return Err("روابط الملفات غير مدعومة.".into());
    }
    let mut files = Vec::new(); crate::ipa_editor::walk(app, &mut files)?;
    let decoder = base64::engine::general_purpose::STANDARD;
    let cert = decoder.decode(cert).map_err(|_| "بيانات الشهادة غير صالحة.")?;
    let x509 = x509_cert::Certificate::from_der(&cert).map_err(|_| "الشهادة غير صالحة.")?;
    let key = decoder.decode(key).map_err(|_| "المفتاح الخاص غير صالح.")?;
    validate_key_certificate(&key, &x509)?;
    let now = SystemTime::now();
    let secs = now.duration_since(UNIX_EPOCH).map_err(err)?.as_secs();
    if secs < x509.tbs_certificate.validity.not_before.to_unix_duration().as_secs()
        || secs >= x509.tbs_certificate.validity.not_after.to_unix_duration().as_secs() {
        return Err("الشهادة منتهية أو لسا ما بلشت صلاحيتها.".into());
    }
    if opts.profiles.len() > 128 { return Err("عدد البروفايلات كبير جداً.".into()); }
    let mut paths = vec![profile_path.to_path_buf()];
    paths.extend(opts.profiles.iter().map(PathBuf::from));
    paths.dedup();
    let target_udid = actual_udid(&opts.pairing_path)?;
    let mut profiles = Vec::new();
    let mut status = Verification { profile_verification: "verified".into(), warnings: vec![], device_authorization: "not_checked".into() };
    for (index,path) in paths.into_iter().enumerate() {
        let metadata = std::fs::metadata(&path).map_err(|_| "ملف البروفايل غير موجود.")?;
        if metadata.len() > 256 * 1024 { return Err("حجم البروفايل كبير جداً.".into()); }
        let data = std::fs::read(path).map_err(|_| "تعذّر قراءة البروفايل.")?;
        let (parsed,verification) = profile_with_verification(&data,index)?;
        if verification.profile_verification != "verified" { status.profile_verification = "unverified".into(); }
        status.warnings.extend(verification.warnings);
        validate_profile(&parsed, &cert, &target_udid, now)?;
        profiles.push(Profile { data, parsed });
    }
    let mut nodes = nested::inventory(app, opts)?;
    let main = nodes.iter().position(|n| n.path == app).ok_or("التطبيق الرئيسي مو موجود.")?;
    let main_original = nodes[main].id.clone();
    let main_patterns: Vec<_> = profiles.iter().map(|p| p.parsed.entitlements().get("application-identifier").and_then(plist::Value::as_string).unwrap_or("")).collect();
    let chosen = nested::select_profile(&main_patterns,&main_original).unwrap_or(0);
    let new_main = resolved_bundle_id(main_patterns[chosen], &main_original)?;
    let mapping = nested::id_map(&nodes, &main_original, &new_main)?;
    let team = profiles[chosen].parsed.team_id();
    let mut assignments = BTreeMap::new();
    let mut entitlements = BTreeMap::new();
    for node in &nodes {
        if node.framework { continue; }
        let id = mapping.get(&node.id).ok_or("معرّف تطبيق غير موجود.")?;
        let patterns: Vec<_> = profiles.iter().map(|p| p.parsed.entitlements().get("application-identifier")
            .and_then(plist::Value::as_string).unwrap_or("")).collect();
        let index = nested::select_profile(&patterns, id)
            .ok_or_else(|| format!("ما في بروفايل صالح للتطبيق {id}. استورد بروفايله أو احذف الإضافة من الخيارات."))?;
        let p = &profiles[index].parsed;
        if p.team_id() != team { return Err(format!("فريق البروفايل مختلف للتطبيق {id}.")); }
        let prefix = patterns[index].split_once('.').ok_or("معرّف البروفايل غير صالح.")?.0;
        let requested = nested::read_entitlements(&std::fs::read(node.executable()?).map_err(err)?)?;
        let constrained = nested::constrain(&requested, p.entitlements(), prefix, id, team, &mapping)
            .map_err(|e| format!("{id} - {e}"))?;
        assignments.insert(id.clone(), index);
        entitlements.insert(id.clone(), constrained);
    }
    // Validate every retained Mach-O before ANY rewrite/removal/signing.
    for file in files.iter().filter(|p| p.is_file() && !nested::removed(app, p, opts)) {
        nested::check_macho_file(file)?;
    }
    let signer = RustCryptoCmsSigner::from_der(&key, &cert, profiles[0].parsed.certificate_chain_der())
        .map_err(|_| "استخدم شهادة Apple RSA مع مفتاحها الخاص المطابق.")?;
    nested::apply_removals(app, opts)?;
    for node in &mut nodes { nested::rewrite(node, &mapping)?; }
    // Explicit deepest-first pass includes Watch/AppClips, which the vendored
    // library does not discover. Parent envelopes then hash their final bytes.
    // Frameworks/PlugIns may be signed again recursively with identical maps.
    nodes.sort_by_key(|n| std::cmp::Reverse(n.path.components().count()));
    for node in &nodes {
        let id = mapping.get(&node.id).unwrap_or(&node.id);
        let empty = plist::Dictionary::new();
        let mut settings = BundleSigningSettings::new(team, entitlements.get(id).unwrap_or(&empty).clone(), Some(&signer));
        settings.entitlements_by_bundle_id = entitlements.clone();
        for (bundle, index) in &assignments {
            settings.embedded_mobileprovisions_by_bundle_id.insert(bundle.clone(), &profiles[*index].data);
        }
        // Framework/dylib code receives neither app entitlements nor profile.
        if !node.framework { settings.embedded_mobileprovision = assignments.get(id).map(|i| profiles[*i].data.as_slice()); }
        apple_codesign_quick::sign_bundle(&node.path, &settings).map_err(|_| format!("تعذّر توقيع التطبيق {id}."))?;
    }
    status.device_authorization = "checked".into();
    Ok(status)
}
#[cfg(test)]
mod tests {
    use super::*;
    // Run in a subprocess so an unexpected native abort cannot kill the suite.
    // Previously this fixture panicked in Tokio block_on (exit 101).
    #[test]
    fn nested_runtime_udid_is_recoverable() {
        const CHILD: &str = "MIRSA_TEST_NESTED_UDID_CHILD";
        if std::env::var_os(CHILD).is_some() {
            let path = std::env::temp_dir().join(format!("mirsa-pairing-invalid-{}", std::process::id()));
            std::fs::write(&path, b"invalid pairing fixture").unwrap();
            let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
            let result = runtime.block_on(async { actual_udid(path.to_str().unwrap()) });
            std::fs::remove_file(path).unwrap();
            assert!(result.is_err());
            return;
        }
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "personal_sign::tests::nested_runtime_udid_is_recoverable", "--nocapture"])
            .env(CHILD, "1").output().unwrap();
        assert!(output.status.success(), "child {:?}: {}", output.status, String::from_utf8_lossy(&output.stderr));
    }
    #[test] fn explicit_profile_rewrites_only_bundle_suffix() {
        assert_eq!(resolved_bundle_id("OLDPREFIX.com.profile.app", "com.original.app").unwrap(), "com.profile.app");
        assert_eq!(resolved_bundle_id("TEAM.com.same", "com.same").unwrap(), "com.same");
    }
    #[test] fn wildcard_profile_preserves_original_and_scope() {
        assert_eq!(resolved_bundle_id("TEAM.*", "com.original.app").unwrap(), "com.original.app");
        assert_eq!(resolved_bundle_id("TEAM.com.example.*", "com.example.app").unwrap(), "com.example.app");
        assert!(resolved_bundle_id("TEAM.com.example.*", "com.other.app").is_err());
    }
    #[test] fn malformed_profiles_fail_closed() {
        for pattern in ["", "TEAM", ".com.app", "TEAM.", "TEAM.com..app", "TEAM.com.*.bad", "TEAM.com.bad*", "TE*AM.*", "TEAM.com/evil"] {
            assert!(resolved_bundle_id(pattern, "com.original.app").is_err(), "{pattern}");
        }
        assert!(resolved_bundle_id("TEAM.com.app", "").is_err());
    }
    #[test] fn invalid_profile_fails_closed() {
        let temp = std::env::temp_dir().join(format!("mirsa-invalid-profile-{}", std::process::id()));
        std::fs::write(&temp, b"not a signed provisioning profile").unwrap();
        let result = sign(Path::new("/nonexistent-app"), &temp, "private", "certificate");
        std::fs::remove_file(temp).unwrap();
        assert!(result.is_err());
    }
    #[test] fn profile_id_scope() {
        assert!(matches_id("ABC.com.example.*", "ABC.com.example.demo"));
        assert!(!matches_id("ABC.com.example.*", "ABC.com.examples.demo"));
        assert!(matches_id("ABC.*", "ABC.com.demo"));
        assert!(!matches_id("ABC.com.demo", "ABC.com.other"));
        assert!(!matches_id("A*B.*", "ABC.com.demo"));
    }
}
#[cfg(test)]
mod authorization_tests {
    use super::*;
    fn profile() -> ProvisioningProfile { profile_with_verification(include_bytes!("../tests/cms-fixtures/valid-test.der"),0).unwrap().0 }
    #[test] fn unsupported_cms_proceeds_with_explicit_warning() {
        let (_,v)=profile_with_verification(include_bytes!("../tests/cms-fixtures/unsupported-test.der"),2).unwrap();
        assert_eq!(v.profile_verification,"unverified"); assert_eq!(v.warnings.len(),1); assert_eq!(v.warnings[0]["profile_index"],2);
    }
    #[test] fn device_cert_and_expiry_remain_hard() {
        let p=profile(); let cert=include_bytes!("../tests/p12-fixtures/leaf.der");
        let now=UNIX_EPOCH+std::time::Duration::from_secs(1800000000);
        assert!(validate_profile(&p,cert,"REAL-TEST-DEVICE",now).is_ok());
        assert!(validate_profile(&p,cert,"WRONG",now).is_err());
        assert!(validate_profile(&p,cert,"",now).is_err());
        assert!(validate_profile(&p,b"wrong","REAL-TEST-DEVICE",now).is_err());
        assert!(validate_profile(&p,cert,"REAL-TEST-DEVICE",UNIX_EPOCH+std::time::Duration::from_secs(2200000000)).is_err());
    }
}

#[cfg(test)]
mod key_binding_tests {
    use super::*;
    #[test] fn selected_certificate_must_match_actual_private_key() {
        use isideload_p12_keystore::{KeyStore,KeyStoreEntry,Pkcs12ImportPolicy};
        let store=KeyStore::from_pkcs12(include_bytes!("../tests/p12-fixtures/modern.p12"),"mirsa-test",Pkcs12ImportPolicy::Raw).unwrap();
        let key=store.entries().find_map(|(_,e)| if let KeyStoreEntry::PrivateKeyChain(c)=e {Some(c.key().as_der().to_vec())} else {None}).unwrap();
        let cert=x509_cert::Certificate::from_der(include_bytes!("../tests/p12-fixtures/leaf.der")).unwrap();
        assert!(validate_key_certificate(&key,&cert).is_ok());
        use rsa::pkcs8::EncodePrivateKey;
        let n=rsa::BigUint::from(3233u32); let e=rsa::BigUint::from(17u32); let d=rsa::BigUint::from(2753u32);
        let wrong=rsa::RsaPrivateKey::from_components(n,e,d,vec![rsa::BigUint::from(61u32),rsa::BigUint::from(53u32)]).unwrap();
        let wrong=wrong.to_pkcs8_der().unwrap();
        assert!(validate_key_certificate(wrong.as_bytes(),&cert).is_err());
        let root=std::env::temp_dir().join(format!("mirsa-direct-key-mismatch-{}",std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("sentinel"),b"unchanged").unwrap();
        let b64=base64::engine::general_purpose::STANDARD;
        let result=sign_with_options(&root,Path::new("/nonexistent-profile"),&b64.encode(wrong.as_bytes()),&b64.encode(include_bytes!("../tests/p12-fixtures/leaf.der")),&Options::default());
        assert!(result.err().unwrap().contains("ما بيطابق"));
        assert_eq!(std::fs::read(root.join("sentinel")).unwrap(),b"unchanged");
        assert_eq!(std::fs::read_dir(&root).unwrap().count(),1);
        std::fs::remove_dir_all(root).unwrap();
    }
}
