#!/bin/bash
# Builds the SnoopyTest iOS app and installs it on a booted simulator so it appears
# in Snoopy's app list. Usage: ./build-and-install.sh [UDID]
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
UDID="${1:-booted}"
BUNDLE_ID="dev.snoopy.TestApp"
APP="$DIR/build/SnoopyTest.app"
SDK="$(xcrun -sdk iphonesimulator --show-sdk-path)"
rm -rf "$APP"; mkdir -p "$APP"
xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios17.0-simulator -sdk "$SDK" \
  -framework SwiftUI -framework Foundation "$DIR"/src/*.swift -o "$APP/SnoopyTest"
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>SnoopyTest</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>SnoopyTest</string>
  <key>CFBundleDisplayName</key><string>Snoopy Test</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>UIDeviceFamily</key><array><integer>1</integer></array>
  <key>MinimumOSVersion</key><string>17.0</string>
  <key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
xcrun simctl install "$UDID" "$APP"
echo "Installed $BUNDLE_ID. It now appears in Snoopy's app list; press Run with Snoopy."
