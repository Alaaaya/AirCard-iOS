# Keyboard dismissal private patch

Base 8dce09f. Only the keyboard wrapper changes the project view.
The progress operation and browser workers own their separate changes.

## Implementation

MirsaApp installs one non-cancelling tap recognizer on its own app window.
The app has no separate text-entry hosting windows (the only other hosting
controller is the image cropper). Presented sheets are in the same window.
No global UIApplication action, keyboard-safe-area suppression, focus stealing,
or high-priority SwiftUI gesture is used.

TextField, SecureField and TextEditor editing/selection subviews are excluded.
Other taps dismiss editing without cancelling or delaying their control action.
The root interactive-scroll environment propagates through child forms and
presented sheets. Project details also declares interactive dismissal explicitly.
Keyboard observers remove the bottom project CTA from layout and accessibility
from willShow until didHide, including interactive dismissal cancellation.
SwiftUI retains normal keyboard avoidance and scrollable input reachability.

## Native validation

MirsaKeyboardTests covers real notification lifecycle; text/secure input
exclusion; non-cancelling recognizer lifecycle; and actual project fixture with
OS software keyboard and real first responder. Runtime test checks focused
field above the reported keyboard frame, interactive scroll mode, absent CTA
while editing, and restored CTA afterward. Full XCUIScreen attachments include
the actual keyboard, not a composited picture.

The notification unit test is explicitly distinct from the OS-keyboard test.
No screenshot or runtime success may be claimed before the native run passes.
Synthetic fixture IPA contains no signing key. No production feed or release is
changed by keyboard-validation.yml.

## Remaining physical-device checks

Tap blank card, header, label, and whitespace outside fields. Check that the
first tap still performs normal buttons/toggles and that tapping between inputs
preserves focus. Check long-press selection, caret positioning and SecureField
eye toggle. Drag interactively down then cancel upward; CTA must stay hidden
until the keyboard actually leaves. Check bottom project fields scroll into
view. Repeat inside login, 2FA, certificate password and import sheets.
VoiceOver native text editing must remain usable. These touch/accessibility
device checks are not replaced by the source or notification unit tests.
