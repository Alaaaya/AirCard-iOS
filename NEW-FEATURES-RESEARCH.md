AirCard additional features feasibility, 2026-11-04
=================================================

Result: implementation blocked. No new functional feature or IPA is claimed.
The existing Video from Photos lock-screen feature is unchanged.

Contact call poster video
-------------------------
No verified iOS 27 contact-to-poster descriptor mapping, database schema, or
video-capable incoming-call provider format was found. CNContactPicker selects
a contact but does not grant arbitrary access to that contact's poster store.
Setting CNMutableContact.imageData only changes the contact photo. It is NOT a
reliable replacement for a Contact Poster and must not be advertised as one.
A video frame exported for manual selection in Contacts would be a separate,
reduced-scope feature. No guessed database writes or fake Apply buttons added.

StandBy video
-------------
Apple documents photo albums, widgets and clocks in StandBy, not arbitrary MOV
posters. The known CollectionsPoster CAML descriptor is a lock-screen provider;
sharing PosterBoard technology does not prove that StandBy accepts it. No
verified user-writable StandBy video-provider format/path was found. This is
unknown, not proof that it is fundamentally impossible.

Carrier text and logo
---------------------
Cowabunga source at 7bcf7a7b81a7ddd6724f8615851ccf7dd878801a,
Cowabunga/Controllers/MiscModsManager.swift, setCarrierName:
  /var/mobile/Library/Carrier Bundles/Overlay/
It enumerates EXISTING plists, reads each and edits StatusBarImages entries.
This is not a generic carrier-logo image injection facility. The legacy loop
also appears to overwrite its own modified dictionary; do not copy blindly.

Nugget source at 26e0c50ec114ca3a4ff6ab2fb4ae309abfd39fa1,
src/tweaks/status_bar/status_bar_tweak.py and status_setter.py:
  HomeDomain /Library/SpringBoard/statusBarOverrides
  equivalent to /var/mobile/Library/SpringBoard/statusBarOverrides
It writes a private packed binary StatusBarOverrideData structure, not a plist
or carrier-bundle logo. Its private bitfield layout needs validation on target
OS. UTF-8 byte bounds also matter. No evidence found of arbitrary bitmap-logo
support on the target device.

The carrier paths ARE under /var/mobile and text is a plausible future target.
The blocker is safe discovery/backup/restore and target-format validation, not
the path boundary. AirliftFFI's inspected public header exposes write_dir,
inject_folder, find_app_container and syslog, but no arbitrary protected-file
read/list/delete interface. Rust AFC reads in exploit.rs are scoped media
staging/book-sync operations, not demonstrated general protected-file reads.
Local FileManager access remains sandboxed. Consequently we cannot enumerate
existing overlay names, preserve original bytes or remove a newly-created
statusBarOverrides through the present exposed API. Writing zero bytes or an
all-zero private struct is not equivalent to restoring an absent file.
No overwrite of cellular configuration is justified without reversible backup.

Next evidence needed
--------------------
Device filesystem export of contact/ambient stores and mappings with private
contact data removed; confirmed provider format; verified read and deletion
capabilities for reversible carrier changes; target-version status-bar layout.
Do not request the user's whole address-book database or pairing secrets in chat.

Sources inspected
-----------------
https://github.com/leminlimez/Cowabunga
https://github.com/leminlimez/Nugget
https://support.apple.com/guide/iphone/use-standby-iph878d77632/ios
https://gist.github.com/MWRevamped/9161837f2bda90d13c7d24e285226691

No app source changed, no compilation needed for this documentation-only
branch. No Actions build triggered and no AirCard-features.ipa produced because
it would contain none of the requested functional additions.
