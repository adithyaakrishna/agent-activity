#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MASTER_ICON="$ROOT_DIR/Assets/AgentActivityAppIcon.png"
OUTPUT_ICON="$ROOT_DIR/Assets/AgentActivity.icns"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/AgentActivity.icon.XXXXXX")"
ICONSET_DIR="$WORK_DIR/AgentActivity.iconset"
VALIDATION_DIR="$WORK_DIR/validated.iconset"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command not found: $1" >&2
    exit 1
  }
}

require_command sips
require_command iconutil

if [[ ! -f "$MASTER_ICON" ]]; then
  echo "Missing icon master: $MASTER_ICON" >&2
  exit 1
fi

master_width="$(sips -g pixelWidth "$MASTER_ICON" | awk '/pixelWidth/ { print $2 }')"
master_height="$(sips -g pixelHeight "$MASTER_ICON" | awk '/pixelHeight/ { print $2 }')"
master_alpha="$(sips -g hasAlpha "$MASTER_ICON" | awk '/hasAlpha/ { print $2 }')"

if [[ "$master_width" != "1024" || "$master_height" != "1024" ]]; then
  echo "Icon master must be exactly 1024x1024; found ${master_width}x${master_height}." >&2
  exit 1
fi

if [[ "$master_alpha" != "yes" ]]; then
  echo "Icon master must include an alpha channel." >&2
  exit 1
fi

mkdir -p "$ICONSET_DIR"

render_icon() {
  local size="$1"
  local filename="$2"
  sips --resampleHeightWidth "$size" "$size" "$MASTER_ICON" --out "$ICONSET_DIR/$filename" >/dev/null
}

render_icon 16 icon_16x16.png
render_icon 32 icon_16x16@2x.png
render_icon 32 icon_32x32.png
render_icon 64 icon_32x32@2x.png
render_icon 128 icon_128x128.png
render_icon 256 icon_128x128@2x.png
render_icon 256 icon_256x256.png
render_icon 512 icon_256x256@2x.png
render_icon 512 icon_512x512.png
render_icon 1024 icon_512x512@2x.png

rm -f "$OUTPUT_ICON"
iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_ICON"
iconutil -c iconset "$OUTPUT_ICON" -o "$VALIDATION_DIR"

[[ -f "$OUTPUT_ICON" ]] || {
  echo "iconutil did not create $OUTPUT_ICON" >&2
  exit 1
}

for filename in \
  icon_16x16.png \
  icon_16x16@2x.png \
  icon_32x32.png \
  icon_32x32@2x.png \
  icon_128x128.png \
  icon_128x128@2x.png \
  icon_256x256.png \
  icon_256x256@2x.png \
  icon_512x512.png \
  icon_512x512@2x.png; do
  [[ -f "$VALIDATION_DIR/$filename" ]] || {
    echo "Validated iconset is missing $filename" >&2
    exit 1
  }
done

echo "Generated and validated $OUTPUT_ICON"
