# BuildLens — Claude quick context

Loaded every session. Keep it short; it exists so you don't have to re-read the repo.
Longer docs (only open when the task needs them): `glasses/README.md` (glasses app, current),
`docs/HANDOFF.md` (history, partly stale: predates BLE), `docs/MORNING.md` (setup), `vision/README.md` (dropped LLM experiment).

## What it is
Step-by-step 3D build instructions for one brick set (42233-3 Dump Truck, 23 steps, shows 46 pieces)
on **iPhone + Mac** (one SwiftUI app) and **MicroLumin M6 glasses** (Android 9, 640×480, mono green,
black = see-through). All stay on the same step. Hackathon project. Branch: `main`.

## Don't read these (big / generated) — saves tokens
- `app/BuildLens/Resources/BuildData/` (hud/ ~600 PNGs, voice/, thumbs/, geometry.bin, build.json) — pipeline output
- `pipeline/voice-cache/`, `pipeline/models/*.mpd`, `pipeline/samples/`, `web/dist/BuildLens.html`
- `glasses/dist/`, `glasses/libs/`, `*.xcassets`, `package-lock.json`, `app/BuildLens.xcodeproj/project.pbxproj`
- `glasses/src/.../MainActivity.java` is 1.6k lines: grep it, don't read it whole.

## Where things are
**Apple app** `app/BuildLens/` (SwiftUI + RealityKit + ARKit, iOS 18+/macOS 15+)
- `App/AppModel.swift` — all state: `next/back/replay/finish/go(to:)`, settings in UserDefaults, read-aloud
- `App/BuildConfig.swift` — set id, barcode, item numbers
- `Build/BuildModel.swift` — loads build.json; `spokenSummary(for:)`
- `Rendering/BuildScene.swift` (step display, slot-in anim, arrows) · `ModelViewer.swift` (orbit view)
- `AR/ARExperienceView.swift` — box scan, table, AR model. Never call `stopAllAnimations()` on the model root.
- `Views/` — HomeView, BuildScreen, BuildPanel, Cards, ViewCube, GlassesPreview (Mac), AssistView + MarkerCard (table marker), BoxScanView
- `Services/` — glasses links: `GlassesBLE` (phone↔glasses Bluetooth), `GlassesLink` (TCP 52733), `USBLink` (phone↔Mac cable, usbmuxd 52735), `PeerSync` (Multipeer phone↔Mac), `GlassesFeed` (camera 52734), `GlassesInstaller` (Mac installs APK). Plus `StepSpeaker`, `VoiceCommands`, `MarkerTracker`, `BoxScanner`.

**Glasses app** `glasses/src/com/buildlens/glasses/` (plain Java, no Gradle, no MicroLumin SDK)
- `MainActivity` — screens, touchpad gestures, menu, `KEYS` table (key codes) at the bottom
- `LinkService` (TCP server 52733, starts at boot) · `BleLink` (BLE peripheral, UUIDs `6b1d000{1..4}-…`, same lines as TCP)
- Ghost: `CameraFeed` → `QrFinder` → `MarkerRefine` → `MarkerPose` → `Lineup` → `GhostView` (GLES2; `FOLLOW_VIEW=true`) using `GhostModel`; `HeadTracker` (gyro)
- Auto-advance: `SetDown` (spot still?) + `PieceCheck` (piece there? DONE/NOT_YET/UNSURE) + `CheckModel`
- `BarcodeReader` (ZXing), `LiveFeed`, `OpenService` (accessibility, opens screen), `BootReceiver`
- `make_assets.py` builds `assets/` (frames, ghost.*, check.bin) from BuildData; `tools/` = Mac tests, `fake_glasses.py`

**Pipeline** `pipeline/` — `models/make_42233_3.py` → .mpd → `make_package.sh` (ldraw2build.py, `render/` three.js+Playwright frames, `make_voice.py` Kokoro) → BuildData.
**Web** `web/src/` — old browser version. **Vision** `vision/` — abandoned, ignore.

## Link protocol (all transports)
One JSON object per line. Keys include: `step`, `finished`, `replay`, `open`, `view`, `milestone`, `hello`,
`scan`, `box`, `placed`, `spin`/`zoom`/`tilt`, `fade`/`voice`/`aloud`, `wake`. Change both sides together:
`LinkService.java`/`BleLink.java` ↔ `GlassesLink.swift`/`GlassesBLE.swift`/`PeerSync.swift`.
Mac bridges glasses over USB (`adb forward`); phone↔glasses with no Mac = BLE.

## Commands
```bash
app/install-iphone.sh                      # build+install+open on plugged-in iPhone (retry if Xcode says "Preparing")
app/install-mac.sh                         # Mac app → /Applications
glasses/build.sh && glasses/setup.sh       # rebuild APK (runs make_assets.py) + install; `setup.sh lineup` = redo eye line-up
adb logcat -s BuildLens                    # glasses log (grep "set-down|camera|ble")
glasses/tools/test_marker.sh               # marker finder tests (Mac)
glasses/tools/test_check.sh                # set-down tests; needs `cd pipeline/render && npm install` once
python3 pipeline/models/check_42233_3.py   # after model edits: must print "OK: all 19 pins and axles..."
```
Emulator: AVD `glasses28`; fake camera with `am start -n com.buildlens.glasses/.MainActivity --es picture table.png`.
Android SDK `/opt/homebrew/share/android-commandlinetools`, JDK `openjdk@17`.

## Rules / gotchas
- **Never edit `project.pbxproj`** — groups are folder-synced; new Swift files are picked up automatically.
- `.gitignore` ignores `Build` → `git add -f app/BuildLens/Build/...`.
- MicroLumin SDK kit is **confidential**: never commit or link it. User has no MLDemo; glasses go via USB/BLE.
- Remote `origin` = AloeVeraZ/LegoBuilder. Never push to `upstream` (bobotucs).
- Glasses APK version = commit count; rebuild + commit `glasses/dist/` when glasses code changes, or the Mac thinks it's current.
- AR only works on a real iPhone (not simulator). Glasses: verify on emulator first when visible there.
- Shared Swift code compiles for both iOS and macOS — guard with `#if os(iOS)` (see `Platform.swift`).
- Design: no explainer text; only pressable things look like buttons; motion straight down or straight in (90°); no click sound;
  no skip on phone box scan; no Start over on glasses; don't change phone pinch/pan. Say "BuildLens", not the toy brand.
- Be honest about what's untested on real hardware; the user would rather know.

## Open work
Re-localise on the phone's marker and stand the build on the table beside the phone (`FOLLOW_VIEW=false`,
`GhostView.anchor`, `BUILD_OFFSET`, table = marker − phone thickness `PieceCheck.DROP`). Phone finish/replay
doesn't cross the Mac bridge. Gyro axes vs camera unverified (`glasses/tools/axes.py`).

## User's workflow
Batch related changes, check them (tests/emulator), then install. "Start it up" = `app/install-iphone.sh`,
confirm BLE link in device console (`ble: connected`), relaunch the app.
