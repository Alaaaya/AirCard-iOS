Open in Mirsa

The production Info.plist already registers com.apple.itunes.ipa, its ipa extension and opening documents in place. Registration is retained, not duplicated or claimed as new.

Opening a file URL now snapshots a coordinated security-scoped read into a UUID-owned protected temporary directory off the main thread. Regular non-symlink files only, 1 byte to 512 MiB. The external document is never changed or deleted. Concurrent handoffs fail visibly instead of replacing a pending import. Provider coordination/copy errors use the existing Notice alert. Temporary snapshot is removed after existing import has made its own copy.

The existing import sheet now includes Personal library alongside Container and Real App. Library uses PersonalAppsLibrary.add, does not sign in or install, and opens the personal tab after durable save. Existing Container/Real login, limits, edit and signing paths are unchanged. Existing IPA validation/extraction remains in AppsStore. LTR and existing glass option cards are reused, English/Arabic.

No new Share Extension, App ID, entitlement or signing target. Document interaction Open In is sufficient when the sending app offers file handoff. Telegram may expose its own share UI or omit a document destination; a guaranteed custom share extension is NOT implemented or claimed. Fallback is Save to Files then Share/Open in Mirsa. Requires device testing of Telegram, Files, Safari Downloads and AirDrop, both cold and warm launch. Remote HTTP links are deliberately not treated as local files.

Manual acceptance on iPhone
Open a small IPA from Files while Mirsa is closed, then while running. Check all three choices, login enforcement and real-app slots. Library must save without installation/login. Cancel then import another file. Open a second file while chooser is visible, verify original remains. Invalid, empty, oversized and unavailable-provider files must fail without leaving a pending import. Original provider file must remain intact. Check Arabic physically LTR. Telegram/Safari/AirDrop visibility must be tested, not assumed.

Integration with kat/cert-bundle-rewrite
Only AppsView's existing InstallChoiceSheet call and one optional onPersonal closure/card are modified in the shared UI. PersonalAppsHub, project/certificate/home files are untouched. Resolve the small AppsView hunk explicitly when integrating; keep that branch's downloader and UI.
