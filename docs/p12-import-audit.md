# Certificate settings separation and P12 audit

Base production 1.3.75 e5b16f7. UI-only behavior correction.
Certificate settings, opened from the hub entry with initialIPA nil, exposes only
P12, password, mobileprovision, save, and existing certificate removal.
No IPA picker exists in this screen in either mode.
IPA import remains PersonalAppsHub. A library row Sign passes a library URL,
shows signing/export actions only, and uses the saved Keychain material.
Main apps, discovery, themes, bottom navigation and cryptographic signer are unchanged.

Observed screenshot reports Cannot open P12. This single message is emitted by a
combined guard for SecPKCS12Import failure, result casting failure, identity count
not exactly one, or missing kSecImportItemIdentity. Therefore it does NOT prove
the password is wrong. No user's P12/password was supplied or tested.

Possible causes include incorrect/empty password, malformed/truncated or mislabeled
file, unsupported PKCS12 encryption/MAC encoding, certificate-only archive without
matching private key, or multiple imported signing identities. Current code requires
exactly one imported identity. It ignores kSecImportItemCertChain: an ordinary
leaf plus intermediate chain must not be equated to multiple signing identities,
but actual result shape needs an iOS fixture test. Chain presence by itself is
not a demonstrated cause. RSA exportability is checked later with a different
error; expiry and provisioning mismatch are checked at signing, also later.
Changing mobileprovision cannot fix an error raised during PKCS12 identity import.

No cryptographic/parser behavior changed here. Follow-up should separate
SecPKCS12Import OSStatus from identity-array validation, preserve safe localized
diagnostics without logging key/password bytes, and test locally generated
single identity, ordinary intermediate chain, wrong/empty password,
certificate-only, malformed, multi-identity and unsupported-key fixtures on iOS.
Do not request private certificates in chat or promise an untested format fix.

Required device acceptance
Settings has no Choose IPA/sign-export. Import in hub, select app Sign,
saved identity required, successful signed output remains in personal library.
