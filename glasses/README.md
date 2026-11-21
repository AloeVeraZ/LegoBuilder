# BuildLens for the MicroLumin M6 glasses

A small Android app (Android 9, 640×480, black = see-through) that shows the current
building step the same way the phone does: the new piece waits just off its place while
an arrow bounces towards where it goes, and moving on slots it in before the next piece
appears. It also shows the step number, which part of the build you are on (main build or
a sub-build) and the pieces to add.

## How it behaves

- **Nothing to start.** A small link service runs from the moment the glasses are switched
  on. The iPhone app finds it by itself over Wi-Fi (`_buildlens-glass._tcp`), and opening
  the instructions on the phone brings the glasses' screen up.
- **Stays on.** Closing the phone app does not close the glasses; they keep their step.
- **Both ways.** A step changed on the phone shows on the glasses and the other way round.
- **Start: scan the box.** The app opens on "scan the box": hold the barcode on the set's
  box (6 73419 42442 4) with the phone (barcode, item number 6588582 or set number 42233;
  BuildConfig.swift), which tells the glasses. The glasses also try with their own camera
  (ZXing, libs/, Apache 2.0), and seeing the phone's code counts too. Hold the touchpad to
  skip it. The Mac does not scan; it passes the news on.
- **Then: scan the phone.** Next comes the scan: a circle in the middle and "put the
  code on your phone in the circle, then tap". On the iPhone: Instructions › ••• › Table
  marker (the glasses also ask the phone to put it up by itself, `"scan": true` on the link,
  once phone and glasses are linked over Wi-Fi). Look so the code sits in the circle and
  tap (any tap counts while scanning): that finds the phone and lines the camera up with
  this wearer's eye in one go. With no tap for two minutes the scan starts again by itself.
- **Build.** The green model sits in the middle of the view and follows the head
  (GhostView.FOLLOW_VIEW; the phone's code is still tracked, for putting it on the table
  later). Each new step turns it to the side the phone app shows that step from. The step
  picture hides while the model shows; the step's words stay.
- **Controls** (touchpad; it reports only finished gestures, never fingers or position):
  tap = next step, double tap = back (the M6 sends its double tap as F12 and then a Back
  key of its own, which is ignored), quick flick forward/back = turn the model a quarter
  turn, triple tap = flicks zoom instead (back to turning after 5 s without a flick),
  hold = the menu (a slow slide also reads as a hold). A tap the touchpad adds at the end
  or start of a flick is ignored. Back never leaves the app.
- **Shared view.** Turn and zoom are one state on phone, Mac and glasses: flicks on the
  glasses move the phone's 3D view, and turning or pinching on the phone (3D, or turning in
  AR) moves the glasses, about 30 times a second. Phone and Mac talk over Wi-Fi or the USB
  cable (USBLink, through macOS's usbmuxd); the Mac talks to the glasses over USB (adb).
- **Menu**: Fade built pieces, Read steps aloud, Voice (the phone's settings: a change on
  either goes to the other), Scan phone again, Replay step. No Start over on the glasses.
  Swipe to move, tap to switch or do, double tap to go back to the model; it closes by
  itself after 20 s, and opening it stops the voice.
- **Sound.** The M6 clicks on every touchpad gesture (the system does it, on the media
  channel). While BuildLens is open that channel is muted and put back afterwards; Read
  steps aloud plays on the alarm channel instead.
- **Live view on the Mac.** With the glasses plugged into the Mac, the Mac app's Glasses
  preview shows the glasses' camera in colour, with the ghost drawn where the glasses
  think it goes. It goes over the USB cable only (`adb forward`, port 52734).
- **Battery.** The step pictures are drawn on a computer by the pipeline and only shown
  here. The arrow's bounce is two pictures swapped by a timer and stops after 20 seconds
  without input; after 5 idle minutes the display may sleep. The camera runs while the app
  is open, to notice the marker; that is the main cost.

Nothing public documents which key codes the M6's buttons send, so the app follows what
similar glasses do and logs every key and touch. If a button does nothing, run
`adb logcat -s BuildLens`, press it, and add the code it prints to the `KEYS` table at the
bottom of `MainActivity.java`.

## Set up (one command)

1. In MLDemo (from the MicroLumin kit), connect the glasses, join them to the same Wi-Fi as
   your iPhone (Wi-Fi screen), and turn on **Developer Mode** (Glasses screen › Developer).
2. Plug the glasses into this Mac, then:

   ```bash
   glasses/setup.sh
   ```

   It finds the glasses, installs the app with the camera already allowed, opens it, and
   walks you through lining up the camera with your eye (once; the glasses remember it).
   `glasses/setup.sh lineup` lines up again, e.g. if someone else wears them.

## The ghost

Once the phone's code has been scanned, the step's pieces are drawn in green in the middle
of the view and stay there as the head turns (`GhostView.FOLLOW_VIEW`): what is already
built shows faintly, and the new pieces go in one after another, as on the phone. The
code's place on the table is still tracked (camera plus gyroscope), for standing the build
on the table later; with `FOLLOW_VIEW` off the build stands on the code instead.

How it works: `CameraFeed` takes the camera picture (Camera2, up to 2048 wide, about 15
searches a second), `QrFinder` finds the marker by its three big squares and the small
one, checks all 27 × 27 cells against the known picture, and `MarkerRefine` fits the whole
picture to the camera image to a fraction of a pixel. `MarkerPose` turns that into where
the phone is in space, `Lineup` maps camera to display, and `GhostView` draws the pieces
with OpenGL ES 2 (the step shapes come from `make_assets.py`: `assets/ghost.json` + `ghost.bin`).

Range: the phone's marker is 67.9 mm across (as wide as the screen allows, at full
brightness) and the glasses look at it in 2048 x 1536, so it is found lying flat on the table
from a normal seat, about half a metre away. It needs about 4 camera pixels a cell. The
line-up is exact at the distance it was done at and drifts a little nearer or further away.
Until the glasses are lined up the ghost is not drawn on them (it would be in the wrong
place); the step picture stays full size. With the ghost up, the step picture sits small in
the top right corner.

Trying it without glasses: `tools/test_marker.sh` checks the marker finder on made-up
camera pictures on this Mac. On the emulator, a still picture can stand in for the camera:

```bash
adb push table.png /sdcard/Android/data/com.buildlens.glasses/files/
adb shell am start -n com.buildlens.glasses/.MainActivity --es picture table.png   # "camera" goes back
```

The log (`adb logcat -s BuildLens`) prints everything the camera says about itself, how
often the marker is seen and how long a search takes.

## Rebuild

`./build.sh` (needs Python 3 with numpy, a JDK and the Android SDK with `platforms;android-34` and
`build-tools;35.0.0`; set `ANDROID_HOME`, and `JAVA_HOME` if `java` is not on your path). It copies the frames and steps from
`app/BuildLens/Resources/BuildData` first, so rerun it after changing the model.

The MicroLumin SDK kit is confidential and is not part of this repo; this app doesn't need it.
