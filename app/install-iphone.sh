#!/usr/bin/env bash
# Builds BuildLens, signs it with your Apple ID's free Personal Team, installs it on the
# iPhone plugged into this Mac and opens it.
#
#   app/install-iphone.sh
#
# Needs, once: your Apple ID added in Xcode (Xcode > Settings > Accounts > +), the iPhone
# plugged in and trusted, and Developer Mode on (Settings > Privacy & Security on the phone).
set -euo pipefail
cd "$(dirname "$0")"

say() { printf '\n%s\n' "$*"; }
fail() { printf '\nNOT DONE: %s\n' "$*" >&2; exit 1; }

# --- the iPhone
devices="$(mktemp)"
trap 'rm -f "$devices"' EXIT
xcrun devicectl list devices --json-output "$devices" >/dev/null 2>&1 || fail "Xcode's device tool did not run. Open Xcode once and try again."
read -r UDID NAME STATE <<<"$(python3 - "$devices" <<'PY'
import json, sys
found = []
for d in json.load(open(sys.argv[1])).get("result", {}).get("devices", []):
    hw, props = d.get("hardwareProperties", {}), d.get("deviceProperties", {})
    if hw.get("reality") == "physical" and hw.get("platform") == "iOS":
        state = d.get("connectionProperties", {}).get("tunnelState", "unknown")
        found.append((hw.get("udid", ""), props.get("name", "iPhone").replace(" ", "_"), state))
# Prefer one that is actually connected right now.
found.sort(key=lambda f: f[2] != "connected")
print(*(found[0] if found else ("", "", "")))
PY
)"
[ -n "${UDID:-}" ] || fail "No iPhone found. Plug it into this Mac with a cable, unlock it and tap Trust."
say "iPhone: ${NAME//_/ } ($STATE)"

# --- the signing team (your Apple ID in Xcode)
TEAM="${DEVELOPMENT_TEAM:-}"
if [ -z "$TEAM" ]; then
  TEAM="$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null | sed -n 's/.*teamID *= *"\{0,1\}\([A-Z0-9]\{10\}\)"\{0,1\};.*/\1/p' | head -1 || true)"
fi
if [ -z "$TEAM" ]; then
  TEAM="$(security find-certificate -a -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1 || true)"
fi
[ -n "$TEAM" ] || fail "No Apple ID in Xcode yet. In Xcode: Settings (Cmd+,) > Accounts > + > Apple Account, sign in, then run this again."
say "Signing team: $TEAM"

# --- build, install, open
BUILD="${TMPDIR:-/tmp}/buildlens-iphone"
LOG="$BUILD/build.log"
mkdir -p "$BUILD"
say "Building (a minute or two the first time)..."
if ! xcodebuild -project BuildLens.xcodeproj -scheme BuildLens -configuration Debug \
      -destination "id=$UDID" -derivedDataPath "$BUILD" \
      -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic build >"$LOG" 2>&1; then
  grep -E "error:" "$LOG" | sort -u | head -8 >&2
  if grep -q "Developer Mode" "$LOG"; then fail "Turn on Developer Mode on the iPhone: Settings > Privacy & Security > Developer Mode."; fi
  if grep -qiE "device is locked|unlock" "$LOG"; then fail "Unlock the iPhone and run this again."; fi
  fail "The build failed. Full log: $LOG"
fi
APP="$BUILD/Build/Products/Debug-iphoneos/BuildLens.app"
say "Installing..."
xcrun devicectl device install app --device "$UDID" "$APP" >>"$LOG" 2>&1 || fail "Could not install. Unlock the iPhone and try again. Log: $LOG"
BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
if xcrun devicectl device process launch --device "$UDID" "$BUNDLE" >>"$LOG" 2>&1; then
  say "BuildLens is open on your iPhone."
else
  say "Installed, but iOS would not open it yet. On the iPhone: Settings > General > VPN & Device Management > your Apple ID > Trust. Then tap the BuildLens icon."
fi
