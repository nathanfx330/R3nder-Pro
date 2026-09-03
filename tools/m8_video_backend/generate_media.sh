#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEDIA_DIR="$SCRIPT_DIR/media"
mkdir -p "$MEDIA_DIR"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg is required to generate the M8 reference media." >&2
  exit 1
fi

WIDTH=1280
HEIGHT=720
FPS=30
SECONDS=20
GOP=120

marker_filter=""
for bit in $(seq 0 9); do
  x=$((8 + bit * 32))
  divisor=$((1 << bit))
  clause="drawbox=x=${x}:y=8:w=24:h=24:color=white:t=fill:enable='eq(mod(floor(n/${divisor}),2),1)'"
  if [[ -n "$marker_filter" ]]; then
    marker_filter+=","
  fi
  marker_filter+="$clause"
done

generate_clip() {
  local background="$1"
  local output="$2"

  ffmpeg \
    -hide_banner \
    -loglevel warning \
    -y \
    -f lavfi \
    -i "color=c=${background}:s=${WIDTH}x${HEIGHT}:r=${FPS}:d=${SECONDS}" \
    -vf "$marker_filter" \
    -an \
    -c:v libx264 \
    -preset medium \
    -crf 18 \
    -pix_fmt yuv420p \
    -g "$GOP" \
    -keyint_min "$GOP" \
    -sc_threshold 0 \
    -bf 3 \
    -movflags +faststart \
    "$output"
}

generate_clip black "$MEDIA_DIR/clip_a.mp4"
generate_clip navy "$MEDIA_DIR/clip_b.mp4"

echo "Generated M8 long-GOP reference media:"
echo "  $MEDIA_DIR/clip_a.mp4"
echo "  $MEDIA_DIR/clip_b.mp4"
echo "  1280x720, 30 fps, 600 frames, GOP 120"
