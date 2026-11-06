# Mirsa Windows handoff protocol v1
iOS worker owns this contract. Backend read before implementation.

USB AFC Documents paths (relative to Documents):
- mirsa-handoff-request.json app writes public request
- mirsa-handoff-envelope.json Windows writes encrypted response atomically (temp then rename)
- mirsa-handoff-receipt.json app writes result
- aircard_pairing.plist canonical existing technical pairing filename, unchanged. Windows uploads pairing before handoff; app syncs existing canonical mirror.

App must be opened once AFTER install before finish. iOS generates a fresh ephemeral Curve25519.KeyAgreement private key in RAM only; request valid 600 seconds. No static shared key, private-key file, credential plist or URL scheme. App processes only while foreground and protected data available. It checks transfer at activation and every 2s while active. Restart invalidates outstanding session, removes stale envelope and creates fresh request. Existing saved Apple ID must NOT silently be overwritten; automatic handoff is first-setup only.

Request JSON keys
{"version":1,"sessionId":"lowercase UUID","publicKey":"BASE64 raw X25519 32 bytes","createdAt":1793970000,"expiresAt":1793970600}
Unix seconds integer. All base64 standard RFC4648 padded. No secret in request.

Envelope JSON
{"version":1,"sessionId":"same","publicKey":"BASE64 sender ephemeral X25519 32 bytes","sealed":"BASE64 nonce[12] || ciphertext || tag[16]"}
X25519 shared secret from app request public key + Windows ephemeral private key.
HKDF-SHA256 length32 salt=UTF8(sessionId), info=UTF8("Mirsa Windows Handoff v1").
AES-256-GCM 12-byte random nonce.
AAD=UTF8("mirsa-handoff-v1|"+sessionId+"|"+decimal(request.expiresAt)).
Plaintext UTF8 JSON {"version":1,"sessionId":"same","expiresAt":same integer,"email":"...","password":"..."}
Envelope max 32768 bytes; plaintext max 16384; email nonempty <=320 UTF8 bytes password nonempty <=4096 UTF8 bytes. Exact session/expiry version validated AFTER decryption; app verifies request time window and pairing exists. Windows must not persist password/plaintext/shared/private keys/logs or claim Apple auth was completed by receipt.

Receipt JSON {"version":1,"sessionId":"same","status":"consumed"|"rejected"}
Consumed only after both credential Keychain writes succeed and verify, canonical pairing is present, encrypted envelope/request deleted, RAM session invalidated. Failure writes only rejected, never detailed errors or secrets. Receipt means local secure storage, NOT successful Apple login, certificate validity, VPN or device capability. Windows should bind receipt sessionId to sent session and may show consumed only for matching session. Receipt is plain local status, not cryptographic attestation.
App will lazily use existing AppsStore.ensureSession() workflow, prompting normal 2FA as needed; no new certificate revocation or login-on-transfer side effect.

Threat model: protects Apple credentials from documents/backups and passive transfer inspection, not malicious trusted host / replacement of request / compromised phone. USB Trust already grants host sensitive pairing access. E2E peer identity beyond USB trust is not claimed. Pairing file is itself sensitive and remains using existing pairing APIs. No TLS/static app secrets invented.
