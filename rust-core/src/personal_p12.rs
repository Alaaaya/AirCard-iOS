// Local-only decoding. Raw policy avoids subject-chain traversal on untrusted
// input; identity selection compares RSA public keys, never bag names/order.
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use isideload_p12_keystore::{KeyStore, KeyStoreEntry, Pkcs12ImportPolicy, error::Error};
use rsa::{RsaPrivateKey, RsaPublicKey, pkcs8::DecodePrivateKey, pkcs1::DecodeRsaPublicKey};
use x509_cert::der::Decode;
use std::ffi::{c_char, CStr, CString};

fn decode(p12: &[u8], password: &str, allowed: &[Vec<u8>]) -> Result<(Vec<u8>, Vec<u8>), &'static str> {
    if p12.is_empty() || p12.len() > 1024*1024 { return Err("invalid"); }
    let store = KeyStore::from_pkcs12(p12, password.trim(), Pkcs12ImportPolicy::Raw).map_err(|e| match e {
        Error::MacError(_) => "password",
        Error::UnsupportedEncryptionScheme | Error::UnsupportedMacAlgorithm | Error::Pkcs5Error(_) => "encryption",
        _ => "invalid",
    })?;
    let mut pairs = Vec::new();
    let certs: Vec<_> = store.entries().filter_map(|(_,e)| if let KeyStoreEntry::Certificate(c)=e {Some(c)}else{None}).collect();
    for (_, entry) in store.entries() {
        if let KeyStoreEntry::PrivateKeyChain(chain) = entry {
            let key = RsaPrivateKey::from_pkcs8_der(chain.key().as_der()).map_err(|_| "key_type")?;
            let public = RsaPublicKey::from(&key);
            for cert in &certs {
                let x = x509_cert::Certificate::from_der(cert.as_der()).map_err(|_| "invalid")?;
                let Some(bits) = x.tbs_certificate.subject_public_key_info.subject_public_key.as_bytes() else {continue};
                if RsaPublicKey::from_pkcs1_der(bits).ok().as_ref() == Some(&public) {
                    pairs.push((chain.key().as_der().to_vec(), cert.as_der().to_vec()));
                }
            }
        }
    }
    pairs.sort(); pairs.dedup();
    if pairs.is_empty() { return Err("no_identity"); }
    let mut matching: Vec<_> = pairs.into_iter().filter(|(_,c)| allowed.contains(c)).collect();
    match matching.len() {
        0 => Err("profile_mismatch"),
        1 => Ok(matching.remove(0)),
        _ => Err("multiple_identities"),
    }
}
#[derive(serde::Deserialize)]
struct Request { p12: String, password: String, profile: String }
fn process(text: &str) -> Result<serde_json::Value, &'static str> {
    if text.len()>2*1024*1024 {return Err("invalid")}
    let r: Request = serde_json::from_str(text).map_err(|_|"invalid")?;
    let data=B64.decode(r.p12).map_err(|_|"invalid")?;
    let profile=B64.decode(r.profile).map_err(|_|"profile")?;
    if profile.len()>256*1024 {return Err("profile")}
    let profile=apple_codesign_quick::ProvisioningProfile::parse(&profile).map_err(|_|"profile")?;
    let allowed=profile.plist().get("DeveloperCertificates").and_then(plist::Value::as_array).ok_or("profile")?
        .iter().filter_map(|v|v.as_data().map(Vec::from)).collect::<Vec<_>>();
    let (key,cert)=decode(&data,&r.password,&allowed)?;
    Ok(serde_json::json!({"ok":true,"key":B64.encode(key),"certificate":B64.encode(cert)}))
}
/// Local memory-only boundary; response is released with al_string_free.
/// Safety: request must be a valid NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn al_personal_p12_import(request:*const c_char)->*mut c_char {
    let result=std::panic::catch_unwind(||{
        if request.is_null(){return Err("invalid")}
        process(CStr::from_ptr(request).to_str().map_err(|_|"invalid")?)
    }).unwrap_or(Err("invalid"));
    let json=match result {Ok(v)=>v,Err(code)=>serde_json::json!({"ok":false,"code":code})};
    CString::new(json.to_string()).unwrap().into_raw()
}
#[cfg(test)]
mod tests {
    use super::*;
    const PASSWORD: &str="mirsa-test";
    fn fixture(name: &str)->Vec<u8>{std::fs::read(format!("{}/tests/p12-fixtures/{name}",env!("CARGO_MANIFEST_DIR"))).unwrap()}
    #[test] fn variants_and_chain(){
        let leaf=fixture("leaf.der");
        for name in ["legacy.p12","modern.p12","chain.p12"] {
            let (_,cert)=decode(&fixture(name),PASSWORD,&[leaf.clone()]).unwrap();
            assert_eq!(cert,leaf);
        }
    }
    #[test] fn multiple_identity_selection(){
        use isideload_p12_keystore::{PrivateKeyChain, PrivateKey, Certificate};
        let one=KeyStore::from_pkcs12(&fixture("modern.p12"),PASSWORD,Pkcs12ImportPolicy::Raw).unwrap();
        let key=one.entries().find_map(|(_,e)|if let KeyStoreEntry::PrivateKeyChain(c)=e{Some(c.key().clone())}else{None}).unwrap();
        let cert=fixture("leaf.der");
        let mut store=KeyStore::new();
        store.add_entry("key",KeyStoreEntry::PrivateKeyChain(PrivateKeyChain::new("key",PrivateKey::from_der(key.as_der()).unwrap(),Vec::<Certificate>::new())));
        store.add_entry("leaf",KeyStoreEntry::Certificate(Certificate::from_der(&cert).unwrap()));
        store.add_entry("other",KeyStoreEntry::Certificate(Certificate::from_der(&fixture("alternate.der")).unwrap()));
        let data=store.writer(PASSWORD).write().unwrap();
        assert_eq!(decode(&data,PASSWORD,&[cert.clone()]).unwrap().1,cert);
        assert_eq!(decode(&data,PASSWORD,&[cert,fixture("alternate.der")]).unwrap_err(),"multiple_identities");
    }
    #[test] fn trims_password(){assert!(decode(&fixture("modern.p12"),"  mirsa-test\n",&[fixture("leaf.der")]).is_ok());}
    #[test] fn wrong_password(){assert_eq!(decode(&fixture("modern.p12"),"wrong",&[fixture("leaf.der")]).unwrap_err(),"password");}
    #[test] fn profile_mismatch(){assert_eq!(decode(&fixture("modern.p12"),PASSWORD,&[]).unwrap_err(),"profile_mismatch");}
    #[test] fn no_identity(){assert_eq!(decode(&fixture("cert-only.p12"),PASSWORD,&[]).unwrap_err(),"no_identity");}
}
