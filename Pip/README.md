# Pip: several photos in Picture in Picture

A separate iPhone app from Edge. Pick photos and float them over whatever else you are doing, in the system's
Picture in Picture window.

- **Photos:** add any number from your photo library (Pip keeps its own copies), reorder or remove them.
- **Several at once:** show 1, 2, 3, 4, 6 or 9 photos at a time, as a grid or as one large photo with the others inset.
- **Window shape:** wide, classic, square, tall, phone, or the shape of the first photo. Photos fill their frame or show whole.
- **In the floating window:** the skip buttons go to the previous or next photos; play/pause turns automatic changing
  (every 2 to 120 seconds) on or off. The window opens by itself when you leave the app, if you want.

## How it works

Picture in Picture only takes video. Pip draws each page of photos into a video frame (`PiP/FrameRenderer.swift`) and
feeds an `AVSampleBufferDisplayLayer`, which `AVPictureInPictureController` can float (`PiP/PipEngine.swift`). The
window's timeline is the slideshow: each page lasts the chosen number of seconds. iOS only allows Picture in Picture
with a playback audio session and the audio background mode; Pip plays no sound and mixes with other apps' audio.

Every push to `Pip/` builds `Pip-unsigned.ipa` into a `pip-build-N` release. Sign it while installing with AltStore /
SideStore or Sideloadly, or install it with TrollStore.

Build locally: `cd Pip && xcodegen generate && open Pip.xcodeproj`.
