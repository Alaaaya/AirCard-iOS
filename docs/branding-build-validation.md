# Mirsa build identity
The application, scheme, test host, Swift module and packaged executable are Mirsa.
The bundle identifier remains com.alaa.mirsa; the extension remains com.alaa.mirsa.liveactivity.
CFBundleDisplayName remains Mirsa. CFBundleName intentionally follows PRODUCT_NAME, now Mirsa.
Existing document type identifiers, URL schemes, preference keys, on-disk library directories,
Bonjour service types and Keychain services are unchanged to preserve existing installations.
No entitlement or provisioning configuration is changed.
AirliftFFI, libairlift_ffi and al_* are the existing exploit/FFI library interface, not the former
application brand. They are retained to avoid changing the native ABI or third-party linkage.
Legal notices and upstream URLs/credits are preserved.

Validation must inspect the built IPA, not just this configuration. It must contain
Payload/Mirsa.app/Mirsa, whose CFBundleExecutable is exactly Mirsa and whose bundle identifier
matches a production IPA. Device and simulator builds must pass on the final integrated SHA.
This branch cannot publish releases or update feeds; only validation workflows may be dispatched.
