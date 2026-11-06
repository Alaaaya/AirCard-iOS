//! CMS cryptography only. Apple role/anchor policy is a separate mandatory gate.
use cms::{content_info::ContentInfo, signed_data::{SignedData, SignerIdentifier}, cert::CertificateChoices};
use x509_cert::der::{Decode, Encode, asn1::{ObjectIdentifier, OctetString}};
use rsa::{pkcs8::DecodePublicKey, signature::Verifier, pkcs1v15::{VerifyingKey, Signature}};
use sha2::Digest;
type Result<T> = std::result::Result<T, String>;
fn bad(_: impl std::fmt::Display) -> String { "توقيع البروفايل غير صالح أو غير مدعوم.".into() }
fn require(ok: bool) -> Result<()> { if ok { Ok(()) } else { Err(bad("")) } }
pub(super) struct Verified { pub content: Vec<u8>, pub signer: Vec<u8>, pub chain: Vec<u8> }
fn null_or_absent(a: &Option<x509_cert::der::Any>) -> bool {
    a.as_ref().is_none_or(|a| a.to_der().ok().as_deref() == Some(&[5,0]))
}
pub(super) fn verify(bytes: &[u8]) -> Result<Verified> {
    require(!bytes.is_empty() && bytes.len() <= 256*1024)?;
    let ci = ContentInfo::from_der(bytes).map_err(bad)?;
    require(ci.content_type.to_string() == "1.2.840.113549.1.7.2")?;
    let sd = ci.content.decode_as::<SignedData>().map_err(bad)?;
    require(sd.signer_infos.0.len() == 1 && sd.digest_algorithms.len() == 1)?;
    let si = sd.signer_infos.0.iter().next().ok_or_else(|| bad(""))?;
    require(sd.digest_algorithms.iter().next() == Some(&si.digest_alg))?;
    require(null_or_absent(&si.digest_alg.parameters) && null_or_absent(&si.signature_algorithm.parameters))?;
    require(sd.encap_content_info.econtent_type.to_string() == "1.2.840.113549.1.7.1")?;
    let content = sd.encap_content_info.econtent.as_ref().ok_or_else(|| bad(""))?
        .decode_as::<OctetString>().map_err(bad)?.as_bytes().to_vec();
    let digest_oid = si.digest_alg.oid.to_string();
    let digest = match digest_oid.as_str() {
        "1.3.14.3.2.26" => sha1::Sha1::digest(&content).to_vec(),
        "2.16.840.1.101.3.4.2.1" => sha2::Sha256::digest(&content).to_vec(),
        _ => return Err(bad("")),
    };
    let attrs = si.signed_attrs.as_ref().ok_or_else(|| bad(""))?;
    let mut seen = std::collections::BTreeSet::new();
    let mut has_type = false; let mut has_digest = false;
    for a in attrs.iter() {
        require(seen.insert(a.oid))?;
        if a.oid.to_string() == "1.2.840.113549.1.9.3" {
            require(a.values.len() == 1)?;
            let value = a.values.iter().next().unwrap().decode_as::<ObjectIdentifier>().map_err(bad)?;
            require(value == sd.encap_content_info.econtent_type)?; has_type = true;
        }
        if a.oid.to_string() == "1.2.840.113549.1.9.4" {
            require(a.values.len() == 1)?;
            let value = a.values.iter().next().unwrap().decode_as::<OctetString>().map_err(bad)?;
            require(value.as_bytes() == digest)?; has_digest = true;
        }
    }
    require(has_type && has_digest)?;
    let certs = sd.certificates.as_ref().ok_or_else(|| bad(""))?;
    require(!certs.0.is_empty() && certs.0.len() <= 16)?;
    let mut selected = None; let mut chain = Vec::new();
    for choice in certs.0.iter() {
        let CertificateChoices::Certificate(cert) = choice else { return Err(bad("")); };
        let der = cert.to_der().map_err(bad)?;
        require(der.len() <= 65536)?;
        chain.extend_from_slice(&(der.len() as u32).to_be_bytes()); chain.extend_from_slice(&der);
        let matches = match &si.sid {
            SignerIdentifier::IssuerAndSerialNumber(s) => cert.tbs_certificate.issuer == s.issuer
                && cert.tbs_certificate.serial_number == s.serial_number,
            SignerIdentifier::SubjectKeyIdentifier(s) => {
                let mut matches = false;
                if let Some(exts) = &cert.tbs_certificate.extensions {
                    let es: Vec<_> = exts.iter().filter(|e| e.extn_id.to_string() == "2.5.29.14").collect();
                    require(es.len() <= 1)?;
                    if let Some(e) = es.first() {
                        matches = OctetString::from_der(e.extn_value.as_bytes()).map_err(bad)?.as_bytes() == s.0.as_bytes();
                    }
                }
                matches
            }
        };
        if matches { require(selected.is_none())?; selected = Some((cert,der)); }
    }
    let (cert,signer) = selected.ok_or_else(|| bad(""))?;
    let key = rsa::RsaPublicKey::from_public_key_der(&cert.tbs_certificate.subject_public_key_info.to_der().map_err(bad)?).map_err(bad)?;
    use rsa::traits::PublicKeyParts;
    require(key.n().bits() >= 2048 && key.n().bits() <= 8192)?;
    let signature = Signature::try_from(si.signature.as_bytes()).map_err(bad)?;
    let message = attrs.to_der().map_err(bad)?;
    let alg = si.signature_algorithm.oid.to_string();
    match digest_oid.as_str() {
        "1.3.14.3.2.26" => { require(alg == "1.2.840.113549.1.1.1" || alg == "1.2.840.113549.1.1.5")?;
            VerifyingKey::<sha1::Sha1>::new(key).verify(&message,&signature).map_err(bad)?; }
        "2.16.840.1.101.3.4.2.1" => { require(alg == "1.2.840.113549.1.1.1" || alg == "1.2.840.113549.1.1.11")?;
            VerifyingKey::<sha2::Sha256>::new(key).verify(&message,&signature).map_err(bad)?; }
        _ => return Err(bad("")),
    }
    require(chain.len() <= 256*1024)?;
    Ok(Verified { content, signer, chain })
}
#[cfg(test)]
mod tests {
    use super::*;
    const VALID: &[u8] = include_bytes!("../tests/cms-fixtures/valid-test.der");
    #[test] fn crypto_positive_not_apple_trust() { let v=verify(VALID).unwrap(); assert!(v.content.starts_with(b"<?xml")); }
    #[test] fn content_tamper_rejected() {
        let mut d=VALID.to_vec(); let p=d.windows(9).position(|b| b==b"TEST ONLY").unwrap(); d[p]=b'B'; assert!(verify(&d).is_err());
    }
    #[test] fn signature_tamper_rejected() { let mut d=VALID.to_vec(); let last=d.len()-1; d[last]^=1; assert!(verify(&d).is_err()); }
    #[test] fn unsupported_rejected_by_crypto() { assert!(verify(include_bytes!("../tests/cms-fixtures/unsupported-test.der")).is_err()); }
    #[test] fn invalid_der_rejected() { assert!(verify(&VALID[..VALID.len()-1]).is_err()); }
}
#[cfg(test)]
mod attribute_tests {
    use super::*;
    fn modified(f: impl FnOnce(&mut SignedData)) -> Vec<u8> {
        let mut ci=ContentInfo::from_der(include_bytes!("../tests/cms-fixtures/valid-test.der")).unwrap();
        let mut sd=ci.content.decode_as::<SignedData>().unwrap(); f(&mut sd);
        ci.content=x509_cert::der::Any::from_der(&sd.to_der().unwrap()).unwrap(); ci.to_der().unwrap()
    }
    #[test] fn missing_attributes_rejected() {
        let d=modified(|sd| { let mut si=sd.signer_infos.0.iter().next().unwrap().clone(); si.signed_attrs=None; sd.signer_infos.0=vec![si].try_into().unwrap(); });
        assert!(verify(&d).is_err());
    }
    #[test] fn wrong_sid_rejected() {
        let d=modified(|sd| { let mut si=sd.signer_infos.0.iter().next().unwrap().clone();
            if let SignerIdentifier::IssuerAndSerialNumber(s)=&mut si.sid { s.serial_number=x509_cert::serial_number::SerialNumber::new(&[42]).unwrap(); }
            sd.signer_infos.0=vec![si].try_into().unwrap(); });
        assert!(verify(&d).is_err());
    }
}
