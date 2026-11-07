Private cellular/device transport fix

Causal findings
Apps refresh preflight required VPN AND Wi-Fi AND pairing. Wi-Fi was a UI requirement, not an authenticated transport requirement.
Shared connect_tunnel tried interface IPs as device endpoints and included unrelated guessed fallbacks. Screenshot endpoint 172.16.0.1 is a SideStore candidate, not proof LocalDevVPN's 10.7.0.1 failed pairing.
Production now prefers configured validated IPv4 then 10.7.0.1 and 172.16.0.1. 10.7.1.1 is excluded as a device target. Interface addresses remain listener hints only. No URL input added.
Cache is populated only by existing successful authenticated RemoteXPC/raw pairing handshake or Lockdown start_session. Changed target clears cache; failed cached route clears and reprobes.
Shared outer future has a 20-second total budget and six-second per-RSD-attempt timeout. Dropping timeout future drops pending connection futures, not detached dial tasks. Pairing, TLS and device-identity checks unchanged.
All existing connect_tunnel callers inherit this, including Apps install/refresh, signed certificate install, self-install, devtools and personal-sign UDID lookup. Pairing-record creation itself has no Wi-Fi gate and does not use this existing-session helper.
Typed connection markers carry fixed stage/kind/domain, only evidenced bounded numeric codes, and known endpoint labels. Unknown evidence remains unknown. SideloadError localizes markers in Arabic/English; approved generic fallback strings are untouched.

Tests actually executed on Linux WEB
CARGO_TARGET_DIR=/tmp/mirsa-cellular-target cargo test --offline
98 passed, 0 failed. Full log /tmp/mirsa-cellular-full-tests.log.
Includes production candidate selection, preference/cache invalidation, listener-vs-device separation, total-budget cancellation with future-drop evidence, completion within budget, invalid-pairing pre-network rejection, timeout/permission/route/heartbeat distinctions, endpoint allowlist and secret stripping.
Swift production-policy and real-interface fixture tests added in tests/DeviceConnectionPolicyTests.swift and tests/DeviceRouteTests.swift but NOT executed here. Neither Linux host has Swift/Xcode. Parent must run native compile/tests before delivery.
No device test. No guaranteed cellular support. No publication.

Fresh upstream evidence
https://github.com/StikDebug/StikDebug/tree/395c4d5a0b5960536c22564f948049122383f3fb
https://github.com/StikDebug/StikDebug/blob/395c4d5a0b5960536c22564f948049122383f3fb/StikDebug/Services/ConnectionDiagnostics.swift
ConnectionDiagnostics diagnoses cellular only after actual connection failure and reachability/path evidence; upstream still acknowledges cellular limitations.
https://github.com/StikDebug/StikDebug/blob/395c4d5a0b5960536c22564f948049122383f3fb/StikDebug/Device/JITEnableContext.swift
Discovery uses NWParameters.tcp with includePeerToPeer, without a required Wi-Fi interface binding.
Upstream Airplane Mode suggestion is evidence of a limitation, NOT our recommendation or a proven fix.
