# BuildLens

Step-by-step 3D building instructions for a brick set, on an iPhone, a Mac and
MicroLumin M6 glasses. All three stay on the same step. On the glasses, the step's new
pieces float in green in front of you while both hands build.

Demo set: 42233-3 Dump Truck (46 pieces, 23 steps).

## Install

You need a Mac with Xcode 16+ and [Homebrew](https://brew.sh). For the iPhone (iOS 18+),
sign in to your Apple ID in Xcode › Settings › Accounts first.

```bash
git clone https://github.com/AloeVeraZ/LegoBuilder.git && cd LegoBuilder && ./install.sh
```

This installs the Mac app, and the iPhone app if a phone is plugged in.

For the glasses, turn on Developer Mode (USB debugging), plug them into the Mac, then:

```bash
glasses/setup.sh
```

It installs the glasses app and walks you through lining the camera up with your eye
(once). If someone else wears the glasses, run `glasses/setup.sh lineup`.

## Use it

1. **Scan the box.** The glasses open on "scan the box". Show the barcode to the iPhone app,
   or hold the touchpad on the glasses to skip.
2. **Scan the phone.** On the iPhone, open Instructions › ••• › Table marker and lay the phone
   flat. Look so the code sits in the circle on the glasses, and tap.
3. **Build.**

| Touchpad | Does |
|---|---|
| Tap | Next step |
| Double tap | Previous step |
| Flick forward / back | Turn the model |
| Triple tap | Flicks zoom instead, for 5 s |
| Hold | Menu: read aloud, voice, scan again, replay |

## Debug the glasses

Watch the log while you use them:

```bash
adb logcat -s BuildLens
```

Rebuild and reinstall after changing anything in `glasses/`:

```bash
glasses/build.sh && glasses/setup.sh
```

The first build needs the Android tools:

```bash
brew install openjdk@17 android-platform-tools && brew install --cask android-commandlinetools && sdkmanager "platforms;android-34" "build-tools;35.0.0" && pip3 install numpy
```

Tests that run on the Mac, without glasses:

```bash
glasses/tools/test_marker.sh
```

```bash
cd pipeline/render && npm install && cd ../.. && glasses/tools/test_check.sh
```

The first checks the phone-code finder, the second the check that moves on by itself once
the new piece is on the build. How the glasses app works, and what each log line means, is in
[glasses/README.md](glasses/README.md).

## What's where

| Folder | |
|---|---|
| `app/` | iPhone and Mac app (SwiftUI, one Xcode project) |
| `glasses/` | Glasses app (Android 9, built without Gradle) |
| `pipeline/` | Turns a digital model of a set into the apps' step data |
| `web/` | Browser version: open `web/dist/BuildLens.html` in Chrome or Edge |
| `docs/HANDOFF.md` | Current state of the project and what's next |
