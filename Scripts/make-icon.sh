#!/bin/bash
# Regenerates the AppIcon PNGs from Scripts/make-icon.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Snoopy/Resources/Assets.xcassets/AppIcon.appiconset"
TMP="$(mktemp -d)"
swiftc "$ROOT/Scripts/make-icon.swift" -o "$TMP/icongen"
"$TMP/icongen" "$OUT"
rm -f "$OUT/master_1024.png"; rm -rf "$TMP"
echo "regenerated icons in $OUT"
