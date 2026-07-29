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
cp Resources/dB.sdef "$APP/Contents/Resources/dB.sdef"

ENTITLEMENTS="Resources/dB.entitlements"

# Prefer a real Developer ID Application cert for release builds: that's what
# notarization requires and what lets the app open without the Gatekeeper
# right-click dance. Falls back to ad-hoc signing for debug builds, or anywhere
# no Developer ID cert is installed (CI without signing secrets, contributors
# without a paid account). Ad-hoc signing is enough for the audio-recording
# permission to stick locally; it just can't be notarized.
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')"

if [ "$CONFIG" = "release" ] && [ -n "$IDENTITY" ]; then
  echo "Signing with: $IDENTITY"
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" "$APP"
else
  echo "Ad-hoc signing (no Developer ID identity; not notarizable)."
  codesign --force --sign - "$APP"
fi

echo "Built $APP"
echo "Run with: open $APP"
