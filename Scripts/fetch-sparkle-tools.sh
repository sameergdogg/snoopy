#!/bin/bash
# Downloads the Sparkle command-line tools used by release.sh (generate_appcast, sign_update,
# generate_keys) into .sparkle/, which is gitignored.
#
# The tools are not part of the Swift package — SPM gives you the framework the app links,
# not the release tooling — so they are fetched separately and pinned to the same version.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${SPARKLE_VERSION:-2.10.0}"
DEST="$ROOT/.sparkle"

if [ -x "$DEST/bin/generate_appcast" ] && [ "$(cat "$DEST/.version" 2>/dev/null)" = "$VERSION" ]; then
  echo "Sparkle $VERSION tools already present at $DEST/bin"
  exit 0
fi

echo "==> Fetching Sparkle $VERSION tools"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/Sparkle.tar.xz" \
  "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
tar -xf "$TMP/Sparkle.tar.xz" -C "$TMP"
[ -d "$TMP/bin" ] || { echo "unexpected archive layout — no bin/"; exit 1; }

rm -rf "$DEST"; mkdir -p "$DEST"
cp -R "$TMP/bin" "$DEST/bin"
printf '%s' "$VERSION" > "$DEST/.version"
echo "==> Sparkle $VERSION tools at $DEST/bin"

if ! security find-generic-password -s "https://sparkle-project.org" >/dev/null 2>&1; then
  cat <<'NOTE'

No Sparkle signing key found in the login keychain. Releases must be signed with the key
matching SUPublicEDKey in project.yml, or existing installs will refuse the update. If this
is a new machine, import the key rather than generating a new one — generating a new pair
orphans everyone already running Snoopy.
NOTE
fi
