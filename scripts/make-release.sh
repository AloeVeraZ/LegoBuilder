#!/usr/bin/env bash
# Builds the files for a GitHub release into release/ (nothing is uploaded):
#   BuildLens-<version>-macOS.zip       the Mac app, carrying the glasses app
#   BuildLensGlasses-<version>.apk      the glasses app on its own
#   and a .sha256 beside each (install.sh checks the Mac download against it).
#
#   scripts/make-release.sh 1.0.0
#
# Publishing, once the files look right:
#   gh release create v1.0.0 release/* --title "BuildLens 1.0.0" --notes-file release/NOTES.md
set -euo pipefail
version="${1:?usage: scripts/make-release.sh <version, e.g. 1.0.0>}"
cd "$(dirname "$0")/.."
out=release
rm -rf "$out" && mkdir -p "$out"

export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
export PATH="$JAVA_HOME/bin:$PATH"
glasses/build.sh | tail -1

build="${TMPDIR:-/tmp}/buildlens-release"
echo "Building the Mac app..."
xcodebuild -project app/BuildLens.xcodeproj -scheme BuildLens -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$build" \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  MARKETING_VERSION="$version" build >"$build.log" 2>&1 || { grep -E "error:" "$build.log" | sort -u | head; exit 1; }
mac="$build/Build/Products/Release/BuildLens.app"
cp glasses/dist/BuildLensGlasses.apk glasses/dist/BuildLensGlasses.version "$mac/Contents/Resources/"
codesign --force --deep --sign - "$mac"

ditto -c -k --keepParent "$mac" "$out/BuildLens-$version-macOS.zip"
cp glasses/dist/BuildLensGlasses.apk "$out/BuildLensGlasses-$version.apk"
(cd "$out" && for f in *; do shasum -a 256 "$f" > "$f.sha256"; done)

cat > "$out/NOTES.md" <<EOF
BuildLens $version: LEGO building steps on a Mac, an iPhone and MicroLumin M6 glasses.

**Install on a Mac** (Apple Silicon or Intel, macOS 15 or later). In Terminal:

\`\`\`bash
curl -fsSL https://raw.githubusercontent.com/AloeVeraZ/LegoBuilder/main/install.sh | bash
\`\`\`

Or download \`BuildLens-$version-macOS.zip\`, unzip it into Applications, and the first time
right-click BuildLens › Open (it is not from the App Store).

- **Glasses:** plug them into the Mac with BuildLens open: it installs the glasses app on them
  by itself and opens it. (\`BuildLensGlasses-$version.apk\` is the same app, for \`adb install\`.)
- **iPhone:** Apple only allows installing it from Xcode with your own Apple ID: clone the repo
  and run \`./install.sh\` with the iPhone plugged in.
EOF
ls -la "$out"
