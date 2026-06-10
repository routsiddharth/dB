#!/bin/bash
# Builds dB.app into ./dist
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"

swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/dB"
APP="dist/dB.app"

rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/dB"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc sign; required for the system audio recording permission to stick.
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Run with: open $APP"
