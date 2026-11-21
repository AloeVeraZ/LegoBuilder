#!/usr/bin/env bash
# Builds dist/BuildLensGlasses.apk without Gradle (plain javac + d8 + aapt2 + apksigner).
# Needs a JDK and the Android SDK (platforms;android-34, build-tools;35.0.0): set ANDROID_HOME.
set -euo pipefail
cd "$(dirname "$0")"
SDK="${ANDROID_HOME:?set ANDROID_HOME to your Android SDK}"
BT="$SDK/build-tools/35.0.0"
JAR="$SDK/platforms/android-34/android.jar"
rm -rf build && mkdir -p build/classes build/dex dist
python3 make_assets.py
"$BT/aapt2" compile --dir res -o build/res.zip
# The version goes up with every commit, so the Mac app knows when the glasses need updating.
VERSION_CODE=$(git rev-list --count HEAD 2>/dev/null || echo 1)
VERSION_NAME="1.$VERSION_CODE ($(git rev-parse --short HEAD 2>/dev/null || echo local))"
"$BT/aapt2" link -I "$JAR" --manifest AndroidManifest.xml -A assets -o build/unsigned.apk build/res.zip \
    --version-code "$VERSION_CODE" --version-name "$VERSION_NAME" --replace-version
# Stop on a compile error (the noise about Java 8 and deprecations is left out).
# ZXing (libs/, Apache 2.0) reads the barcode on the set's box.
LIBS=libs/core-3.5.3.jar
if ! javac --release 8 -classpath "$JAR:$LIBS" -d build/classes $(find src -name '*.java') > build/javac.log 2>&1; then
    grep -v "bootstrap classpath\|^warning\|^1 warning\|obsolete\|suppress" build/javac.log; echo "Build failed."; exit 1
fi
(cd build/classes && jar cf ../classes.jar .)
cp "$LIBS" build/libs.jar
"$BT/d8" --min-api 24 --lib "$JAR" --output build/dex build/classes.jar build/libs.jar
cp build/unsigned.apk build/with-dex.apk
(cd build/dex && zip -q ../with-dex.apk classes.dex)
"$BT/zipalign" -f 4 build/with-dex.apk build/aligned.apk
[ -f debug.keystore ] || keytool -genkeypair -keystore debug.keystore -storepass android -keypass android -alias debug \
    -dname "CN=BuildLens Debug" -keyalg RSA -keysize 2048 -validity 10000 >/dev/null 2>&1
"$BT/apksigner" sign --ks debug.keystore --ks-pass pass:android --key-pass pass:android --out dist/BuildLensGlasses.apk build/aligned.apk
echo "$VERSION_CODE" > dist/BuildLensGlasses.version
echo "Built $(pwd)/dist/BuildLensGlasses.apk (version $VERSION_NAME)"
