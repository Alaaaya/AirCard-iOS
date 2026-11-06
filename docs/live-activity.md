# Mirsa download and install Live Activity

## Included

`MirsaLiveActivity` is an embedded WidgetKit extension. `MirsaDownloadAttributes`
is compiled into the app and extension. The extension offers lock-screen,
compact, expanded, and minimal Dynamic Island presentations. The lock-screen
and expanded views show download bytes and real percent when the server provides
a total length. Unknown lengths and non-measurable signing stages are explicitly
indeterminate, not simulated progress. Arabic text retains left-to-right layout.

`MirsaInstallActivity` owns ActivityKit request/update/end. Background URLSession
tasks carry the opaque operation ID in `taskDescription` so a callback after an
iOS relaunch can reattach to the existing activity. URLs, local paths, Apple ID
credentials and certificates are never sent to the widget. Percent updates are
coalesced (at most one per second) and serialized with final states. Success or
failure ends the activity with a brief lock-screen summary; cancellation ends it
immediately. A background-completed IPA without an in-memory continuation is
shown as ready to continue, not installed. Stale data is labeled as last known
status after 90 seconds without an update.

## Important limitations

This is **real-installed Mirsa only**, not container mode. The container signer
removes `PlugIns` (`rust-core/src/container.rs`), and a dynamically loaded app
cannot register a WidgetKit extension with iOS. The real-installed app must
include `PlugIns/MirsaLiveActivity.appex` and its signed extension must be
registered and accepted by iOS. A Dynamic Island presentation also requires
supported hardware and permission in Settings. No notification permission or
push entitlement is needed for local ActivityKit updates themselves.

**Extension signing and provisioning are not verified on a device.** The nested
bundle signer visits `PlugIns`, but `rust-core/src/sideload.rs` currently chooses
`ExtensionsBehavior::ReuseMain`. Recursively signing an extension is not proof
that its profile or final bundle identifier is valid for iOS. External signers
must preserve the extension, sign its executable and provide valid matching
provisioning. A signer that drops extensions cannot support this feature. Do not
claim this works on-device until a signed IPA has been installed and exercised.

The Setup packaging workflow rebases embedded `.appex` bundle IDs to the Setup
parent (`com.alaa.mirsa.setup`) and synchronizes their versions. This fixes the
unsigned archive's parent-prefix consistency; it does not fix or validate
provisioning, entitlement rewriting, or the signer's extension policy.

There is no APNs server. Download transfer continues under iOS background
URLSession, but UI updates only happen when iOS gives Mirsa execution time.
Background ActivityKit updates are best effort and can be delayed/throttled.
Leaving the app does not grant indefinite background signing/installation;
the displayed status may become stale and require reopening Mirsa. Force-quitting
can cancel background transfers until the app is reopened. Tapping the activity
opens Mirsa; the downloads URL does not bypass the existing import/editor flow.

## Release validation still required

Generate the Xcode project and build both app and extension on macOS with Xcode.
Inspect the resulting IPA for the extension executable, `NSExtension` dictionary,
parent `NSSupportsLiveActivities`, consistent versions and parent-prefixed bundle
IDs. Then validate after real signing and device installation: known/unknown
length, cancel, failure, suspended/resumed transfer, OS relaunch, import/editor,
signing/install success/failure, disabled permission and stale display. Check
both the regular app and Setup parent IDs. Source/static checks on Linux are not
a replacement for Swift compilation or device tests.
