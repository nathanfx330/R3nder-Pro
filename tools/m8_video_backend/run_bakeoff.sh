#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$SCRIPT_DIR/generate_media.sh"
bash "$SCRIPT_DIR/build.sh"

"$SCRIPT_DIR/m8_bakeoff" \
  "$SCRIPT_DIR/media/clip_a.mp4" \
  "$SCRIPT_DIR/media/clip_b.mp4" \
  "$SCRIPT_DIR/m8_results.csv"
