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

## The set-down check (moves on by itself)

While the ghost is up, the glasses check whether the step's new piece is really on the
build, and move on to the next step by themselves when it is, exactly as one click would
(the phone follows). The workflow: build in your hands as usual, put the build down on its
spot (where the ghost stands, about the way the ghost shows it), take your hands away. A
moment later the next step appears. Clicks keep working; when the glasses can't tell, they
simply wait for one.

- `SetDown` watches the spot: once it has changed (hands, the build picked up and put back)
  and then stays still for about half a second, it has the step checked. Two checks on two
  different pictures must both say the piece is on before moving on, and nothing is checked
  again until the spot changes.
- `PieceCheck` looks at one picture: the table's colour from a ring round the spot; the
  build's turn (within 45° of the ghost's) and position (within 2.2 cm of the spot), found
  by trying placings of the step's pieces against the picture's colours; then, pixel by
  pixel where the new piece should show, whether it looks like the piece or like what would
  be there without it. It answers DONE, NOT_YET or UNSURE (too little to see: the piece is
  on the far side, or the same colour as what is behind it, like a black axle in a black block).
- A copy of the new piece lying beside the build must not count: the build is also placed
  without the new piece, and the two placings must agree before it says DONE.
- The step shapes and colours come from `make_assets.py` (`assets/check.bin`).
- The table is taken to be a phone's thickness (8 mm, `PieceCheck.DROP`) below the marker
  on the screen; the ghost is now drawn at that height too (it used to stand on the screen's
  height, 8 mm too high).

Every check is logged: `adb logcat -s BuildLens | grep set-down` shows lines like
`set-down check, step 7: DONE p=0.93 votes 360/386 ... -> next step`, or UNSURE with the
reason. Those lines are what to send back when tuning it on the real glasses.

**Tested on this Mac, not on glasses.** `tools/test_check.sh` renders made-up glasses-camera
pictures (the phone with its real marker, the build on the spot, random tables, light,
shadows, turns, some with the new piece lying loose beside the build), runs the real marker
finder and the check on them, and tests `SetDown`'s timing:

| Build put down | Right | Unsure (waits for a click) | Moved on wrongly |
|---|---|---|---|
| About as the ghost shows (within 30°) | 39 of 92 | 46 | 0 |
| Any way at all (`--any-turn`) | 32 of 92 | 53 | 0 |

No wrong move on in 276 test pictures (67 with a loose copy of the piece beside the build).
On light tables it says DONE for about half the pieces put on; on dark tables (black and dark
grey pieces barely show) it mostly waits for a click. A check takes ~20 ms on a Mac; expect
a few hundred ms on the glasses (it runs on the camera's thread, once per set-down).

Unknown until it runs on the glasses: whether the camera's picture is sharp and big enough
(the build is only 50-150 pixels across at 1280 wide from 40-55 cm), the real lighting, and
how still people's heads are. Build on a light, plain table for the best chance.

## Rebuild

`./build.sh` (needs Python 3 with numpy, a JDK and the Android SDK with `platforms;android-34` and
`build-tools;35.0.0`; set `ANDROID_HOME`, and `JAVA_HOME` if `java` is not on your path). It copies the frames and steps from
`app/BuildLens/Resources/BuildData` first, so rerun it after changing the model.

The MicroLumin SDK kit is confidential and is not part of this repo; this app doesn't need it.
