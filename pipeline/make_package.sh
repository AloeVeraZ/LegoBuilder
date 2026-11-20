#!/usr/bin/env bash
# Convert a model and install it into the app.
#
#   pipeline/make_package.sh MODEL_FILE [--set-id 77243-1] [--set-name "..."] [--theme "..."]
#
# MODEL_FILE: .ldr / .mpd / BrickLink Studio .io
# Needs: python3 + numpy, node (renders thumbnails with headless Chromium via Playwright).
# Parts library: $LDRAW_LIBRARY, or .ldraw/ldraw (run pipeline/fetch_ldraw.sh once).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MODEL="$1"; shift
LIB="${LDRAW_LIBRARY:-$ROOT/.ldraw/ldraw}"
OUT="$ROOT/app/BuildLens/Resources/BuildData"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 "$HERE/ldraw2build.py" "$MODEL" --library "$LIB" --out "$TMP" "$@"
if [ ! -d "$HERE/render/node_modules" ]; then (cd "$HERE/render" && npm install --no-audit --no-fund); fi
node "$HERE/render/render.mjs" "$TMP" --thumbs --hud --hero

rm -rf "$OUT"
mkdir -p "$OUT/thumbs" "$OUT/hud"
cp "$TMP/build.json" "$TMP/geometry.bin" "$OUT/"
cp "$TMP/hero.png" "$OUT/build-hero.png"
for f in "$TMP"/thumbs/*.png; do cp "$f" "$OUT/thumbs/thumb-$(basename "$f")"; done
for f in "$TMP"/hud/*.png; do cp "$f" "$OUT/hud/hud-$(basename "$f")"; done
echo "Installed into $OUT ($(ls "$OUT/thumbs" | wc -l | tr -d ' ') thumbnails, $(ls "$OUT/hud" | wc -l | tr -d ' ') glasses frames)"
