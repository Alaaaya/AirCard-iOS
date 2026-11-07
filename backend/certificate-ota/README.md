# Private certificate OTA foundation, NOT enabled

Live infrastructure was checked with the owner's management token, without printing it.
The Mirsa-only Supabase project hirebeofomiyumwysppj (mirsa-discovery) is ACTIVE_HEALTHY.
Its only deployed Edge Function is discovery-search. Storage configuration is available.
The Player project must not be used. Existing install behaviour and Apple ID default are untouched.

contract.mjs is only a tested validation/manifest foundation. It is NOT a working OTA service.
No toggle is exposed, no uploads happen, and no deployment has been performed.

Remaining implementation and authorization boundary
- Private bucket dedicated to signed IPAs, 30 MB maximum per object.
- Authenticated per-install JWT upload reservations, atomic user/global count and byte quotas.
- Server-generated 256-bit tokens; short-lived signed IPA URLs and manifest URLs, 15 minute lifetime.
- Manifest requests must fail closed after expiry and must never be cached.
- Scheduled server cleanup must physically delete expired IPAs and metadata, with retry and audit.
- Validate uploaded IPA archive, root Payload app, bundle/version and absence of bundled signing secrets.
- Reject archive bombs, encrypted archives, path traversal and malformed signatures; do not trust filename/MIME.
- Only locally signed IPA is sent. P12, private key, password and raw provisioning material never go to this API.
- Client uses existing local signing, checks actual Mirsa ID/profile coverage for self-update, confirms before
  launching itms-services. Explain keychain reset possibility and certificate revocation stopping Mirsa.
- Apple ID remains default. No changes to 1.3.118 strict-OFF compatibility for normal certificate signing.

A live host exists. There is no owner account/host blocker proven.
Adding a bucket, schema, cleanup schedule and new live Edge Function changes the existing live backend;
this private-only batch has not authorized production/backend deployment. Obtain that specific approval
before deployment, then test a real HTTPS manifest/IPA download and expired URL rejection.
