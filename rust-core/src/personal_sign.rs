//! Personal signing uses supplied material only. No Apple ID session/network.
use apple_codesign_quick::{ProvisioningProfile, BundleSigningSettings, RustCryptoCmsSigner};
use base64::Engine;
use x509_cert::der::Decode;
use std::{path::Path, time::{SystemTime, UNIX_EPOCH}};

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
pub fn sign(app: &Path, profile_path: &Path, key: &str, cert: &str) -> Result<(), String> {
    let profile_data = std::fs::read(profile_path).map_err(err)?;
    if profile_data.len() > 256 * 1024 { return Err("Profile exceeds 256 KiB".into()); }
    let profile = ProvisioningProfile::parse(&profile_data).map_err(|_| "Invalid provisioning profile")?;
    let now = SystemTime::now();
    let expiry = profile.plist().get("ExpirationDate").and_then(plist::Value::as_date)
        .ok_or("Profile has no expiration date")?;
    let expires: SystemTime = expiry.into();
    if let Some(created) = profile.plist().get("CreationDate").and_then(plist::Value::as_date) {
        let created: SystemTime = created.into();
        if created > now { return Err("البروفايل لسا ما بلشت صلاحيته.".into()); }
    }
    if expires <= now { return Err("انتهت صلاحية البروفايل.".into()); }
    // App Store profiles cannot be used for local sideload installation.
    if profile.plist().get("ProvisionsAllDevices").and_then(plist::Value::as_boolean) != Some(true)
        && profile.plist().get("ProvisionedDevices").and_then(plist::Value::as_array).map_or(true, |d| d.is_empty()) {
        return Err("استخدم بروفايل تطوير أو Ad Hoc أو مؤسسات، مو App Store.".into());
    }
    let decoder = base64::engine::general_purpose::STANDARD;
    let cert = decoder.decode(cert).map_err(|_| "Invalid certificate data")?;
    let x509 = x509_cert::Certificate::from_der(&cert).map_err(|_| "Invalid certificate")?;
    let now_secs = now.duration_since(UNIX_EPOCH).map_err(err)?.as_secs();
    let validity = &x509.tbs_certificate.validity;
    if now_secs < validity.not_before.to_unix_duration().as_secs()
        || now_secs >= validity.not_after.to_unix_duration().as_secs() {
        return Err("الشهادة منتهية أو لسا ما بلشت صلاحيتها.".into());
    }
    let certs = profile.plist().get("DeveloperCertificates").and_then(plist::Value::as_array)
        .ok_or("Profile has no developer certificates")?;
    if !certs.iter().any(|v| v.as_data() == Some(cert.as_slice())) {
        return Err("الشهادة ما بتطابق هالبروفايل.".into());
    }
    let mut info = plist::Value::from_file(app.join("Info.plist")).map_err(err)?;
    let id = info.as_dictionary().and_then(|d| d.get("CFBundleIdentifier")).and_then(plist::Value::as_string)
        .ok_or("معرّف التطبيق مو موجود.")?;
    let mut entitlements = profile.entitlements().clone();
    let pattern = entitlements.get("application-identifier").and_then(plist::Value::as_string)
        .ok_or("البروفايل ما فيه معرّف تطبيق.")?.to_owned();
    // Prefix is not necessarily TeamIdentifier on older accounts.
    let prefix = pattern.split_once('.').ok_or("معرّف التطبيق في البروفايل غير صالح.")?.0;
    let resolved_id = resolved_bundle_id(&pattern, id)?;
    let rewritten = resolved_id != id;
    let app_id = format!("{prefix}.{resolved_id}");
    if !matches_id(&pattern, &app_id) { return Err("البروفايل ما بيسمح بمعرّف هالتطبيق.".into()); }
    entitlements.insert("application-identifier".into(), app_id.clone().into());
    if let Some(plist::Value::Array(groups)) = entitlements.get_mut("keychain-access-groups") {
        for group in groups {
            if let Some(s) = group.as_string() {
                if s == format!("{prefix}.*") { *group = app_id.clone().into(); }
                else if s.contains('*') { return Err("مجموعة Keychain في البروفايل غير مدعومة.".into()); }
            }
        }
    }
    // A separate profile is required per extension. Never silently sign one
    // with the parent's profile or remove user extensions.
    for path in ["PlugIns", "Watch", "AppClips"] {
        if app.join(path).exists() { return Err("التطبيق فيه إضافات أو تطبيق ساعة أو App Clips. بدهم بروفايلات منفصلة وما بيندعموا حالياً.".into()); }
    }
    // Inspect every Mach-O, not only the main executable. Bounded extraction
    // already rejected symlinks/special files and archive traversal.
    let mut files = Vec::new();
    crate::ipa_editor::walk(app, &mut files)?;
    for file in files.iter().filter(|p| p.is_file()) {
        use std::io::Read;
        let mut f = std::fs::File::open(file).map_err(err)?;
        let mut magic = [0u8; 4];
        if f.read_exact(&mut magic).is_ok() && matches!(magic,
            [0xcf,0xfa,0xed,0xfe] | [0xfe,0xed,0xfa,0xcf] |
            [0xce,0xfa,0xed,0xfe] | [0xfe,0xed,0xfa,0xce] |
            [0xca,0xfe,0xba,0xbe] | [0xbe,0xba,0xfe,0xca] |
            [0xca,0xfe,0xba,0xbf] | [0xbf,0xba,0xfe,0xca]) {
            crate::ipa_editor::unencrypted(&std::fs::read(file).map_err(err)?)?;
        }
        if file.file_name().and_then(|n| n.to_str()) == Some("Info.plist")
            && file.parent() != Some(app)
            && file.parent().and_then(|p| p.extension()).and_then(|e| e.to_str())
                .map_or(false, |e| matches!(e, "appex" | "app")) {
            return Err("التطبيقات والإضافات المضمّنة بدها بروفايلات منفصلة.".into());
        }
    }
    let key = decoder.decode(key).map_err(|_| "Invalid private key data")?;
    let signer = RustCryptoCmsSigner::from_der(&key, &cert, profile.certificate_chain_der())
        .map_err(|_| "Unsupported identity. Use an RSA Apple signing certificate with its private key")?;
    // Modify only the extracted temporary main app, after all validation.
    // Extension-bearing archives still fail closed above, before any rewrite.
    if rewritten {
        info.as_dictionary_mut().ok_or("ملف معلومات التطبيق غير صالح.")?
            .insert("CFBundleIdentifier".into(), resolved_id.into());
        info.to_file_xml(app.join("Info.plist")).map_err(err)?;
    }
    let mut settings = BundleSigningSettings::new(profile.team_id(), entitlements, Some(&signer));
    settings.embedded_mobileprovision = Some(&profile_data);
    apple_codesign_quick::sign_bundle(app, &settings).map_err(err)
}
#[cfg(test)]
mod tests {
    use super::*;
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
        assert!(result.unwrap_err().contains("Invalid provisioning profile"));
    }
    #[test] fn profile_id_scope() {
        assert!(matches_id("ABC.com.example.*", "ABC.com.example.demo"));
        assert!(!matches_id("ABC.com.example.*", "ABC.com.examples.demo"));
        assert!(matches_id("ABC.*", "ABC.com.demo"));
        assert!(!matches_id("ABC.com.demo", "ABC.com.other"));
        assert!(!matches_id("A*B.*", "ABC.com.demo"));
    }
}
