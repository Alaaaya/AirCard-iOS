Video wallpaper experimental branch
==================================
Select Video from Photos in Wallpapers (Arabic title on Arabic devices).
The picker reads only the chosen video, copies its temporary provider URL,
trims to the first 10 seconds and center-crops after applying track rotation.
AVFoundation exports an HEVC/H.264 MOV, then samples at 24 fps, maximum 240
JPEG frames, 540 px wide at the device's portrait aspect ratio. The MOV is
temporary: PosterBoard consumes a looping CAML image sequence, not a MOV or
a Photos Live Photo.

The generated CollectionsPoster descriptor is packaged as .tendies and imported
using the existing TendiesEngine. Review/select it and tap the existing apply
button. This deliberately does not silently respring or apply on selection.
Source copies, MOV and intermediate frames are removed after conversion.

Compatibility
-------------
AirCard upstream reports airlift works on iOS 27.0.1, and patched starting
27.2 beta 3. There is no iOS 26.4 block in this feature. Playback and descriptor
compatibility still need testing on a real device. No successful build or
device test is claimed.

Build
-----
Run build-ipa.sh with macOS/Xcode, or manually dispatch unsigned-ipa.yml.
Linux build attempt failed because xcodebuild is absent. Account Actions billing
may prevent the macOS job from starting. No IPA exists until that job succeeds.

Licensing
---------
VideoCAML templates originate from leminlimez/Pocket-Poster (GPL-3.0).
See LICENSES. Preserve notices and provide corresponding combined source under
GPL-3.0 if distributing an IPA. Do not label the combined app as MIT-only.

Device acceptance checks
------------------------
Cancel picker; select iCloud video; select landscape/rotated/portrait clips;
try clips shorter and longer than 10 seconds; verify crop and first-frame
thumbnail; import/apply through normal paired VPN flow; confirm motion on lock
screen; force-close/relaunch and ensure imported wallpaper persists. Confirm
existing .tendies imports and other tabs remain unchanged.
