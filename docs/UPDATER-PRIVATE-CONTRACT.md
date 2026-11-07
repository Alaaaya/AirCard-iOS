Private updater correction, no publication

Live evidence independently downloaded 2026-11-07 from
https://github.com/Alaaaya/Mirsa-iOS/releases/download/build-88/Mirsa.ipa
Actual Payload/Mirsa.app/Info.plist says CFBundleVersion 1.3.2,
CFBundleShortVersionString 1.3.2, MirsaBuild 88, ID com.alaa.mirsa.
The published build is NOT 88 or 1.3.88 for numeric update comparisons.

Integrate this commit, dispatch Unsigned Mirsa IPA manually only. build-ipa.sh
stamps real parent and embedded extension builds after Xcode builds and before
ZIP packaging, using workflow run_number and run_attempt. E.g. run89 attempt1
is 2.89.1; attempt2 is 2.89.2; run100 attempt1 is 3.0.1. It fails closed on
Apple component bounds exhaustion. Number sequence is workflow-local: deliver
only the Unsigned Mirsa IPA workflow artifact as the canonical updater build,
not validation workflow artifacts whose run counters are independent.
No marketing/feed version bump is necessary for the private IPA.
verify_mirsa_ipa.py runs after packaging and asserts actual parent AND embedded
extension build equal the expected CI stamp. Integrator must retain that log
and independently unzip delivered Mirsa.ipa to confirm its actual plist.

Updater checks real downloaded IPA plist, not GitHub tag digits, MirsaBuild,
marketing versions, cached installed versions, or unverified remote metadata.
Equal/lower/unknown/malformed versions never offer an update. Install path
checks again, including the final downloaded bundle. This adds a full IPA
verification download per check and re-verifies at install, intentionally
prioritizing correctness over guessing from legacy tag metadata.

Release bodies are curated JSON objects containing releaseNotes.ar and/or
releaseNotes.en. Generator reads docs/release-notes.json by exact target key
(e.g. 1.3.89); absent entries emit empty notes, not git subjects. The client
uses the actual app language L.isArabic, never silently substitutes English
for missing Arabic. Existing raw release bodies/commit subjects show honest
localized notes-unavailable text. Existing download URLs, release tags,
legacy feed fields and player entries remain untouched. No generated feeds
were edited or published. A future approved release requires human-curated
notes for that exact version, not an inferred changelog.

Linux has no swiftc/Xcode here. Python packaging and source checks pass;
UpdaterMetadataTests.swift awaits native XCTest and Swift compilation in CI.
Full Python suite has one pre-existing pairing-alert source-expectation failure
against AppsStore.friendly (the cellular fix now uses a classified message).
Do not claim that unrelated test passed. No device-runtime validation yet.

Follow-up hardening supersedes the full-unzip check described above. Both check
and final install download now reuse DiscoveryDownloader's Rust DNS-pinned,
HTTPS-only public-address transport, no proxy/credentials, manually rechecked
redirects (five), 15-second connect timeout, 120-second total deadline,
128 MiB streamed compressed-byte limit and cancellation token. GitHub public
asset CDN redirects remain allowed. No URLSession fallback. Failed download
files are removed by DiscoveryDownloader; successful files have caller defers.
Metadata API requests bypass local cache and have a 30-second request timeout;
this does not promise upstream/CDN freshness.

Actual-build inspection reuses existing memory-mapped IPAValidator/ZipReader;
no archive extraction occurs for checks. Updater limits are 128 MiB archive,
512 MiB declared expanded sum, 10,000 entries, 32 path components, 1 MiB plist,
128 MiB executable and 200 compression ratio for read entries. Existing unsafe
path rules remain, plus opt-in symlink rejection from ZIP Unix attributes.
Cancellation is checked before/after bounded archive inspection. Final install
revalidates with those same limits then uses the existing maintained Rust zip
crate via IPAEditorService.extract, not the older generic unzip bridge. Its
actual byte budgets, safe-path/link checks remain defense in depth. Temporary
extraction directory is always removed. Swift/native execution still pending.
