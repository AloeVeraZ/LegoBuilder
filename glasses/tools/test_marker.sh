#!/usr/bin/env bash
# Tests the glasses' marker finder on made-up camera pictures, on this computer. Needs a JDK.
set -euo pipefail
cd "$(dirname "$0")/.."
java -version >/dev/null 2>&1 || export PATH="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}/bin:$PATH"
out=build/marker-test
rm -rf "$out" && mkdir -p "$out"
src=src/com/buildlens/glasses
javac -d "$out" $src/QrFinder.java $src/Homography.java $src/MarkerPose.java $src/MarkerRefine.java tools/MarkerTest.java
java -cp "$out" MarkerTest
