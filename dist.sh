#!/bin/bash
# Builds a signed, notarized, stapled DMG you can hand to anyone.
#
# Prereqs (one-time, see CLAUDE.md "Distributing"):
#   - A "Developer ID Application" certificate in your login keychain.
#   - Notarization credentials saved as the keychain profile named below
#     (xcrun notarytool store-credentials "dB-notary" ...).
#
# Usage: ./dist.sh
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="dB-notary"   # notarytool keychain profile (see store-credentials)
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
APP="dist/dB.app"
ZIP="dist/dB-${VERSION}.zip"
DMG="dist/dB-${VERSION}.dmg"

# 1. Build + Developer ID sign (build.sh picks the cert up automatically).
./build.sh release

# Bail out early if build.sh fell back to ad-hoc signing — notarization needs
# a real Developer ID signature. Capture codesign's output first, then grep the
# string: piping straight into `grep -q` lets grep close the pipe on match,
# which kills codesign with SIGPIPE and (under pipefail) fakes a failure.
SIGN_INFO="$(codesign -dvv "$APP" 2>&1)"
if ! grep -q "Authority=Developer ID Application" <<<"$SIGN_INFO"; then
  echo "ERROR: $APP is not Developer ID signed. Is your cert installed?" >&2
  echo "       security find-identity -v -p codesigning" >&2
  exit 1
fi

# 2. Notarize. Apple wants a zip (or dmg/pkg); we zip the app, wait for the
#    verdict, then staple the ticket onto the app itself so it launches even
#    offline / before the DMG is opened.
echo "==> Zipping for notarization"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple (a few minutes; --wait blocks until done)"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Stapling ticket to the app"
xcrun stapler staple "$APP"
rm -f "$ZIP"

# 3. Package the stapled app into a drag-to-Applications DMG. Plain hdiutil so
#    there are no extra tooling deps.
echo "==> Building DMG"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "dB" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

# 4. Sign + notarize + staple the DMG itself, in that order. The disk image
#    needs its own Developer ID signature and notarization ticket so the
#    *download* is trusted (not just the app inside). Order matters: codesign
#    first, then notarize the signed bits, then staple.
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
echo "==> Code-signing the DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
echo "==> Notarizing the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
echo "==> Stapling the DMG"
xcrun stapler staple "$DMG"

# 5. Final sanity check: Gatekeeper should accept the DMG outright.
echo "==> Verifying"
spctl --assess --type open --context context:primary-signature -v "$DMG" || true
xcrun stapler validate "$DMG"

echo ""
echo "Done: $DMG"
echo "Share that file. Recipients drag dB to Applications and just open it."
