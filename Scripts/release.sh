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
GH_OWNER="${GH_OWNER:-sameergdogg}"
GH_REPO="${GH_REPO:-snoopy}"
KEY_ID="${KEY_ID:-4DZTWDQRU6}"
KEY_FILE="${KEY_FILE:-$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8}"
: "${ISSUER_ID:=${SKIP_NOTARIZE:+unused}}"
[ -n "${ISSUER_ID:-}" ] || { echo "set ISSUER_ID to your App Store Connect issuer UUID"; exit 1; }

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
sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }

# Order matters: a containing bundle's signature covers its contents, so anything nested
# must be signed before the thing that contains it. Sparkle makes this real — its framework
# ships a nested Updater.app and a standalone Autoupdate helper, and signing only the
# framework leaves them unsigned, which fails notarization and then fails to launch.
# `-depth` walks contents before their directory, which is exactly inside-out order.
find "$APP/Contents" -depth \( -name "*.app" -o -name "*.xpc" \) -print0 2>/dev/null | while IFS= read -r -d '' f; do
  echo "    nested bundle: ${f#$APP/}"
  sign "$f"
done

# Loose Mach-O helpers and libraries: the injected hook dylib, Sparkle's Autoupdate.
find "$APP/Contents" -type f -perm -u+x -print0 2>/dev/null | while IFS= read -r -d '' f; do
  # Only actual Mach-O files; scripts and resources are covered by the enclosing signature.
  if file -b "$f" | grep -q "Mach-O"; then
    case "$f" in
      "$APP/Contents/MacOS/$APPNAME") continue ;;   # the main executable, signed with the app
    esac
    echo "    macho: ${f#$APP/}"
    sign "$f"
  fi
done

# Versioned frameworks are signed at the version directory, then the bundle.
for fw in "$APP/Contents/Frameworks/"*.framework; do
  [ -e "$fw" ] || continue
  for v in "$fw/Versions/"*/; do
    case "$v" in *"/Current/") continue ;; esac
    [ -d "$v" ] && { echo "    framework version: ${v#$APP/}"; sign "$v"; }
  done
  echo "    framework: ${fw#$APP/}"
  sign "$fw"
done

sign "$APP"
# --deep on *verification* (not signing) is the check that every nested piece above really
# did get signed; it is how an unsigned Sparkle helper would be caught here rather than by
# the notary service ten minutes later.
codesign --verify --deep --strict --verbose=2 "$APP"

if [ -n "${SKIP_NOTARIZE:-}" ]; then
  echo "==> Skipping notarization (SKIP_NOTARIZE set) — for verifying signing only."
  echo "    The resulting DMG is NOT distributable."
fi

echo "==> Notarizing"
ZIP="$DIST/$APPNAME-notarize.zip"
if [ -z "${SKIP_NOTARIZE:-}" ]; then
  /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" \
    --key "$KEY_FILE" --key-id "$KEY_ID" --issuer "$ISSUER_ID" \
    --wait
  echo "==> Stapling"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl -a -vvv --type execute "$APP" || true
fi

echo "==> Building DMG"
DMG="$DIST/$APPNAME-$VERSION.dmg"
STAGE="$(mktemp -d)"; cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APPNAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
if [ -z "${SKIP_NOTARIZE:-}" ]; then
  # Notarize + staple the DMG too, so the download itself passes Gatekeeper.
  xcrun notarytool submit "$DMG" --key "$KEY_FILE" --key-id "$KEY_ID" --issuer "$ISSUER_ID" --wait
  xcrun stapler staple "$DMG"
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"

echo "==> Building the Sparkle appcast"
# Sparkle needs a signed feed to offer this build to anyone already running Snoopy. The
# private EdDSA key lives only in this machine's login keychain; generate_appcast reads it
# from there and never writes it anywhere.
SPARKLE_BIN="${SPARKLE_BIN:-$ROOT/.sparkle/bin}"
if [ ! -x "$SPARKLE_BIN/generate_appcast" ]; then
  echo "Sparkle tools not found at $SPARKLE_BIN — run Scripts/fetch-sparkle-tools.sh first."
  exit 1
fi

FEED="$DIST/appcast"; mkdir -p "$FEED"
cp "$DMG" "$FEED/"
# Release notes for this version, shown inside Sparkle's update window. Matching the
# archive's basename is how generate_appcast finds them.
NOTES="$ROOT/docs/RELEASE_NOTES_$VERSION.md"
[ -f "$NOTES" ] && cp "$NOTES" "$FEED/$APPNAME-$VERSION.md"

# Start from the published feed so the history survives; a feed rebuilt from scratch each
# time would drop every earlier version's entry.
PUBLISHED_FEED="https://github.com/$GH_OWNER/$GH_REPO/releases/latest/download/appcast.xml"
if curl -fsSL "$PUBLISHED_FEED" -o "$FEED/appcast.xml" 2>/dev/null; then
  echo "    seeded from the published feed"
else
  echo "    no published feed yet — starting a new one"
fi

"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/$GH_OWNER/$GH_REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$GH_OWNER/$GH_REPO" \
  --full-release-notes-url "https://github.com/$GH_OWNER/$GH_REPO/releases" \
  --embed-release-notes \
  "$FEED"

APPCAST="$FEED/appcast.xml"
[ -f "$APPCAST" ] || { echo "generate_appcast produced no appcast.xml"; exit 1; }
# A feed that does not mention this build would silently never offer it.
grep -q "sparkle:edSignature" "$APPCAST" || { echo "appcast has no EdDSA signature"; exit 1; }
grep -q "$APPNAME-$VERSION.dmg" "$APPCAST" || { echo "appcast does not list $APPNAME-$VERSION.dmg"; exit 1; }
cp "$APPCAST" "$DIST/appcast.xml"
rm -f "$FEED/$APPNAME-$VERSION.dmg"
echo "    appcast: $DIST/appcast.xml"

echo "==> Done"
echo "    $DMG"
echo "    $DIST/appcast.xml"
echo
echo "Publish both — the appcast must be attached to the release, because SUFeedURL points at"
echo "releases/latest/download/appcast.xml:"
echo "    gh release create v$VERSION \\"
echo "      \"$DMG\" \"$DMG.sha256\" \"$DIST/appcast.xml\" \\"
echo "      --title \"$APPNAME $VERSION\" --notes-file docs/RELEASE_NOTES_$VERSION.md"
