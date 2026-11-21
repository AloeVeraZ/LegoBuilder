# BuildLens handoff

Written 2026-11-21 for whoever picks this up next. Read this first, then `docs/MORNING.md`
(setup checklist) and `glasses/README.md`.

## What this is

BuildLens shows LEGO building instructions in 3D on an iPhone and on **MicroLumin M6**
smart glasses (Android 9, 640×480 single-colour green waveguide display; black = see-through).
Demo set: LEGO Technic **42233-3 Dump Truck** (23 steps; the box says 46 pieces, the model
has 45 instances and the app shows 46 on purpose). It is a hackathon project ("Worn",
City Tech NYC, team Superpog).

- Repo: `~/Github/LegoBuilder`, remote `origin` = `github.com/AloeVeraZ/LegoBuilder`
  (a fork of the teammate's `bobotucs/LegoBuilder`; do not push to or merge into theirs).
- **`aloe/glasses-demo`**: the finished phone / Mac / glasses apps. The user considers the
  phone app done. Tag `demo-ready` marks an earlier agreed point on this branch.
- **`ghost-piece`**: the current work, built on top of `aloe/glasses-demo`. All new feature
  work goes here. General fixes have been cherry-picked to both branches so far.
- The MicroLumin SDK kit is **confidential**: never commit kit files, never put them in a
  public link. The glasses app deliberately does not use the SDK.

## The user

- New to Xcode and Android tooling. Give click-by-click steps naming exact buttons and menus.
- Dictates by voice, so messages are loose; work out the intent and act. They often say
  "don't ask, do what's best". Still ask before downloads, and say plainly when something
  cannot be done or has not been tested.
- Strong UI opinions, all already applied; keep to them:
  - No explainer or "how it works" text anywhere. It must be obvious without reading.
  - Only things that can be pressed may look like buttons.
  - Animation: the grounded piece and camera stay still; the waiting piece stays still and
    only its arrow bounces; a piece goes in over about half a second; motion only straight
    down or straight in from a side (90° only); nothing clips through anything; no click sound.
  - The model must be physically right (pins seated, shapes match holes) and look like the
    real LEGO set.
- They test on a real **iPhone 18 Pro Max** ("Aloe Iphone") plugged into the Mac, and send
  screenshots. AR cannot run in the simulator, so AR changes are only ever verified by them.

## Machine setup (already done on this Mac)

- Xcode 27.2, signed in with a free Personal Team (`7SZQGAT2TZ`); the phone app expires 7
  days after each install. Bundle id `com.aloeveraz.buildlens`.
- Homebrew: `adb`, `openjdk@17`, `android-commandlinetools`, `xcodegen`, `poppler`, node.
- Android SDK at `/opt/homebrew/share/android-commandlinetools` (platform 34, build-tools
  35.0.0, an Android 9 arm64 emulator image, AVD `glasses28`).
- LDraw parts library at `.ldraw/ldraw` (`pipeline/fetch_ldraw.sh`).
- Kokoro voice model at `~/Library/Caches/buildlens-voice` (own venv + `model/`), only
  needed to record new spoken lines.

## Everyday commands

```bash
app/install-iphone.sh        # build, sign, install and open on the plugged-in iPhone
app/install-mac.sh           # build the Mac app into /Applications (+ Desktop shortcut)

# Rebuild the model package (geometry, thumbnails, ~600 glasses frames, voice). A few minutes.
python3 pipeline/models/make_42233_3.py            # writes the .mpd
python3 pipeline/models/check_42233_3.py           # must print "OK: all 19 pins and axles..."
pipeline/make_package.sh pipeline/models/42233-3-dump-truck.mpd --set-id 42233-3 \
  --set-name "Dump Truck" --theme "Technic · Mighty Machines Series 1" --pieces 46

# Glasses app (plain Java, no Gradle)
export JAVA_HOME=/opt/homebrew/opt/openjdk@17 ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
(cd glasses && python3 make_assets.py && ./build.sh)   # -> glasses/dist/BuildLensGlasses.apk
```

The Xcode project uses file-system-synchronised groups: new Swift files are picked up
automatically. **Never edit `project.pbxproj`.** Note `.gitignore` ignores a `Build` path,
so `git add app/BuildLens/Build/...` needs `git add -u` or `-f`.

Commits end with `Co-Authored-By: ...` for the model that wrote them.

## How it is put together

**Model pipeline** (`pipeline/`)
- `models/make_42233_3.py` generates the LDraw `.mpd`. Layout is derived from how the parts
  connect, not placed by eye. Custom meta `0 !PUSH x y z [ORDER n] [STILL] [GAP n]` before a
  part says which way it goes in. Colours are overridden to match LEGO's photos.
- Four parts are hand-modelled because they are not in LDraw: bed panels 7450/7451, cab half
  7944, and the tyre 50951. They are close to the real set but not mould-exact; the bed's
  ends and underside are the weakest. The user accepted the current look but may ask for more.
- `ldraw2build.py` writes `build.json` + `geometry.bin` (metres, +Y up). `--seam 0.012`
  shrinks every part 1.2% about its middle to leave a hairline between pieces.
- `render/` (three.js + Playwright) draws thumbnails, the hero image and the glasses frames:
  per step and per side (`q0..q3`): waiting (`""`), arrow down (`-w`), going in (`-c`, `-a`,
  `-d`), seated (`-b`); `-r1..4` turning frames; `hud-finish-01..24` for the end spin.
- `make_voice.py` writes each spoken line in plain words and records it with Kokoro into
  `pipeline/voice-cache` (committed), then into `BuildData/voice`.

**Apple app** (`app/BuildLens`, SwiftUI + RealityKit + ARKit, iOS 18+/macOS 15+)
- `App/AppModel.swift`: all state. `next/back/replay/finish/go(to:)`, milestones ("good
  job" between sub-builds), `isSeating`, read-aloud via `speak(key, otherwise:)`, `hush()`.
- `Rendering/BuildScene.swift`: step display, slot-in animation, arrows, staged framing.
  `Rendering/ModelViewer.swift`: the 3D orbit view.
- `AR/ARExperienceView.swift`: scan the box (set number 42233 only), find the table, stand
  the model on it sized from camera distance, turn it to each step's side, finger rotation,
  view cube callbacks, home button (turns back, keeps zoom). **Do not call
  `stopAllAnimations()` on the model root**: it is recursive and freezes pieces mid slot-in.
- `Views/`: `HomeView` (one fixed page), `BuildScreen`, `BuildPanel`, `Cards`,
  `ViewCube` (faces, edges and corners are tappable; no arrows), `GlassesPreview`.
- `Services/GlassesLink.swift`: phone↔glasses link. `StepSpeaker.swift`: plays the
  recorded line, falls back to the system voice.
- The Mac app is only for showing judges: big Instructions tile, and a separate Glasses
  preview window. The Mac never links to the glasses.

**Glasses app** (`glasses/`, Android, plain Java)
- `LinkService`: foreground service, starts at boot, TCP server on port 52733 advertised as
  `_buildlens-glass._tcp`. One JSON object per line both ways: `step`, `finished`, `replay`,
  `open`, `view`, `milestone`, `hello`. The phone leads while its instructions are open.
- `MainActivity`: shows the pre-rendered frames. One click = next, two = replay, three =
  back; swipe = zoom. Slot-in over four frames, "good job" after the piece is in, spin and
  confetti at the end.
- `tools/fake_glasses.py` stands in for the glasses on the Mac (type `n`, `r`, `b`).

## What has and has not been verified

- Phone app: verified by the user on the real iPhone, including AR. Home, 3D and most UI
  also checked in the simulator.
- Glasses app: only ever run on the Android 9 emulator, and not since the latest changes
  (four-frame slot-in, finish spin, confetti). **It has never run on the real glasses.**
  The button key codes are guesses (`KEYS` table in `MainActivity.java`); map them with
  `adb logcat -s BuildLens` when the hardware arrives (`docs/MORNING.md` steps 2-4).
- Recorded voice: the 31 clips are in the app bundle; nobody has confirmed how it sounds on
  the phone yet.

## The ghost piece feature (the open work)

**What the user wants:** wearing the glasses, they hold real pieces; the glasses' camera
sees them, and the display shows a green ghost of the next piece exactly where it goes on
the real assembly, one piece at a time, moving on as each is pressed in. Only the phone and
the glasses may be used: no printed cards or other props.

**What was agreed as realistic:** tracking loose, thumb-sized, single-colour pieces in
someone's hands was judged not achievable reliably. The approach taken instead uses **the
phone as the landmark**: the phone lies on the table showing a QR marker, a camera finds
it, and the build stands at a fixed spot 11 cm to the right of the marker. The grounded
piece must sit on that spot, not loose in a hand. The user accepted this ("great idea").

**What exists on `ghost-piece`:**
- `Services/MarkerTracker.swift`: camera capture (AVFoundation), QR detection (Vision,
  payload `BUILDLENS-TABLE`, 50 mm wide), pose from the four corners by homography. The pose
  maths is checked against a synthetic pose (error ~1e-7). Focal length is an assumed 62°
  field of view, not calibrated.
- `Views/AssistView.swift`: draws the camera picture, a dashed ring where the build
  stands, what is already built (faint), and the step's new pieces in shaded green sliding
  into place one after another (grouped by `ORDER`), looping. Drawn with SwiftUI `Canvas`.
  Also `MarkerCard`: the full-screen marker on the phone (••• menu › Table marker).
- `GlassesPreview` on the Mac has a **Live** button that shows `AssistView`, with the Mac's
  camera standing in for the glasses' camera.
- **Nobody has run Live with a real camera and marker yet.** First thing to do: have the
  user try it (phone: Instructions › ••• › Table marker; Mac: Glasses preview › Live, allow
  the camera) and fix what turns up.

**Not built yet, roughly in order:**
1. Confirm an app can use the camera on the real glasses (Camera2 on Android 9) and what
   it sees. Everything below depends on this.
2. Get the ghost onto the glasses' display. Two routes: draw it on the glasses (port the
   projection to Android `Canvas`, ship the step geometry in the APK), or have the phone
   render and stream pictures over the existing link. On the glasses only the green is
   drawn, on black.
3. Line the picture up with what the wearer sees: the camera and the eye are in different
   places, so this needs a calibration step done with the glasses on.
4. Noticing that a piece has really been pressed in, to move on by itself. Today the user
   still presses Next / clicks.
5. While the phone shows the marker it cannot show the steps; decide whether that matters.

Be straight with the user about which of these work and which are untested; they would
rather hear it than have a demo fail in front of judges.
