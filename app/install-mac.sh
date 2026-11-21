#!/usr/bin/env bash
# Builds the Mac version of BuildLens, puts it in /Applications and adds a shortcut on the
# Desktop. Run it again after changing the app to update the installed copy.
#
#   app/install-mac.sh
set -euo pipefail
cd "$(dirname "$0")"

BUILD="${TMPDIR:-/tmp}/buildlens-mac"
LOG="$BUILD/build.log"
mkdir -p "$BUILD"
echo "Building the Mac app..."
# Signed for this Mac only ("-"): no Apple ID needed, and it opens without warnings here.
if ! xcodebuild -project BuildLens.xcodeproj -scheme BuildLens -configuration Release \
      -destination 'platform=macOS' -derivedDataPath "$BUILD" \
      CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" build >"$LOG" 2>&1; then
  grep -E "error:" "$LOG" | sort -u | head -8 >&2
  echo "NOT DONE: the build failed. Full log: $LOG" >&2
  exit 1
fi

APP="/Applications/BuildLens.app"
osascript -e 'tell application "BuildLens" to quit' >/dev/null 2>&1 || true
rm -rf "$APP"
ditto "$BUILD/Build/Products/Release/BuildLens.app" "$APP"
ln -sfn "$APP" "$HOME/Desktop/BuildLens"
echo "Installed $APP, with a shortcut on the Desktop."
