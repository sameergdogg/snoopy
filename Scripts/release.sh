#!/bin/bash
# Builds, Developer-ID-signs, notarizes, staples, and packages Snoopy into a DMG.
#
# Prerequisites (one-time):
#   1. A "Developer ID Application" certificate installed in the login keychain.
#   2. An App Store Connect API key (.p8) with the Issuer ID.
#
# Usage:
#   ISSUER_ID=<uuid> ./Scripts/release.sh 0.1.0-rc.1
#
# Optional env:
#   KEY_ID   (default 4DZTWDQRU6)
#   KEY_FILE (default ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8)
#   TEAM_ID  (default 9B6HPGD2B9)
#   IDENTITY (default: first "Developer ID Application" identity in the keychain)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: release.sh <version> (e.g. 0.1.0-rc.1)}"
TEAM_ID="${TEAM_ID:-9B6HPGD2B9}"
KEY_ID="${KEY_ID:-4DZTWDQRU6}"
KEY_FILE="${KEY_FILE:-$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8}"
: "${ISSUER_ID:?set ISSUER_ID to your App Store Connect issuer UUID}"

IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
[ -n "$IDENTITY" ] || { echo "No 'Developer ID Application' identity found. Create the cert first."; exit 1; }
echo "Signing identity: $IDENTITY"

DIST="$ROOT/dist"; rm -rf "$DIST"; mkdir -p "$DIST"
APPNAME="Snoopy"
APP="$DIST/$APPNAME.app"

echo "==> Building Release"
cd "$ROOT"
xcodegen generate >/dev/null
xcodebuild -project Snoopy.xcodeproj -scheme Snoopy -configuration Release \
  CONFIGURATION_BUILD_DIR="$DIST" \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_IDENTITY="$IDENTITY" ENABLE_HARDENED_RUNTIME=YES \
  clean build >/dev/null
[ -d "$APP" ] || { echo "build did not produce $APP"; exit 1; }

echo "==> Signing (inside-out) with hardened runtime + secure timestamp"
# Sign every embedded Mach-O first (the injected hook dylib), then the app.
find "$APP/Contents" -type f \( -name "*.dylib" -o -name "*.framework" \) -print0 2>/dev/null | while IFS= read -r -d '' f; do
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$f"
done
codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Notarizing"
ZIP="$DIST/$APPNAME-notarize.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" \
  --key "$KEY_FILE" --key-id "$KEY_ID" --issuer "$ISSUER_ID" \
  --wait
echo "==> Stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vvv --type execute "$APP" || true

echo "==> Building DMG"
DMG="$DIST/$APPNAME-$VERSION.dmg"
STAGE="$(mktemp -d)"; cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APPNAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
# Notarize + staple the DMG too, so the download itself passes Gatekeeper.
xcrun notarytool submit "$DMG" --key "$KEY_FILE" --key-id "$KEY_ID" --issuer "$ISSUER_ID" --wait
xcrun stapler staple "$DMG"

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "==> Done: $DMG"
