# Personal project signing (review branch only)

Based on production 7c50e6e, branch kat/cert-bundle-rewrite. No publishing or source-feed changes authorized.

## Identifier resolution

The main application's CFBundleIdentifier is changed to an explicit profile's allowed bundle ID, stripping only the application-identifier prefix. That prefix may differ from TeamIdentifier on older Apple accounts. Wildcard profiles retain the original identifier and must actually permit it. Malformed wildcard scopes fail closed. The final application-identifier entitlement uses the profile prefix and resolved bundle ID. Keychain groups come only from the profile; the profile-prefix wildcard is narrowed to the final app ID. Other unsupported wildcard groups fail closed. No imported application entitlement is granted.

All profile/certificate expiry, certificate membership, encrypted executable and nested-app checks remain in place. Extensions/App Clips are not silently signed with the parent profile. Unsupported extension-bearing apps fail with an Arabic explanation; the explicit project Watch-removal option can remove the temporary Watch directory. Source IPAs remain untouched.

## Personal certificate storage

Multiple identities and selection are stored together in the existing device-only, when-unlocked Keychain item, never library JSON. Existing single-identity records are read as a legacy entry and migrated on a subsequent write. Saving identical P12/profile selects the existing entry rather than duplicating it. Deletion affects only the selected identity; other identities remain. Metadata is parsed from actual P12 certificate and provisioning profile. Expiry displays the earlier certificate/profile expiration, not a remote revocation guarantee.

## Project transformation

Changes apply only to a freshly bounded-extracted temporary archive. Optional changes cover name/ID/public version, file sharing, URL scheme removal, removing the old embedded profile, Watch removal, minimum OS metadata and injection through the existing validated Rust editor. Signing necessarily embeds the selected current provisioning profile, even when an old profile was removed. Output is an IPA share/export artifact, not a claim of installation. Lowering MinimumOSVersion alone does not make newer APIs compatible.

Arbitrary entitlement import is deliberately not implemented. A safe entitlement editor must validate each requested entitlement against the selected profile rather than offering an unbounded entitlement grant.

## Validation

Rust tests cover explicit differing/same IDs, wildcard retain/scope rejection, malformed profile patterns, and invalid profile rejection. Full native CI and actual device signing status must be recorded in the final review report. UI screenshots must be actual simulator output or explicitly marked unavailable; no generated mockups count as runtime verification.
