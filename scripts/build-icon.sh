#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
SOURCE_PATH="$PROJECT_DIR/app-resources/app-icon-1024.png"
OUTPUT_PATH="$PROJECT_DIR/app-resources/app-icon.icns"
ICON_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/port-watch-icon.XXXXXX")"
ICONSET_DIR="$ICON_WORK_DIR/app-icon.iconset"

trap 'rm -rf "$ICON_WORK_DIR"' EXIT

if [[ ! -f "$SOURCE_PATH" ]]; then
    echo "アイコン画像が見つかりません: $SOURCE_PATH" >&2
    exit 1
fi

mkdir -p "$ICONSET_DIR"

sips -z 16 16 "$SOURCE_PATH" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$SOURCE_PATH" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$SOURCE_PATH" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$SOURCE_PATH" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$SOURCE_PATH" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$SOURCE_PATH" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$SOURCE_PATH" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$SOURCE_PATH" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$SOURCE_PATH" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
install -m 644 "$SOURCE_PATH" "$ICONSET_DIR/icon_512x512@2x.png"

iconutil --convert icns \
    --output "$ICON_WORK_DIR/app-icon.icns" \
    "$ICONSET_DIR"
install -m 644 "$ICON_WORK_DIR/app-icon.icns" "$OUTPUT_PATH"

echo "$OUTPUT_PATH"
