# Glasses version (MicroLumin / MLVision M6)

The research report suggests the hackathon glasses are the **M6**. If so, they are an
Android-based computer on the glasses (reportedly Android 9 Go on a UNISOC W517) with a
**640×480** waveguide display, a camera, microphones, and touch, ring or voice input. The
SDK is handed out at the event, so everything below that depends on it is a plan, not code.

## What's already done for it

- **Glasses frames.** The pipeline renders a 640×480 green-on-black frame for every step:
  new pieces filled bright, earlier pieces as outlines. That suits a monochrome-green
  waveguide and reads at a glance. They're in `app/BuildLens/Resources/BuildData/hud/`.
  The Mac and iPhone **Glasses preview** shows exactly these, with the step text on top.
- **Step text.** `BuildModel.spokenSummary(for:)` gives one short sentence per step
  ("Step 3 of 40. Add 2 red plate 1 by 2…"), for the glasses' speaker or captions.
- **Step sync message.** The phone and Mac already share the current step as `{"step": N}`.
  The glasses can use the same message.

## Likely architecture

1. **Phone is the brain, glasses are the display (preferred for the demo).** The iPhone app
   keeps doing scanning and AR. On every step change it sends the step number (or the
   frame PNG) to the glasses. How depends on the SDK:
   - If MicroLumin offers a phone-side SDK, call it from `AppModel.go(to:)`.
   - Otherwise add a tiny LAN channel: the phone runs a WebSocket server, advertised over
     Bonjour, and the glasses connect to it.
     MultipeerConnectivity is Apple-only, so it can't be used for the glasses.
2. **Stand-alone glasses app (Android APK).** It bundles the `hud/` frames and the step list,
   and moves through steps with touch, ring or voice ("next" / "back"). It optionally
   follows the phone over the same LAN channel.

## First hour with the hardware

1. Get one static "Hello" screen on the display: install method, screen size, monochrome or colour.
2. Get one input event (touchpad, ring, or a voice keyword).
3. Show `hud-step-001.png` full screen, and change frames on input.
4. Receive `{"step": N}` from the phone and switch frames, so phone and glasses stay in step.

## Questions for the MicroLumin engineer

- Which model is this (M6 Air / Display / Display Pro)? Is the display mono green or full colour?
- Can we `adb install` our own APK, or must apps go through a phone-side SDK?
- How do we draw on the display: a normal Android Activity, or an SDK display API? What resolution and safe area?
- How do touch, ring and voice inputs reach our app (key codes, callbacks)?
- Can a third-party iPhone app talk to the glasses (BLE / Wi-Fi protocol or an iOS SDK)?
- Can our app use the camera (Camera2 or SDK only)? This would be for a later "which step am I on" feature.
