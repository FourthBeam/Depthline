#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Depthline.app"
if [[ ! -x "$APP/Contents/MacOS/Depthline" ]]; then
  bash "$ROOT/native/build.sh"
fi
open "$APP"
