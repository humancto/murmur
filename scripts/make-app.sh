#!/usr/bin/env bash
#
# Build Murmur.app from the SPM executable + Resources/Info.plist.
#
# `swift run Murmur` is NOT supported for end-to-end testing — without an
# .app bundle there's no Info.plist, which means:
#   - NSMicrophoneUsageDescription is missing → mic request crashes
#   - LSUIElement is missing → Dock icon flashes
#   - TCC keys consent off the bundle ID → AX trust is per-binary-hash
#
# Run this script, then `open ./build/Murmur.app`.

set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="Murmur"
BUILD_DIR="./build"
APP_DIR="$BUILD_DIR/Murmur.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> Building release binary"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
    swift build -c release --product "$SCHEME"

BIN_PATH="$(swift build -c release --show-bin-path)/$SCHEME"
if [ ! -x "$BIN_PATH" ]; then
    echo "ERROR: built binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling app bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BIN_PATH" "$MACOS/$SCHEME"
cp ./Resources/Info.plist "$CONTENTS/Info.plist"
printf "APPL????" > "$CONTENTS/PkgInfo"

# Ad-hoc sign so Gatekeeper doesn't outright refuse to launch on first run.
# (For real distribution, use Developer ID + notarytool.)
codesign --force --sign - --deep "$APP_DIR" 2>/dev/null || true

echo
echo "==> Built: $APP_DIR"
echo "==> Launch with: open $APP_DIR"
