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
- **Controls** (side button, touchpad tap or ring):
  one click = next step, two clicks = this step again, three clicks = back one step.
  Swiping the touchpad forward zooms the picture in, back zooms it out.
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

With the phone lying on the table showing its marker (iPhone: Instructions › ••• › Table
marker), the glasses' camera finds it and the step pictures give way to the step's pieces
drawn in green right where they go: the build stands 11 cm to the right of the phone's
code, what is already built shows faintly, and the new pieces go in one after another, as
on the phone. Look away from the phone and the step pictures come back. Clicks work the
same either way.

How it works: `CameraFeed` takes the camera picture (Camera2, up to 1280 wide, about 15
searches a second), `QrFinder` finds the marker by its three big squares and the small
one, checks all 27 × 27 cells against the known picture, and `MarkerRefine` fits the whole
picture to the camera image to a fraction of a pixel. `MarkerPose` turns that into where
the phone is in space, `Lineup` maps camera to display, and `GhostView` draws the pieces
with OpenGL ES 2 (the step shapes come from `make_assets.py`: `assets/ghost.json` + `ghost.bin`).

Limits: the marker is 50 mm across, so the camera has to be within roughly 60 cm of it
(less when looking at it from a steep angle). The line-up is exact at the distance it was
done at and drifts a little nearer or further away.

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
