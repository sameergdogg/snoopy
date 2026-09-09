#!/bin/bash
# Builds libSnoopyHook.dylib for the iOS Simulator (arm64 + x86_64) and ad-hoc signs it.
# Usage: build-hook.sh [output-dir]   (default: build/hook)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/hook}"
TMP="$(mktemp -d)"
mkdir -p "$OUT"
SDK="$(xcrun -sdk iphonesimulator --show-sdk-path)"
FLAGS=(-isysroot "$SDK" -fobjc-arc -O2 -Wall -Wno-unused-function -dynamiclib -install_name @rpath/libSnoopyHook.dylib -framework Foundation)
xcrun -sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator "${FLAGS[@]}" "$ROOT"/Hook/*.m -o "$TMP/arm64.dylib"
xcrun -sdk iphonesimulator clang -target x86_64-apple-ios15.0-simulator "${FLAGS[@]}" "$ROOT"/Hook/*.m -o "$TMP/x86_64.dylib"
lipo -create "$TMP/arm64.dylib" "$TMP/x86_64.dylib" -output "$OUT/libSnoopyHook.dylib"
codesign --force --sign - "$OUT/libSnoopyHook.dylib" 2>/dev/null
rm -rf "$TMP"
echo "built $OUT/libSnoopyHook.dylib"
