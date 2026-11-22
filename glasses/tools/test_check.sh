#!/usr/bin/env bash
# Tests the set-down check (PieceCheck, SetDown) on made-up camera pictures, on this computer.
# Needs a JDK, Node with the renderer's packages (cd pipeline/render && npm install) and Python 3.
#   glasses/tools/test_check.sh               # 92 pictures, the build put down about the way the ghost shows it
#   glasses/tools/test_check.sh --any-turn    # put down any way at all (harder)
#   glasses/tools/test_check.sh --count 230 --seed 5 --draw    # more, and save pictures of the mistakes
#   glasses/tools/test_check.sh --true-pose   # skip the marker finder (the check alone)
# If Playwright asks for a browser download, set BL_CHROMIUM to a chrome-headless-shell you have.
set -euo pipefail
cd "$(dirname "$0")/.."
java -version >/dev/null 2>&1 || export PATH="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}/bin:$PATH"
count=92; seed=2; spread=30; extra=(--turn-range 45)
while [ $# -gt 0 ]; do
  case "$1" in
    --count) count=$2; shift ;;
    --seed) seed=$2; shift ;;
    --any-turn) spread=180; extra=() ;;
    --draw) extra+=(--draw build/check-test/mistakes) ;;
    --true-pose) extra+=(--true-pose) ;;
  esac
  shift
done
out=build/check-test
scenes=$out/scenes-$count-$seed-spread$spread
[ -f assets/check.bin ] || python3 make_assets.py
if [ ! -f "$scenes/scenes.txt" ]; then
  node ../pipeline/render/scenes.mjs ../app/BuildLens/Resources/BuildData "$scenes" --count "$count" --seed "$seed" --spread "$spread"
fi
rm -rf "$out/classes" && mkdir -p "$out/classes"
src=src/com/buildlens/glasses
plain="$src/QrFinder.java $src/Homography.java $src/MarkerPose.java $src/MarkerRefine.java $src/CheckModel.java $src/Frame.java $src/PieceCheck.java $src/SetDown.java"
# The glasses build with Java 8: check these compile for it too.
javac --release 8 -Xlint:-options -d "$out/classes" $plain
javac -d "$out/classes" $plain tools/CheckTest.java tools/SetDownTest.java
java -cp "$out/classes" CheckTest "$scenes" assets/check.bin ${extra[@]+"${extra[@]}"}
echo
java -cp "$out/classes" SetDownTest "$scenes" assets/check.bin | grep -E "^scene|ok$|WRONG|^SetDown"
