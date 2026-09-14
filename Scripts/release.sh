#!/bin/bash
# Builds, Developer-ID-signs, notarizes, staples, and packages Snoopy into a DMG.
#
# Prerequisites (one-time):
#   1. A "Developer ID Application" certificate installed in the login keychain.
#   2. An App Store Connect API key (.p8) with the Issuer ID.
#
# Usage:
#   ISSUER_ID=<uuid> ./Scripts/release.sh 0.2.0
#
# Optional env:
#   KEY_ID   (default 4DZTWDQRU6)
#   KEY_FILE (default ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8)
#   TEAM_ID  (default 9B6HPGD2B9)
#   IDENTITY (default: first "Developer ID Application" identity in the keychain)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: release.sh <version> (e.g. 0.2.0 or 0.2.0-rc.1)}"

# CFBundleShortVersionString must be one to three dot-separated numbers — Apple rejects a
# "-rc.1" suffix — so the release channel keeps the full string and the bundle keeps the
# numeric part. CFBundleVersion is the commit count: monotonic, needs no bookkeeping, and
# lets macOS tell two builds of the same version apart.
SHORT_VERSION="$(printf '%s' "$VERSION" | sed -E 's/^v?([0-9]+(\.[0-9]+){0,2}).*$/\1/')"
if ! [[ "$SHORT_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "Cannot derive a numeric version from '$VERSION' (expected e.g. 0.2.0 or 0.2.0-rc.1)"; exit 1
fi
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD)}"
echo "Version: $SHORT_VERSION (build $BUILD_NUMBER), channel $VERSION"
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
  MARKETING_VERSION="$SHORT_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  SNOOPY_RELEASE_CHANNEL="$VERSION" \
  build >/dev/null
[ -d "$APP" ] || { echo "build did not produce $APP"; exit 1; }

# The whole point of the settings above: fail loudly rather than ship a DMG whose name
# disagrees with the version the app reports.
PLIST="$APP/Contents/Info.plist"
BUILT_SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
BUILT_CHANNEL="$(/usr/libexec/PlistBuddy -c 'Print :SnoopyReleaseChannel' "$PLIST")"
if [ "$BUILT_SHORT" != "$SHORT_VERSION" ] || [ "$BUILT_BUILD" != "$BUILD_NUMBER" ] || [ "$BUILT_CHANNEL" != "$VERSION" ]; then
  echo "Version mismatch in the built app:"
  echo "  CFBundleShortVersionString = $BUILT_SHORT (want $SHORT_VERSION)"
  echo "  CFBundleVersion            = $BUILT_BUILD (want $BUILD_NUMBER)"
  echo "  SnoopyReleaseChannel       = $BUILT_CHANNEL (want $VERSION)"
  exit 1
fi
echo "    app reports $BUILT_SHORT ($BUILT_BUILD), channel $BUILT_CHANNEL"

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
