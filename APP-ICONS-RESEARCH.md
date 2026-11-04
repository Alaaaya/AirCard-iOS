# App icons investigation

Inspected 2026-11-04. Status: BLOCKED, no icon feature implemented.

Requested reference: https://github.com/ii7511587-alt/Airbored
Inspected revision: 360174cefb7e819f300ac349057cd6bea5986fc8.

Airbored contains a one-line README and 29 GitHub workflow files that generate
Swift projects. It contains no icon-writing engine or bundled replacement library.
All workflow files were inspected for implementation, target paths and restoration.

## Concrete evidence

- `.github/workflows/W.yml` lines 484-485 defines its own
  `airlift_start_pairing_server` returning 0 and `airlift_apply_theme` returning
  true unconditionally. No device operation occurs in either function.
- `Astrsrg5trdmain.yml` likewise supplies a success-only theme stub.
- `main.yml` explicitly logs "apply called (stub)" in its fallback. Its apparent
  AirliftFFI path only logs a message and PNG size, not an icon write.
- `She is main.yml` saves the selected PNG to the app's own Caches directory as
  `youtube_custom_icon.png`, then reports injection success. This is not the
  YouTube app or SpringBoard's icon store.
- `V20.yml` lines 453-456 declares invented external function names, then clones
  Mak5er's AirCard-iOS library rather than implementing those functions.
  Its pairing flow writes the literal string "pairing_data_generated_by_host".
- `Cdhygd6gcycgycfycftcfctcftcfcttcftcctcfmain.yml` also merely declares these
  external names and manufactures an "airlift_paired_session_token" text file.
- The actual AirCard C header and Rust source export `al_pairing_run_host`,
  `al_exploit_write_dir`, `al_exploit_inject_folder`, etc. They do not define
  `airlift_apply_theme` or `airlift_start_pairing_server`.

## Missing requirements

There is no real icon destination path, image/cache format, installed-app icon
lookup, cache invalidation procedure, original backup or original restoration.
A hardcoded YouTube bundle ID does not resolve those requirements. No demonstrated
iOS 27.0.1 icon-changing implementation is present. The iOS 17 deployment target
and an "iOS 27+" pairing label are not evidence of icon support.

AirCard's existing write-directory primitive alone is not enough to invent a
correct SpringBoard icon database/cache mutation. Its public FFI also lacks a
general remote original-file read/delete operation, so a reliable restore cannot
be promised on that basis.

## Licensing

No LICENSE, COPYING, or other license grant is present in the inspected Airbored
tree. Public visibility does not grant permission to copy its generated Swift
source. No Airbored source has been copied into AirCard. This document credits
Airbored/ii7511587-alt as the investigated reference, not a working dependency.

## Result

The app-icons branch is based on working video-wallpaper revision 686e768.
Only this research document is added. No runtime/UI/resource/FFI/build changes,
no speculative writes and no fake apply/restore buttons. Video wallpaper is
untouched. No new icons IPA was built, because it would falsely suggest an
implemented feature. A future implementation needs a real, licensed icon-writing
engine plus exact iOS 27 paths/formats and a verified reversible procedure.
