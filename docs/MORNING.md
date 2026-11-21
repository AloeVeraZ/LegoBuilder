# Morning checklist (hackathon day)

Everything below is in order. Steps 1 and 2 need you; for the rest you can also just tell
Claude "do the next step" and it will run the commands.

## 1. Put BuildLens on your iPhone (about 5 minutes)

1. Open **Xcode**. Menu bar: **Xcode › Settings…** (⌘,) › **Accounts** tab › **+** at the
   bottom left › **Apple Account** › sign in with your Apple ID.
2. Plug the iPhone into this Mac with a cable. On the phone tap **Trust** and enter your passcode.
3. On the iPhone: **Settings › Privacy & Security › Developer Mode** › turn it on. The phone
   restarts; after it comes back, confirm **Turn On**.
4. In Xcode: **File › Open…** and choose `app/BuildLens.xcodeproj` in this folder.
5. In the left sidebar click the blue **BuildLens** at the very top, then **BuildLens** under
   TARGETS, then the **Signing & Capabilities** tab. Set **Team** to your name
   (it says "Personal Team").
6. At the top of the window, click the device name next to "BuildLens" and pick your iPhone.
7. Press **▶** (top left). The first build takes a minute or two.
8. If the phone says the developer is not trusted: **Settings › General › VPN & Device
   Management** › your Apple ID › **Trust**. Then press ▶ again.
9. When BuildLens asks to **find devices on your local network**, tap **Allow**. Without
   this the phone cannot find the glasses. (If you tapped Don't Allow: Settings › BuildLens ›
   Local Network.)

Or, after step 3, run `app/install-iphone.sh` (or tell Claude "install BuildLens on my
iPhone"): it finds the phone, signs the app with your Apple ID, installs it and opens it,
and tells you exactly what is missing if it can't.

## The Mac app, for showing the judges

BuildLens is also installed on this Mac: open **BuildLens** from the Desktop shortcut,
Launchpad or Spotlight. The big **Open** tile starts the instructions; **Glasses preview**
opens a separate window that shows what the glasses show and follows the step you are on.
The Mac links to glasses plugged into it by USB and to the phone (Wi-Fi or its cable), and
passes steps, settings and the view between them, so no Wi-Fi is needed. After changing the app, `app/install-mac.sh` updates
the installed copy.

## 2. Put BuildLens on the glasses (about 5 minutes)

1. In **MLDemo** on the iPhone: connect the glasses, open the **Wi-Fi** screen and join them
   to the **same Wi-Fi as the iPhone**, then **Glasses screen › Developer › Developer Mode** on.
2. Plug the glasses into this Mac with their USB cable and run:

   ```bash
   glasses/setup.sh
   ```

   It installs the app (camera allowed), opens it, and then walks you through lining up
   the camera with your eye: on the iPhone open **Instructions › ••• › Table marker** and lay
   the phone flat, put the glasses on, look so the code sits in the green circle and click;
   then the same for a second circle. You should then see "STEP 1/23" in green.

   If it says no glasses were found, it tells you what to check.

## 3. Teach it the glasses' buttons (about 2 minutes)

Nobody has published which signals the M6's side button, touchpad and ring send, so the app
guesses from similar glasses and logs everything. Run this, then press each control once
(tap, double tap, swipe forward, swipe back, side button, ring):

```bash
adb logcat -s BuildLens
```

- If one click already goes to the next step, two clicks replay it and three go back: done.
- If a control does nothing, paste the lines it printed to Claude and say which control it
  was. It is a one-line change in `KEYS` at the bottom of
  `glasses/src/com/buildlens/glasses/MainActivity.java`, then rebuild and reinstall
  (`glasses/build.sh`, then `glasses/setup.sh`).

## 4. Check the two together

1. On the iPhone open BuildLens. The big tile should read **Phone + glasses · Open**.
   Tap it: the glasses should show the same step without you touching them.
2. Press **Next** on the phone: the glasses follow. Click on the glasses: the phone follows.
3. Close the app on the phone: the glasses keep showing their step, and their buttons
   still work. Open the instructions on the phone again and it picks up where the glasses are.

If the tile only says **Instructions · Open**, the phone has not found the glasses:

- Both must be on the **same Wi-Fi**. Venue Wi-Fi often blocks devices from seeing each
  other. The reliable fix is to turn on **Personal Hotspot** on the iPhone and join the
  glasses to it in MLDemo.
- Make sure Local Network is allowed for BuildLens (step 1.9).
- Make sure the glasses app was opened once (`glasses/setup.sh` does that).

## 5. The ghost (green piece on the real build)

1. On the iPhone: **Instructions › ••• › Table marker**, and lay the phone flat on the table.
2. Wearing the glasses, look at the phone from where you sit. The step picture gives way to
   a dashed green ring on the table right of the phone, with the step's new piece going in
   where it belongs. Build on that ring.
3. Click on the glasses to move on as usual. Look away from the phone and the step pictures
   come back.

If the ring sits beside where it should be, run `glasses/setup.sh lineup` and line up again
at the distance you build at. If nothing shows, `adb logcat -s BuildLens` says whether the
camera opened and how often it sees the marker.

## 6. If something fails during the demo

- **Glasses link down:** the phone app works fully on its own. In the build screen, the
  **•••** menu has **Glasses preview**, which shows exactly what the glasses would show.
- **No glasses at all:** `python3 glasses/tools/fake_glasses.py` on this Mac stands in for
  them (type `n`, `r`, `b` + Enter for one, two, three clicks) to show the two-way sync.
  Do not leave it running when the real glasses are around: the phone links to whichever
  it finds first.
- **No iPhone:** use the Mac app (above). `web/dist/BuildLens.html` opens in any browser
  (older animation, no glasses link).

## What is and is not verified

Verified on this Mac:

- The phone app in the iPhone simulator: all the animation, the sub-build moments, finish,
  exit, and two-way sync with a stand-in for the glasses.
- The glasses app on an Android 9 emulator at 640×480: it starts by itself after a restart,
  opens its screen when the phone opens the instructions, and one / two / three clicks work.
- Every pin and axle in the model passes through the holes it should
  (`python3 pipeline/models/check_42233_3.py`).

Not verified, because it needs the real hardware:

- The app on a real iPhone (camera scanning and AR have never run anywhere).
- Anything on the real glasses: how it looks through the waveguide, which signals the
  buttons send, whether the glasses' own software lets an app start at switch-on or keeps
  the display awake.
- The phone finding the glasses over the venue's Wi-Fi.
- The ghost on the glasses: whether their camera can be used by an app at all, how sharp
  it is, and how well the line-up holds. Its parts are checked on this Mac (the marker
  finder on made-up camera pictures: within about 1 mm where the build stands) and on the
  emulator (camera opening, ghost drawing, line-up flow), never on the real glasses.

## Submitting

The code is at https://github.com/AloeVeraZ/LegoBuilder on the branch `main`.
The MicroLumin kit is confidential: nothing from it is in the repo, and it should stay that way.
