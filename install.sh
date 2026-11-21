#!/usr/bin/env bash
# BuildLens on this Mac, and from it on the iPhone and the glasses.
#
# From a copy of the repo (needs Xcode; the iPhone also needs your Apple ID in Xcode):
#   ./install.sh
# Without the repo (the Mac app only, from the latest GitHub release):
#   curl -fsSL https://raw.githubusercontent.com/AloeVeraZ/LegoBuilder/main/install.sh | bash
#
# The Mac app carries the glasses app and puts it on any glasses plugged into this Mac, so
# plugging the glasses in is all they need. The iPhone app has to be built and signed here
# with Xcode (Apple does not allow installing a ready-made app on someone else's iPhone).
set -euo pipefail
repo="AloeVeraZ/LegoBuilder"
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\nNOT DONE: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "BuildLens installs from a Mac."

# adb, for the glasses (Homebrew's android-platform-tools).
need_adb() {
  command -v adb >/dev/null && return
  for p in /opt/homebrew/bin/adb /usr/local/bin/adb; do [ -x "$p" ] && return; done
  if command -v brew >/dev/null; then
    say "Installing adb (for the glasses)..."
    brew install --quiet android-platform-tools
  else
    echo "For the glasses: install Homebrew (https://brew.sh), then run: brew install android-platform-tools"
  fi
}

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -n "$here" ] && [ -f "$here/app/install-mac.sh" ]; then
  # ---------------------------------------------------------------- from the repo
  cd "$here"
  command -v xcodebuild >/dev/null || fail "Install Xcode from the App Store, open it once, then run this again."
  need_adb
  # A newer glasses app if the tools to build one are here; otherwise the one in the repo.
  sdk="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
  if [ -d "$sdk/build-tools/35.0.0" ] && command -v python3 >/dev/null && python3 -c 'import numpy' 2>/dev/null; then
    say "Building the glasses app..."
    JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}" ANDROID_HOME="$sdk" \
      PATH="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}/bin:$PATH" glasses/build.sh | tail -1
  fi

  say "Mac: building and installing BuildLens..."
  app/install-mac.sh

  # The iPhone, if one is plugged in.
  devices="$(mktemp)"
  if xcrun devicectl list devices --json-output "$devices" >/dev/null 2>&1 &&
     python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["result"]["devices"]; sys.exit(0 if any(x.get("hardwareProperties",{}).get("reality")=="physical" and x["hardwareProperties"].get("platform")=="iOS" for x in d) else 1)' "$devices"; then
    say "iPhone: building and installing BuildLens..."
    app/install-iphone.sh || echo "The iPhone was skipped (see above). Run app/install-iphone.sh once it is sorted."
  else
    echo "No iPhone plugged in: plug it in and run app/install-iphone.sh later."
  fi
  rm -f "$devices"
else
  # ---------------------------------------------------------------- from the release
  say "Finding the latest BuildLens release..."
  tag="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest" | sed -n 's#.*/releases/tag/##p')"
  [ -n "$tag" ] || fail "No release found on github.com/$repo."
  version="${tag#v}"
  file="BuildLens-$version-macOS.zip"
  stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
  curl -fL --progress-bar -o "$stage/$file" "https://github.com/$repo/releases/download/$tag/$file"
  curl -fsSL -o "$stage/$file.sha256" "https://github.com/$repo/releases/download/$tag/$file.sha256"
  (cd "$stage" && shasum -a 256 -c "$file.sha256" >/dev/null) || fail "The download did not check out. Nothing was installed."
  need_adb
  osascript -e 'tell application "BuildLens" to quit' >/dev/null 2>&1 || true
  rm -rf /Applications/BuildLens.app
  ditto -x -k "$stage/$file" /Applications
  ln -sfn /Applications/BuildLens.app "$HOME/Desktop/BuildLens"
  echo "Installed BuildLens $version in /Applications."
  echo "For the iPhone app: clone github.com/$repo and run ./install.sh there (needs Xcode)."
fi

open /Applications/BuildLens.app
say "Done. Plug the glasses into this Mac: BuildLens goes on them by itself and opens."
