# Personal signing Rust audit

Base: 6e8d82bd94cdd50cf1bbdb06674c6f62ef3aec6e.

The Zeus crash root cause is NOT established. No Zeus IPA, iOS crash report,
or jetsam report was available. Do not describe this patch as a verified fix
for the owner's on-device crash.

## Reproduced defect and narrow change

Calling personal_sign::actual_udid from within an entered Tokio runtime
panicked at Tokio scheduler/multi_thread/mod.rs:91, with "Cannot start a
runtime from within a runtime". The regression runs this actual function in a
child process with a temporary invalid pairing file. Before the guard it failed
with exit 101, NOT SIGABRT. After the guard it returns an Arabic Result::Err
and the child succeeds. Swift's current detached signing worker is not itself
a Tokio runtime, so this fixture does not explain the reported Zeus crash.

The blocking API now checks Handle::try_current before constructing a runtime.
No authorization, profile matching, key/certificate checks, CMS warning policy,
or signing behavior on the supported Swift call path changes.

## FFI and archive evidence

al_ipa_editor_run and al_personal_p12_import already have catch_unwind inside
extern C. The workspace release profile and checked build scripts/workflows
contain no explicit panic=abort override. Default Rust unwind can be caught;
allocation failure, stack overflow, invalid foreign pointers, jetsam and signals
are not made recoverable by catch_unwind. We did not reproduce any of those.

Added a direct FFI regression for null, malformed JSON, null JSON, missing fields,
and a nonexistent personal-sign input. All return owned error JSON and can be
freed correctly. Existing encrypted Mach-O/FAT validation, malformed input,
traversal, symlink, duplicate path, profile, UDID, identity-binding and P12 tests
remain passing. No decryption support was added.

ZIP extraction and packing already stream file contents; extraction enforces
512 MiB per entry, 4 GiB total and 100,000 entries. This does not imply signing
is low-memory. The signer still reads full Mach-O data; FAT signing processes
slices in parallel and retains signed slices. personal signing also reads full
executables for entitlement inspection and full Mach-O files for validation.
Those are possible memory-pressure risks, not proof of jetsam for this IPA.
No arbitrary new memory cap or broad signer rewrite was introduced without a
real failing artifact or on-device evidence.

## Validation

CARGO_TARGET_DIR=/tmp/mirsa-cert-rewrite/rust-core/target CARGO_BUILD_JOBS=2 \
 cargo test --manifest-path rust-core/Cargo.toml --lib

Result: 51 passed, 0 failed. Linux host only; not an iOS device/ABI/runtime test.
The pre-change nested regression failed and post-change passes. Build logs are
/tmp/mirsa-nested-before.log and /tmp/mirsa-sign-crash-after.log on the web host.
No production push, workflow dispatch, feed write or publication occurred.

Next decisive evidence: obtain the actual installed build identifier plus the
Mirsa .ips termination report or jetsam entry. An isolated reproduction needs
the same IPA and signing material, supplied securely, not credentials in logs.
