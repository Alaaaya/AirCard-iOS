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
