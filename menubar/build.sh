#!/bin/sh
# Build AIUsage.app from a single Swift file - no Xcode project needed.
#
#   ./menubar/build.sh            -> dist/AIUsage.app
#   DEST=/Applications ./menubar/build.sh --install
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/dist}
APP=$OUT/AIUsage.app
DEST=${DEST:-/Applications}

command -v swiftc >/dev/null 2>&1 || {
  echo "swiftc not found - install the Xcode Command Line Tools" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AIUsage</string>
  <key>CFBundleDisplayName</key><string>AI Usage</string>
  <key>CFBundleIdentifier</key><string>com.tyrannoapartment.aiusage</string>
  <key>CFBundleVersion</key><string>${VERSION:-0.3.2}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION:-0.3.2}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>AIUsage</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <!-- Menu bar only: no Dock icon, no main window. -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

swiftc -O -swift-version 5 \
  -framework AppKit \
  -o "$APP/Contents/MacOS/AIUsage" \
  "$ROOT/menubar/AIUsage.swift"

# SIGN_IDENTITY is set by CI, which holds the Developer ID certificate. Local
# builds fall back to an ad-hoc signature: enough for the machine that built
# the app, and it keeps macOS from re-prompting on every launch.
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" "$APP"
  echo "signed with: $SIGN_IDENTITY"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "built $APP"

if [ "${1:-}" = "--install" ]; then
  rm -rf "$DEST/AIUsage.app"
  cp -R "$APP" "$DEST/AIUsage.app"
  echo "installed $DEST/AIUsage.app"
fi
