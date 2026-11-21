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
  Swipes and arrow keys also go forward and back.
- **Battery.** The glasses render nothing: every picture is drawn on a computer by the
  pipeline and only shown here. The arrow's bounce is two pictures swapped by a timer and
  stops after 20 seconds without input; after 5 idle minutes the display may sleep.

Nothing public documents which key codes the M6's buttons send, so the app follows what
similar glasses do and logs every key and touch. If a button does nothing, run
`adb logcat -s BuildLens`, press it, and add the code it prints to the `KEYS` table at the
bottom of `MainActivity.java`.

## Install

1. In MLDemo (from the MicroLumin kit), connect the glasses, join them to the same Wi-Fi as
   your iPhone (Wi-Fi screen), and turn on **Developer Mode** (Glasses screen › Developer).
2. Replug the glasses' USB cable into your computer and check `adb devices -l` shows `model:XNM_Glass`.
3. Install it, and open it once (Android only lets an app start by itself after it has
   been opened once):

   ```bash
   adb install -r glasses/dist/BuildLensGlasses.apk
   adb shell am start -n com.buildlens.glasses/.MainActivity
   ```

## Rebuild

`./build.sh` (needs a JDK and the Android SDK with `platforms;android-34` and
`build-tools;35.0.0`; set `ANDROID_HOME`, and `JAVA_HOME` if `java` is not on your path). It copies the frames and steps from
`app/BuildLens/Resources/BuildData` first, so rerun it after changing the model.

The MicroLumin SDK kit is confidential and is not part of this repo; this app doesn't need it.
