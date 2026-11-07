# Private renewal lifetime repair

Base 2aa8de9. No publication or live-feed changes.

Exact dependency evidence, read from installed registry isideload 0.5.2
src/sideload/install.rs line 162 calls isideload_vfs::fs::metadata(&path)
inside afc_upload_dir while traversing the already-signed .app. It is not
a read of the source IPA. That line follows symlinks; ENOENT alone cannot
distinguish a disappearing entry from a broken link.

src/sideload/application.rs lines 44-60 derives extraction from the IPA
basename in the global temp directory and deletes an existing extraction.
src/sideload/sideloader.rs sign_app returns that extracted bundle.
Our pre-fix sideload.rs released the session lock before AFC upload, then
deleted any ancestor ending in _extracted. Concurrent same-basename signing
can therefore replace/delete an earlier upload's input. This is a proven
code-path collision mechanism, NOT proof that it caused the owner's Husk
incident. Reopening Mirsa succeeded, so persistent missing IPA is not assumed.

Repair
Each Apple-ID install opens the current canonical input, snapshots it into
a unique operation-owned directory, awaits all copy/write/rename work, and
extracts with the existing hardened archive parser. It passes an extracted
.app, not IPA, to upstream, avoiding its basename-derived global extraction.
Already-extracted and certificate-signed .app inputs also get owned copies.
The operation retains its workspace until the complete transport/install
future returns, on success or failure; Drop only deletes that exact root.
There is no suffix-based cleanup, cache wipe, automatic reinstall retry, or
deletion of Downloads/project/source files.

One async Rust install mutex serializes Apple-ID and certificate AFC installs,
including PublicStaging use. Swift manual/background/intent renewal calls
join an existing per-app Task and resolve the current apps record, not the
passed stale ManagedApp. Each next attempt recreates its workspace. Originals
are published by same-directory atomic rename only after the copy completes,
preserving previous original on preparation failure and open-reader lifetime.

Diagnostics
SideloadError, AppsStore.error and FFI install log callbacks apply the same
sanitizer. Preserve stage, OS cause and relevant install codes, remove local,
runner, Rust-source and Windows paths. Arabic generic ENOENT is a transient
file/folder unavailability, never a claim the source IPA is missing.
Only the typed MIRSA_SOURCE_IPA_MISSING generated when opening an IPA source
returns NotFound produces the explicit localized download-again message.
A missing pairing file, extraction entry or staging resource cannot generate
that marker. Existing connection failure translation is retained.

Verification actually run on Linux WEB
cargo check --lib --offline passed.
cargo test --lib --offline passed 122 tests, zero failed.
Nine workspace tests cover canonical replacement, source cleanup, concurrent
owners, fresh retry in same process, missing source, preparation-only ENOENT,
unfinished/delayed atomic publication, unique concurrent stages.
Two integration unit tests cover shared QuickInstall basenames via the actual
hardened ZIP parser and certificate .app caller cleanup after snapshot.
One Rust gate test proves exclusive shared manual/background transport gate.
Four Swift diagnostic tests added, NOT RUN on Linux.
Swift task joining/current-record code is source-reviewed only, NOT native-tested.
No physical-device reproducer or runtime success claimed.

Integration requirements
Cherry-pick this commit preserving the whole private batch and separate renewal
wording commit ef3902e. xcodegen must include new InstallErrorText.swift.
Run fresh EXACT canonical device CI; do not deliver old 2aa8de9 IPA.
Need native Swift tests and owner device renewal test without restarting.
