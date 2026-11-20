#!/usr/bin/env bash
# Download the official LDraw parts library (~150 MB zip, ~620 MB unpacked) into .ldraw/
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/.ldraw"
cd "$ROOT/.ldraw"
curl -L --fail -o complete.zip https://library.ldraw.org/library/updates/complete.zip
unzip -q -o complete.zip
rm complete.zip
echo "LDraw library ready in $ROOT/.ldraw/ldraw"
