# BuildLens

Scan a brick set with your phone and follow 3D, step-by-step building instructions.
The model appears in AR on your table, each step's new pieces fly into place under a
bouncing arrow, and the pieces you need are listed with pictures and counts.
The same app runs on the Mac, and the two stay on the same step.

Hackathon demo set: **77243 Oracle Red Bull Racing RB20 F1 Race Car** (251 pieces).

> **Right now the app shows a stand-in model** (a small 61-piece car from the LDraw
> sample library), because we don't have a digital model of 77243 yet. See
> [Swap in the real RB20 model](#swap-in-the-real-rb20-model). Scanning already looks
> for "77243", so you can test it with the real box today.

## What's in the repo

```
app/                      Xcode project: one SwiftUI app for iPhone + Mac
  BuildLens.xcodeproj
  BuildLens/
    App/                  app state (AppModel), set config (BuildConfig), helpers
    Build/                loads the step data the converter produces
    Rendering/            RealityKit scene (pieces, highlight, arrow) + 3D orbit viewer
    AR/                   camera scanning (reads "77243") and AR placement (iPhone only)
    Services/             voice commands, read-aloud, iPhone<->Mac step sync
    Views/                screens
    Resources/BuildData/  the converted model: build.json, geometry.bin, thumbnails, glasses frames
pipeline/                 turns a digital brick model into the app's step data
  ldraw2build.py          LDraw / Studio .io  ->  build.json + geometry.bin
  render/                 headless three.js renderer: part thumbnails, glasses frames, previews
  make_package.sh         convert + render + copy into the app, in one go
  fetch_ldraw.sh          downloads the LDraw parts library (needed by the converter)
web/                      Windows / browser version: builds one self-contained BuildLens.html
docs/GLASSES.md           plan for the MicroLumin M6 glasses version
```

## Run it on Windows (or any computer)

Open **`web/dist/BuildLens.html`** in Chrome or Edge. On GitHub, open the file and use
**Download raw file**, then double-click it. It's a single self-contained file with no install,
no server and no internet needed, and it works offline at a demo table.

- `←` / `→` (or Space) change steps, `R` replays the step, `G` shows the glasses preview.
- Drag to orbit, scroll to zoom, right-drag to pan.
- 🎤 **Voice**: say "next", "back", "repeat" or "done" (Chrome/Edge; allow the microphone).
- **Read aloud** speaks each step; **Focus on new** fades the earlier pieces.

The Windows version has the 3D steps, parts list, voice and glasses preview. It has no
camera scanning or AR; those are iPhone-only for now. To rebuild it after changing the
model, run `cd web && npm install && npm run build`. `make_package.sh` also does this
automatically.

## Run it on your iPhone and Mac

You need Xcode 16 or newer, and an iPhone on iOS 18+ (any iPhone XS or newer). The Mac
needs macOS 15+.

1. Open `app/BuildLens.xcodeproj` in Xcode.
2. Click the **BuildLens** target, open **Signing & Capabilities**, pick your **Team**, and
   change the **Bundle Identifier** to something unique, such as `com.yourname.buildlens`.
3. iPhone: plug it in (or pair it over Wi-Fi), pick it as the run destination, then press **Run**.
   The first time, allow the developer certificate on the phone under
   Settings → General → VPN & Device Management.
4. Mac: pick **My Mac** as the destination and press **Run**.

AR and camera scanning only work on a real iPhone. The Simulator and the Mac use the 3D viewer.

> The code was written in a Linux container with no Xcode, so it has been syntax-checked
> but **not compiled yet**. If the first build shows errors, paste them to Claude and they'll
> be fixed quickly. If Xcode can't open the project at all, regenerate it:
> `brew install xcodegen && cd app && xcodegen`.

## Put it on TestFlight

This needs a paid Apple Developer account.

1. In [App Store Connect](https://appstoreconnect.apple.com), go to **My Apps → + → New App**.
   Choose iOS, use the same bundle ID as in Xcode, and give it any name and SKU.
2. In Xcode, set the destination to **Any iOS Device (arm64)**, then choose **Product → Archive**.
3. In the Organizer window, choose **Distribute App → TestFlight & App Store**, then **Upload**.
4. After processing (about 5–15 minutes), the build shows under **TestFlight** in App Store Connect.
   Add yourself (and teammates) as internal testers and install it with the TestFlight app.

The app already includes the app icon, the permission texts and the "no encryption"
flag, so the upload shouldn't ask any extra questions. For each new upload, increase
**Build** (`CURRENT_PROJECT_VERSION`) by one.

## Swap in the real RB20 model

The app's 3D steps come from a digital model of the set that contains its build steps.
Getting that model is the main piece of work left.

**1. Get a model of 77243 with steps (one of these):**

- **Look for one.** Open BrickLink Studio (free) on the Mac, go to the **Gallery**, and search
  for "77243" or "RB20". Rebrickable sometimes has one too. Download the `.io` file.
- **Build it yourself in Studio** from the official PDF, which is on lego.com under
  building instructions for 77243. That's about 2–3 hours for 251 pieces.
  - Add pieces in the same order as the booklet, and start a new step for each booklet step.
  - For the bits the booklet builds separately, use Studio's submodels. The app then shows
    them on their own first, and attaches them in the right step.
  - For the demo, the first 10–15 steps are enough to show following along. The complete
    model makes the "scan the box and it pops out" moment much better, though.
- LDraw `.ldr` / `.mpd` files from other tools (LeoCAD, Mecabricks exports) work too.

**2. Convert it and rebuild the app:**

```bash
pipeline/fetch_ldraw.sh
```

```bash
pipeline/make_package.sh path/to/77243.io --set-id 77243-1 --set-name "Oracle Red Bull Racing RB20 F1 Race Car" --theme "Speed Champions"
```

Then run the app again from Xcode. The converter needs `python3` with `numpy`
(`pip3 install numpy`). The renderer needs Node.js and Playwright
(`npm i -g playwright && npx playwright install chromium`).

Alternatively, send the `.io` / `.ldr` file to Claude and the conversion will be done for you.

The converter prints any pieces it can't find in the parts library. Very new 2025 pieces
may be missing; they show up as grey placeholder bricks until they're added.

## Demo script (about 2 minutes)

1. **Scan.** Open the app and tap **Scan your set**. Point the phone at the 77243 box.
   The app reads the set number, and the finished car grows out of the box with a spin.
   *"Set found · 251 pieces · N steps."*
2. **Build.** Tap **Start building**. Step 1's pieces fly into place with a yellow arrow over
   them, and the bottom strip shows exactly which pieces to grab. Drag to move the car,
   pinch to resize, twist to turn it. Your hands show in front of the hologram.
3. **Hands-free.** Open the ••• menu and turn on voice control. Say *"next"* and *"back"*.
   Turn on **Read steps aloud**.
4. **Mac + glasses.** On the projected Mac, the same step follows the phone automatically.
   Open **Glasses preview** to show the green 640×480 frame the smart glasses will display.
5. **Pitch:** on the phone you hold the device; on the MicroLumin glasses the same steps float
   in your view while both hands build.

## How it works

**Pipeline (runs once per model).** `ldraw2build.py` reads LDraw / Studio files and resolves
every piece against the official LDraw parts library. For each unique part it builds a
triangle mesh: colours, back-face winding, smooth normals, and a conversion to metres
with +Y up. It then works out the step sequence, including sub-assemblies, which are
shown on their own first and then attached, the way printed instructions do it. The
renderer (three.js in headless Chromium) draws a thumbnail for every piece/colour, plus
a green line-art 640×480 frame of every step for the glasses.

**App.** RealityKit draws one entity per piece, sharing meshes per part. A step shows the
pieces built so far, gives the new pieces a glow, and animates them in from outside the
model: from above, from the side, or from below. Sub-assembly steps show only that
sub-assembly. ARKit handles the camera:
- The Vision framework reads the set number from the box.
- An optional photo of the box front (`BoxFront.jpg`) also enables image tracking.
- Plane detection, person occlusion and grounding shadows are on.
- Gestures move, rotate and scale the model.

MultipeerConnectivity syncs the step between nearby devices, and the Speech framework
handles voice commands.

**Tweak the set settings** in `app/BuildLens/App/BuildConfig.swift`: the set number to
look for, the box photo width, and the AR size.

## Testing the pipeline

```bash
python3 pipeline/ldraw2build.py pipeline/samples/car.mpd --library .ldraw/ldraw --out /tmp/car
```

```bash
node pipeline/render/render.mjs /tmp/car --previews
```

The second command renders `/tmp/car/previews/step-XXX.png` so you can check every step.

The stand-in car comes from the LDraw sample library (CCAL 2.0, see `pipeline/samples/CAreadme.txt`).
Part geometry comes from the [LDraw parts library](https://library.ldraw.org).
