Discovery pinned transport security review

The previous URLSession DNS preflight did not bind the actual socket address.
Candidate verification and the accepted-card download now both use the same
Rust reqwest 0.13.5 transport, already present transitively in this repository.

Each HTTPS hop resolves once, rejects empty/mixed/private/special-use answers,
creates a fresh no-proxy client with those exact DNS overrides, keeps the
original hostname in the URL for default rustls certificate/SNI validation,
disables automatic redirects and Referer, and checks the connected peer.
Every redirect repeats the complete process. No cookie jar, arbitrary headers,
Apple credentials, backend credentials, or authorization is accepted by this
FFI. Returned errors deliberately do not include URLs or server response text.
There is no deployed proxy or backend change. Requests go directly from device.

Responses require HTTP 200, identity encoding, a bounded streaming body and a
single operation deadline. Cancellation interrupts stalled network operations.
The downloader then requires a valid IPA archive before returning a temporary
file; the existing callers still check requested bundle/version identity.
Swift-only policy builds cannot download and fail closed without AirliftFFI.

Rust tests include an actual local TLS server with a test-only loopback pin,
a deliberately rebinding fallback resolver, successful original-hostname TLS,
rejection of a mismatching TLS hostname, and assertions that the fallback DNS
resolver never runs and HTTP Host remains the original hostname. Test fixture
private key is ONLY a disposable self-signed local regression certificate,
not a signing credential or trusted production root. Production rejects that
loopback address and test hostname before creating any connection.
Additional tests cover mixed/special-use DNS, public-resolved/private-peer
mismatch and unsafe redirect targets. Python wiring tests check that both
candidate verification and accepted-card download cannot bypass this transport.

Docs lookup: chub had no reqwest documentation; inspected installed 0.13.5 source
and official https://docs.rs/reqwest/0.13.5/reqwest/struct.ClientBuilder.html .
No custom cryptography or custom TLS verifier.

Limitations and required acceptance
Native iOS compilation and exact integrated SHA CI/screenshots remain required.
Pure-Swift Discovery tests deliberately exercise the unavailable-transport
failure path, not the real Rust bridge. macOS/Linux Rust tests do not substitute
for iOS bridge/link verification. Cancellation during synchronous archive
validation takes effect after validation; archive bounds remain enforced.
This transport change is not evidence that the unrelated signing crash is fixed.
Discovery metadata/source HTTP remains a separate existing transport; this
change closes IPA verification/download rebinding, not all outbound app HTTP.

Local evidence
Exact transport module compiled with rustc against the Cargo-built reqwest,
Tokio and rustls libraries and all five tests passed, including a real TLS
socket, hostname mismatch rejection, rebinding DNS fallback count zero, and
production download entry refusing private destinations before file creation.
C header parsed with cc. Python transport wiring 2/2 and presentation 4/4 pass.
Full application Rust build and Swift native CI remain separate acceptance gates.
The owner revoked ALL publication authorization, even if every CI turns green.
No production/feed/deployment changes are authorized without fresh approval.
