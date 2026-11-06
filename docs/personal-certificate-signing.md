# Personal certificate signing

The Apps home adds a separate section titled exactly «توقيع التطبيقات بشهادة». It does not replace Apple ID sign-in, free-account signing, or Container installation. Both normal and optional Home Screen layouts can open it. Arabic text does not mirror the layout.

Import a personal RSA P12 and password, import its mobileprovision, save, choose an IPA, then sign and export. Export uses the system share sheet to Files or a compatible installer. There is deliberately no fake direct-install button or public upload server. Export alone does not install anything.

P12, password and profile are a single atomic Keychain record, under a distinct service, with WhenUnlockedThisDeviceOnly accessibility and synchronization disabled. The existing Apple ID handover/export cannot see this service. Signing exports the RSA private key into process memory only for the reused local Rust signer. No key file, logging, Apple ID request, certificate registration, revocation or remote upload occurs. Source files selected in Files remain the user's responsibility.

The existing bounded ZIP extractor and packer are reused. New validation checks profile expiry, certificate validity, exact certificate membership in the profile, bundle-ID scope, profile distribution type, and encrypted Mach-O inputs. Signed output includes the public embedded profile, not private material. Signing supports only RSA identities and applications without extensions, Watch, App Clips or nested apps. Separate per-extension profiles are intentionally not approximated.

Apple validates provisioning-profile CMS signature, device eligibility, online certificate revocation, entitlements and trust during installation. The local profile parser is not a replacement for iOS trust verification. No claim of guaranteed installability is made. No personal certificate or device was available for end-to-end validation.

Manual acceptance on device still needed
1. Import valid P12/password and matching development or Ad Hoc profile.
2. Unlock/relaunch and verify saved identity remains available, without Apple ID login.
3. Sign a matching unencrypted IPA, export, install with a supported installer.
4. Wrong password, mismatching/expired cert/profile, wrong bundle ID, App Store profile, encrypted binary and extension app must fail without export.
5. Remove saved identity, relaunch and confirm absence. Existing Apple ID and container apps remain.
6. Check Arabic title exactly, horizontal tabs, optional home shortcut and share-sheet lifecycle.

No merge, production release, source-feed changes or owner IPA delivery are authorized by this branch.
