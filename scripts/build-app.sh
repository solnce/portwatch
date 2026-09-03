#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
CONFIGURATION="${1:-release}"
APP_DIR="$PROJECT_DIR/dist/Port Watch.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

if [[ "$APP_DIR" != "$PROJECT_DIR/dist/Port Watch.app" ]]; then
    echo "アプリ出力先が不正です" >&2
    exit 1
fi

cd "$PROJECT_DIR"
BUILD_ARGUMENTS=(
    --disable-sandbox
    --configuration "$CONFIGURATION"
    --arch arm64
    --arch x86_64
)
swift build "${BUILD_ARGUMENTS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGUMENTS[@]}" --show-bin-path)"
EXECUTABLE_PATH="$BIN_DIR/local-port-monitor"
/usr/bin/lipo "$EXECUTABLE_PATH" -verify_arch arm64 x86_64

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
install -m 755 "$EXECUTABLE_PATH" "$MACOS_DIR/local-port-monitor"
install -m 644 "$PROJECT_DIR/app-resources/info.plist" "$CONTENTS_DIR/Info.plist"

plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "$APP_DIR"
