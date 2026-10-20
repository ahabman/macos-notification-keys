#!/bin/zsh
# Builds NotificationKeys.app (menu bar agent) next to this script.
# ./build.sh --install also replaces /Applications/NotificationKeys.app.
set -euo pipefail
cd "$(dirname "$0")"
APP=NotificationKeys.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 Sources/main.swift -o "$APP/Contents/MacOS/NotificationKeys"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.notificationkeys</string>
  <key>CFBundleName</key><string>NotificationKeys</string>
  <key>CFBundleExecutable</key><string>NotificationKeys</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
# Ad-hoc signatures default to a designated requirement of the exact cdhash, so
# every rebuild loses the Accessibility grant. Pin the requirement to the bundle
# identifier instead so the grant survives rebuilds.
codesign --force --sign - -r='designated => identifier "local.notificationkeys"' "$APP"
echo "Built $PWD/$APP"
if [[ "${1:-}" == "--install" ]]; then
  pkill -f "/Applications/$APP/Contents/MacOS/" || true
  rm -rf "/Applications/$APP"
  ditto "$APP" "/Applications/$APP"
  echo "Installed /Applications/$APP"
fi
