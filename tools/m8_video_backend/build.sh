#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SCRIPT_DIR/m8_bakeoff"

for tool in g++ pkg-config; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is required to build the M8 bakeoff." >&2
    exit 1
  fi
done

MLT_PKG=""
for candidate in mlt-framework-7 mlt-framework; do
  if pkg-config --exists "$candidate"; then
    MLT_PKG="$candidate"
    break
  fi
done

if [[ -z "$MLT_PKG" ]]; then
  cat >&2 <<'EOF'
Could not find the MLT development package through pkg-config.
On Ubuntu/Debian this is normally provided by libmlt-dev.
EOF
  exit 1
fi

FFMPEG_PKGS=(libavformat libavcodec libavutil)
for pkg in "${FFMPEG_PKGS[@]}"; do
  if ! pkg-config --exists "$pkg"; then
    echo "Could not find $pkg through pkg-config. Install the FFmpeg development packages." >&2
    exit 1
  fi
done

read -r -a CFLAGS <<< "$(pkg-config --cflags "$MLT_PKG" "${FFMPEG_PKGS[@]}")"
read -r -a LIBS <<< "$(pkg-config --libs "$MLT_PKG" "${FFMPEG_PKGS[@]}")"

g++ \
  -std=c++17 \
  -O2 \
  -Wall \
  -Wextra \
  -pedantic \
  "${CFLAGS[@]}" \
  "$SCRIPT_DIR/bakeoff.cc" \
  -o "$OUT" \
  "${LIBS[@]}"

echo "Built $OUT"
echo "MLT pkg-config module: $MLT_PKG"
