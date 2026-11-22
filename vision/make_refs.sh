#!/bin/bash
# Renders the step finder's reference pictures into vision/refs: for every step, the build
# before and after it, from the four sides the app uses, at two camera heights.
# Needs the renderer's packages (cd pipeline/render && npm install). If Playwright asks for
# a browser download, set BL_CHROMIUM to a chrome-headless-shell you already have.
set -euo pipefail
cd "$(dirname "$0")/.."
node pipeline/render/render.mjs app/BuildLens/Resources/BuildData --refs vision/refs --elevs 35,55 "$@"
