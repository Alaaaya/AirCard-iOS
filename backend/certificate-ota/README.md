# Private certificate OTA

Deployed only to Mirsa project hirebeofomiyumwysppj. Never use the Player project.
Owner authorized additive infrastructure for this private batch, not app publication.

Dedicated private bucket mirsa-ota-private, 30 MiB upload maximum.
User JWT checked with Auth getUser on every upload. Server-generated 256-bit bearer download tokens.
RLS denies direct anonymous/authenticated table access. Only service_role invokes quota functions.
Atomic quotas: three uploads/user/hour, five active global, twenty/day, 200 MiB/day, 400 MiB/31 days.
Manifest and IPA use the same strict fifteen-minute expiry, enforced independently of cleanup.
Eight GETs total per reservation; no redirect to a longer-lived storage URL. No-store responses.
pg_cron every five minutes requests cleanup using a separate Vault-backed secret.
Service-role, cleanup secret, P12, password and private keys are never shipped in the app.
Only locally signed IPA with embedded PUBLIC profile is uploaded.
Archive central-directory bounds reject traversal, duplicates, excessive expansion and signing-key extensions.
This is structural validation, not cryptographic signature verification or iOS installation proof.

Live tests passed authenticated structural-fixture upload, manifest XML GET and byte-identical IPA GET,
unauthenticated 401, unknown token 410, expired manifest and IPA 410 BEFORE cleanup,
and cleanup 200 with fixture object no longer downloadable afterward.
Fixture was NOT an installable signed app. Real-device OTA install remains untested.

Apple ID is the default. Own-certificate mode routes Mirsa self-install/update only.
Local signer still uses the existing real-device pairing/VPN UDID check. OTA delivery uses HTTPS,
not VPN. This batch does NOT remove that local signing dependency or weaken actual-UDID verification.
Profile matching is strict for Mirsa self-install, normal certificate compatibility stays strict-OFF.
The first locally selected saved certificate is used, matching the existing vault selection semantics.
