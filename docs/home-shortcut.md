# Home Screen shortcut without a profile

Uses Apple's ShortcutsLink to open Mirsa's own App Shortcuts page, not an empty editor. Open Saved App is a new entity-backed intent; the existing App ID intent stays compatible. The selected app becomes the query's default and first suggestion. Each saved shortcut serializes the app's stable ID, so adding another icon cannot retarget an earlier one. Missing/deleted apps return a not-found message instead of opening the current suggestion.

Expected iOS flow (device validation required): tap Mirsa's Shortcuts button; long-press Open Saved App; choose New Shortcut; verify/select the app name if iOS doesn't apply the default; open the shortcut title menu; Add to Home Screen; Add. On versions where the App Shortcut offers Add to Home Screen directly, use that only after confirming the app parameter. Names/menu placement differ by iOS language and release. Custom icon is optional via Share icon and the system photo/file chooser.

This is NOT a literal one-tap install or an imported signed shortcut. There is no documented API to create a fully populated user shortcut through create-shortcut query arguments. A dynamically generated unsigned plist is rejected on modern iOS. Remote import needs a signed .shortcut or an iCloud shared link. No signing identity/iCloud shortcut host is configured here; no bogus import URL, external signing service, or configuration profile was added.

Sources checked 2026-11-06:
https://developer.apple.com/documentation/appintents/shortcutslink
https://developer.apple.com/documentation/appintents/acceleratingappinteractionswithappintents
https://support.apple.com/guide/shortcuts/open-create-and-run-a-shortcut-apda283236d7/ios
https://support.apple.com/guide/shortcuts/share-shortcuts-apdf01f8c054/ios
