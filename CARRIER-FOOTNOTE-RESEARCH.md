# Carrier and footnote integration audit

Audited 2026-11-04 against carrier research commit 0797b132f8c23d8bf4f32c376c998f2457a71d9c and Placard commit 7dcefb610cc60ae909b6046beee7adb691148e44.
Base remains the working video-wallpaper commit 686e768. No runtime changes or unverified controls were added.

## Carrier text: real research, blocked on safe on-device replacement

https://github.com/Prognosticate-X/ios27-carrier-lockscreen-research

The generator is real code. It builds an NSKeyedArchiver record for
/var/mobile/Library/SpringBoard/StatusBarOverrides.archive with
_SBSystemStatusStatusBarOverridesArchiveRecord, STStatusBarData and cellular
entries. The reset is a valid empty record, not a guessed carrier string.

However, writing an empty record back is itself an overwrite. The research's
tools/airlift_archive_replace.py explicitly says plain deployment fails when the
destination exists. It first moves the old archive to Media recovery, then moves
the new archive into the vacated destination, in the same AirTraffic session.
It also reads and saves the old bytes. The latest physical-device recheck,
docs/EN/04_research_handoffs/2026-11-04_online-carrier-override-recheck.md,
used that replacement path plus a systemstatusd/SpringBoard live-domain purge.
The older two-phase overwrite coordinator tries to deploy reset before reboot;
it does not establish that our current writer can overwrite an existing archive.

Our bundled AirliftFFI exports write_dir and inject_folder but no arbitrary
same-session move/recover/read/restore operation. rust-core/src/exploit.rs
write_files_batch builds link-first, then payload moves only; it does not vacate
the existing destination, back it up or verify target bytes. Its success log
after FileComplete is not proof that an existing destination was overwritten.

A first carrier application might work on a missing destination, but a reliable
update/reset is NOT established. Shipping Apply plus a nonfunctional Reset would
violate this task's requirements. This is a missing implementation/verification
boundary, not evidence that carrier modification is fundamentally impossible.

Additional limitation: the actual verified status=5 configuration pins cellular
bars and network type. It is not a harmless text-only overlay; stale bars/5G and
text remaining in Airplane Mode must be disclosed before any future application.
VPN passthrough requires an empty suppression set and omitting vpnEntry.

Next implementation must extend/rebuild the Rust FFI with transactional recovery,
persistent backup, rollback on partial failure, target readback, and honest reset
handling, then test on physical iOS 27.0.1. Do not modify a daily driver merely to
discover whether restoration works.

## Lock screen footnote: not reachable through the requested writer

Target documented by the research:
/var/containers/Shared/SystemGroup/systemgroup.com.apple.configurationprofiles/Library/ConfigurationProfiles/SharedDeviceConfiguration.plist

That is outside the stipulated /var/mobile writer boundary. The research offers
a configuration profile (com.apple.shareddeviceconfiguration) or a desktop
SysSharedContainerDomain backup restore, not an AirCard-compatible mobile path.
Profile acceptance/supervision requirements are not established for this
personal device. A generated mobileconfig is not proof the device accepts it.
Reset would be removing the accepted profile through Settings; not an Airlift
default-value write. No backup restore was attempted.

## Placard: real source, main missing feature incompatible on this device

https://github.com/frs0n/placard

Placard's installed-wallpaper listing/deletion uses bad_query. Its own
placard/SystemCompatibility.swift supports iOS 26 through 26.6.1 and specifically
27.0 developer beta 1-4 builds, NOT 27.0.1. Do not expose a working-looking library
manager or remove button on the user's version.

Video generation and tendies import are real, but AirCard already has these.
Placard additionally supports selectable auto-reverse and a 12-second cap.
Those are optional future video enhancements, not solutions for carrier reset
or footnote access. No speculative behavior was added to the working video path.

## Licensing and delivery

Carrier README claims MIT but checkout contains no LICENSE or copyright notice;
no carrier source was copied. Resolve notices before any future port.
Placard is GPL-3.0, with its own upstream licensing caveats; no Placard source
was copied and no license terms were silently changed.

Only this audit is committed. No new IPA/build was produced because neither
requested system feature meets the reversible-operation requirement. The working
video feature and all app source remain byte-identical to video-wallpaper.
