Private signing identity correction, based on production 8dce09ffd0324d02794482383db07c78312ea1da.

Observed source defect, not a device reproduction

In production rust-core/src/personal_sign.rs, resolved_bundle_id returned the suffix of any explicit profile even when the input app had a different identity. sign_with_options used select_profile(...).unwrap_or(0), so a nonmatching profile became an automatic identity rewrite. Two inputs could consequently be signed under the same output bundle ID, which causes normal iOS replacement behavior.

Additionally ios-app/Apps/CertificateInstall.swift copied SavedIdentity.bundleID directly into project options for exact profiles. personal_p12.rs supplies that value from Entitlements.application-identifier, INCLUDING the App ID prefix, rather than CFBundleIdentifier. Swift edited the main Info.plist before Rust could map original nested IDs. This was incorrect even when TeamIdentifier and application prefix happened to match.

Production wildcard handling in Rust already preserved original identities. Therefore the reported symptom alone does NOT establish whether the owner's profile is wildcard or exact. No identifiable owner profile was available in the checked server files. Classification remains UNKNOWN. Repository profiles and P12s are test fixtures, not owner credentials. No profile contents, device IDs or certificate secrets were printed.

Policy after correction

Original CFBundleIdentifier remains the default. An exact profile matching another app produces an actionable authorization error before any rewrite/removal/signing. There is no silent fallback. A wildcard profile preserves two different allowed app IDs. Explicit user-entered custom IDs are passed to Rust, validated against the profile, then applied with the SAME mapping to the main bundle, nested bundles, documented reference keys, application-identifier, and remapped keychain groups. Unrelated frameworks stay unchanged. Entitlement authorization, certificate/key matching, expiry, real device authorization and encrypted Mach-O rejection remain in force.

The application prefix is taken from the profile's application-identifier, independently from TeamIdentifier. We do not interpret either prefix as a concrete bundle ID, and do not claim an exact profile authorizes arbitrary IDs. Choosing the same custom ID twice intentionally still represents the same iOS app.

Source comparison, actually read at pinned commits

Feather current HEAD 31ab6de455f2a6108f6830e343dee826310c03be:
https://github.com/khcrysalis/Feather/blob/31ab6de455f2a6108f6830e343dee826310c03be/Feather/Utilities/Handlers/SigningHandler.swift#L218-L220
Only an explicit options.appIdentifier replaces CFBundleIdentifier in the inspected rewrite. The handler also has separate configurable identifier logic; this is not a claim that every Feather mode preserves the original.
https://github.com/khcrysalis/Feather/blob/31ab6de455f2a6108f6830e343dee826310c03be/Feather/Utilities/Handlers/ZsignHandler.swift#L42-L61
It passes the selected profile and P12 into Zsign without assigning the profile application-identifier to CFBundleIdentifier.

zsign current HEAD 9299685bab7ef99827e06e5dfda93af747386590:
https://github.com/zhlynn/zsign/blob/9299685bab7ef99827e06e5dfda93af747386590/src/bundle.cpp#L656-L669
ModifyBundleInfo changes the app identity only when the caller supplies a nonempty replacement bundle ID; updates plugin identities in that branch.
https://github.com/zhlynn/zsign/blob/9299685bab7ef99827e06e5dfda93af747386590/src/bundle.cpp#L55-L66
Signing inventory reads CFBundleIdentifier from the app, not a shared certificate identity.
https://github.com/zhlynn/zsign/blob/9299685bab7ef99827e06e5dfda93af747386590/src/openssl.cpp#L858-L865
Profile application-identifier and TeamIdentifier are separate fields. Mirsa retains its own stricter profile authorization rather than copying zsign's entire entitlement behavior.

Regression scope

Rust regressions invoke the very same main_identity, nested profile selection, id_map, rewrite and constrain functions used by sign_with_options. They verify two different apps under one wildcard pattern, legacy application prefix distinct from TeamIdentifier, exact-profile mismatch refusal, matching exact-profile success, explicit custom ID acceptance/refusal, and consistent nested/keychain/application-ID rewriting.

These are shared-path policy/filesystem tests, NOT proof of an actual P12 signed IPA installing on an iPhone. No owner pairing/credentials were requested or fabricated. Physical-device coexistence remains untested.
