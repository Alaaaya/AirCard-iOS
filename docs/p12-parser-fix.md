Personal P12 import correction

Based exactly on production 453d987. Only the personal identity importer changes.
The existing isideload-p12-keystore dependency is reused directly, with legacy
encryption enabled, avoiding iOS SecPKCS12Import AES/PBES2 compatibility and
the old entries.count == 1 rejection. No external OpenSSL executable is used
by the app. OpenSSL is used only to generate synthetic test fixtures.

Raw import avoids issuer-subject chain walks on untrusted certificates.
RSA private/public keys are compared cryptographically, then the certificate
DER must appear in DeveloperCertificates in the supplied signed provisioning
profile. Extra chain certificates do not count as additional identities.
Zero or multiple matching identities fail closed. Password edges are trimmed.
An integrity/MAC failure cannot distinguish a wrong password from damaged
data, so the localized error explicitly mentions both possibilities.
Unsupported cipher errors, missing identity, ambiguous identity and profile
mismatch have separate English/Arabic messages. Existing signing validity,
bundle scope and local-export restrictions remain unchanged.

All material remains in memory and the existing device-only Keychain vault.
No private material logs, uploads or plaintext identity files were introduced.
Fixture private keys are synthetic disposable test identities, not Apple
certificates. generate.sh regenerates them using local OpenSSL 3.

Tests include RC2-40/3DES legacy, PBES2/AES256, extra CA chain, trimmed password,
incorrect password, certificate-only P12, mismatched profile and multiple
certificate identities, with explicit unique-profile selection.
These are local Linux Rust tests. iOS compilation is separate. Real owner
P12 and device import/sign/export have not been tested; no claim it fixes
that particular file until the owner tests the built version.
