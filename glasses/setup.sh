#!/usr/bin/env bash
# Sets up the glasses in one go: installs BuildLens (with the camera allowed), opens it, and
# lines its camera up with your eye. Plug the glasses into this Mac first.
#
#   glasses/setup.sh            install, open, line up (line-up only the first time)
#   glasses/setup.sh lineup     just line up again
#
# Needs adb (brew install android-platform-tools) and Developer Mode on the glasses
# (MLDemo › Glasses › Developer).
set -euo pipefail
cd "$(dirname "$0")"
APK=dist/BuildLensGlasses.apk
APP=com.buildlens.glasses

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

command -v adb >/dev/null || { say "adb is missing. Run: brew install android-platform-tools"; exit 1; }

# The glasses: a plugged-in device that is not an emulator.
serial="${ANDROID_SERIAL:-$(adb devices | awk 'NR > 1 && $2 == "device" && $1 !~ /^emulator-/ { print $1; exit }')}"
if [ -z "$serial" ]; then
    say "No glasses found."
    echo "  1. Plug the glasses into this Mac with their USB cable."
    echo "  2. In MLDemo turn on Developer Mode (Glasses › Developer), then unplug and plug in again."
    echo "  3. If the glasses ask to allow USB debugging, allow it. Then run this again."
    adb devices -l | sed 's/^/     /'
    exit 1
fi
a() { adb -s "$serial" "$@"; }
echo "Glasses: $(a shell getprop ro.product.model | tr -d '\r') ($serial)"

lineup_only=false
[ "${1:-}" = "lineup" ] && lineup_only=true

if ! $lineup_only; then
    say "Installing BuildLens..."
    # -g allows the camera straight away, so nothing has to be tapped on the glasses.
    a install -r -g "$APK" | tail -1
    a shell am start -n $APP/.MainActivity >/dev/null
    echo "Open on the glasses."
fi

# Line up the first time (the glasses remember it), or whenever asked.
if $lineup_only || ! a shell "test -s /sdcard/Android/data/$APP/files/lined-up" 2>/dev/null; then
    say "Line up the camera with your eye (once):"
    echo "  1. On the iPhone: Instructions › ••• › Table marker. Lay the phone flat on the table."
    echo "  2. Put the glasses on and sit as you will when building."
    echo "  3. A circle appears. Look so the code on the phone sits in the circle, and tap once."
    echo "  The code's outline then shows in green over the real one for a few seconds;"
    echo "  swipe to make it bigger or smaller until it matches."
    a logcat -c
    a shell am start -n $APP/.MainActivity --ez lineup true >/dev/null
    echo
    echo "Waiting for the tap (Ctrl-C to stop)..."
    while :; do
        line=$(a logcat -d -s BuildLens | grep -E "line-up: (done|given up|click, but|makes no sense)" | tail -1 || true)
        case "$line" in
            *"line-up: done"*) say "Lined up."; break ;;
            *"line-up: given up"*) say "No clicks for two minutes, so the glasses went back to the steps. Run: glasses/setup.sh lineup"; exit 1 ;;
        esac
        if [ -n "$line" ] && [ "$line" != "${last:-}" ]; then
            case "$line" in
                *"not seen"*) echo "  The camera can't see the code: look more straight at it, or bring it nearer, and click again." ;;
                *"too close"*) echo "  Both clicks saw the code in the same place. Start again from the first circle, moving your head between clicks." ;;
            esac
            last="$line"
        fi
        sleep 1
    done
fi

say "Done. The step's pieces show in green in the middle of your view."
