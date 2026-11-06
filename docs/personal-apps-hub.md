# Personal apps hub
Based on production f8aaf9d. Supersedes direct certificate bottom-tab proposal.
Bottom order is Apps, Sources, Tools, + in both native and Liquid navigation.
Plus opens an independent apps home; its signing entry is exactly توقيع التطبيقات بشهادة.
Classic and Liquid use existing themed glass cards.

Library is Application Support/MirsaPersonalApps, not DownloadsLibrary or AppsStore.
Imports are copied and inspected using existing bounded IPA extraction and Info.plist tools.
Only imported IPA and public metadata are persisted, with complete file protection and backup exclusion.
UUID filenames prevent filename/path injection. Index writes are atomic; failed index writes clean the new IPA.
Unreadable index blocks new writes rather than silently replacing the library.
No private identity material enters metadata. Existing Keychain vault and cryptographic signer are unchanged.
Import classification means imported only, NOT verified signature or installed.
Signed classification means this local signer produced the IPA, NOT device-trusted/installed.
Signing saves a persistent copy before the existing temporary share artifact is cleaned up.
Failed library save retains signed export and explicitly reports failure.
Existing app home, downloads, Apple-ID flows and container are not used for personal imports.

Device acceptance still required
Import IPA, relaunch and verify persistence. Select personal row Sign and verify it preselects IPA.
Import matching certificate/profile, sign, reopen hub and verify signed row and share export.
Check Classic/Liquid, Arabic/English, small/large text and four-tab bottom layout.
Confirm main apps/downloads remain unchanged. No direct installation is implemented.
