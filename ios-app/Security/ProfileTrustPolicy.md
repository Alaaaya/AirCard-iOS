# Strict provisioning signer trust boundary

Rust verifies CMS content digest, content type, signed attributes, SID-selected certificate and RSA signature before calling this function. The bridge never accepts a JSON verification flag and does not itself implement CMS.

The C ABI receives the exact verified signer DER and a packet of repeated big-endian u32 length + certificate DER. Bounds are 16 packet certificates, 65536 bytes each, 262144 packet bytes; signer is independently bounded to 65536. Malformed input fails closed. Packet certificates are untrusted intermediates, never anchors.

Public iOS Security APIs evaluate Basic X509 at the actual current time, explicit anchors only, no network fetch, with no trust exceptions. The evaluated signer must equal the passed DER. Additional authorization requires exactly three evaluated certificates, production leaf CN `Apple iPhone OS Provisioning Profile Signing`, intermediate CN `Apple iPhone Certification Authority`, and an exact bundled production Apple root. No generic Apple developer certificate, Mac provisioning role, TEST signer, or private API fallback.

Role baseline corroboration is Apple's currently published open-source Security main commit db15acbe6a7f257a859ad9a3bb86097bfe0679d9, OSX/sec/Security/SecPolicy.c, function SecPolicyCreateiPhoneProvisioningProfileSigning lines 2502-2541. This is a strict compatibility baseline, not a guarantee of current production-profile support. Its trailing OID comment is NOT used as an authorization substitute. Unlike the internal policy's historical no-validity behavior, this bridge intentionally requires present certificate validity.

Source https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/sec/Security/SecPolicy.c
Public APIs https://developer.apple.com/documentation/security/configuring-a-trust and https://developer.apple.com/documentation/security/sectrustevaluatewitherror(_:_:)

Official anchor discovery https://www.apple.com/certificateauthority/
Downloaded DER sources and SHA256
Apple Root CA https://www.apple.com/appleca/AppleIncRootCertificate.cer B0B1730ECBC7FF4505142C49F1295E6EDA6BCAED7E2C68C5BE91B5A11001F024
G2 https://www.apple.com/certificateauthority/AppleRootCA-G2.cer C2B9B042DD57830E7D117DAC55AC8AE19407D38E41D88F3215BC3A890444A050
G3 https://www.apple.com/certificateauthority/AppleRootCA-G3.cer 63343ABFB89A6A03EBB57E9B3F5FA7BE7C4F5C756F3017B3A8C488C3653E9179

No production mobileprovision file was found in the web host's /files, /home/kit or /tmp search. Therefore actual user-profile role compatibility and real-device installation are unverified. This offline boundary does not claim live revocation status or replacement for iOS installation enforcement.
