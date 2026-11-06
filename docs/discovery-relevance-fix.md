# Discovery relevance and actual-IPA-only results

Base 6e8d82bd94cdd50cf1bbdb06674c6f62ef3aec6e. Isolated branch kat/discovery-relevance. No backend deployment, production push, feed change, or release.

## Root causes
App Store URL parsing accepted an unanchored id substring, including query strings. Engine's ID-query path appended backend hits without relevance ranking. Backend only rejected Android and unsafe URL shapes, not unrelated titles or social/wiki/decrypt hosts. A .ipa suffix alone made a hit downloadable. Apple reference cards were appended and page-only hits displayed.

## Owner override implemented
Apple listings are internal identity only. An ID lookup accepts only Apple's exact requested trackId and a nonempty bundle/title. ID URL input accepts HTTPS exact Apple hosts, canonical app path and complete ASCII numeric terminal id; credentials, unsafe port, lookalikes, query-only ids, and trailing junk fail.
Only relevant actual-archive-validated download candidates reach outcome and UI. Metadata and page-only cards never display. Empty string is exactly ما لقيت IPA لهالتطبيق.
Existing source card icon, name/version/bundle, source, تنزيل/لا buttons, confirmation/trust flow, and download-to-library path retained. Dead reference badge/open-page action removed.
Title matching requires complete normalized query tokens, never substrings or joined words. Authoritative bundle mismatch rejects a candidate both before and during byte validation. Sources' bundle metadata does not count as archive verification.
Backend and Swift independently block social/wiki/known decrypt/crack destinations, including subdomains and redirect hops. Backend rejects explicit decrypt/crack textual hits as well. Legitimate generic hosts are not blocked just because a word occurs inside their hostname.
Candidates are fetched sequentially, max six, each max 256 MiB and 30 seconds. Existing bounded ZIP/plist/Mach-O validator checks real bytes, expected authoritative bundle, declared version and encryption. Fake .ipa HTML/other ZIPs fail. Metadata is never fabricated to promote invalid results. Verified display bundle/version come from the real archive. A stored ZIP member length mismatch previously able to trap is now rejected.

## Security boundaries
Backend HTML resolver retains its DNS-vetted, socket-pinned public-address transport, bounded body, deadline and manual redirects.
iOS download URL policy applies before initial request and on every redirect, including blocked hosts, IP/private/local names and unsafe schemes/ports. Added fail-closed public-DNS answer preflight before each download/hop; mixed/private answer sets rejected.
IMPORTANT: URLSession does not expose DNS socket pinning. Client DNS guard is a preflight, so DNS rebinding between preflight and connection is NOT fully prevented. Do not claim equivalence to backend socket pinning. A fully rebinding-proof client transport or backend binary proxy would be a separate change and requires review.
Prevalidation fetch is temporary and deleted, not installed or added automatically. UI explanatory sentence corrected accordingly; accept still re-downloads and re-validates, protecting against changed content.

## Validation actually run
Deno 2.9.6: 15 backend tests passed; deno check backend/discovery-search/index.ts passed.
Swift 6.2.4 Linux test harness: 35 XCTest tests passed. Harness copied exact core/archive/provider/orchestrator/downloader logic, added FoundationNetworking imports, omitted Apple-only SafeMetadataHTTP and stubbed two auth interfaces. Thus this is compiled behavioral coverage, NOT a full iOS build or test of Apple's URLSession streaming metadata client.
Swift frontend -parse all Discovery sources and DiscoveryTests succeeded.
Python UI source-contract suite: 4 passed (no reference cards/sections, exact empty Arabic, existing icon/version/bundle and download/no flow retained). These are static UI checks, NOT rendered simulator UI tests.
Fixtures cover canonical and international Apple URLs, URL lookalikes/credentials/unsafe ports/path suffixes, metadata-only/page-only/x.com absence, fake .ipa HTML/other ZIP rejection, real IPA source result, actual bundle identity, normalized token boundaries, original junk examples, private-address classifications and redirect destinations.

## Remaining integration gate
No macOS/Xcode or simulator available in this worktree. Parent must compile and test the exact integrated SHA on macOS/iOS and inspect all actual requested screenshots. Native live-network verification and rendered UI test remain unverified. No claims about production behavior until coordinated backend deployment and exact-SHA CI/screenshot gate.
Apple lookup reference (chub has no Apple/iTunes entry):
https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/iTuneSearchAPI/LookupExamples.html
