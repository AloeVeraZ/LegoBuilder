# BuildLens for the MicroLumin M6 glasses

A small Android app (Android 9, 640×480, black = see-through) that shows the current
building step: the green frame of the model with the new pieces filled in, the step number,
the sub-build name and the pieces to add.

- **Next / back:** temple touchpad, ring, swipe or tap (arrow keys, Enter and media keys also work).
  Every key press is logged, so unknown buttons can be mapped: `adb logcat -s BuildLens`.
- **Follows the iPhone app** over Wi-Fi. The glasses advertise `_buildlens-glass._tcp`; the
  iPhone app finds and connects to them automatically, and steps changed on either side show on both.

## Install

1. In MLDemo (from the MicroLumin kit), connect the glasses, join them to the same Wi-Fi as
   your iPhone (Wi-Fi screen), and turn on **Developer Mode** (Glasses screen › Developer).
2. Replug the glasses' USB cable into your computer and check `adb devices -l` shows `model:XNM_Glass`.
3. Install and start:

   ```bash
   adb install -r glasses/dist/BuildLensGlasses.apk
   adb shell am start -n com.buildlens.glasses/.MainActivity
   ```

## Rebuild

`./build.sh` (needs a JDK and the Android SDK with `platforms;android-34` and
`build-tools;35.0.0`; set `ANDROID_HOME`). It copies the frames and steps from
`app/BuildLens/Resources/BuildData` first, so rerun it after changing the model.

The MicroLumin SDK kit is confidential and is not part of this repo; this app doesn't need it.
