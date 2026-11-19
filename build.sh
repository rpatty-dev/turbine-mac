#!/bin/bash
# Builds build/Turbine.app. Usage: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/Turbine.app
rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TurbineMac "$APP/Contents/MacOS/Turbine"
cp turbine.user.js "$APP/Contents/Resources/"
swiftc -O tools/makeicon.swift -o .build/makeicon && .build/makeicon assets/icon.svg build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Turbine</string>
  <key>CFBundleDisplayName</key><string>Turbine</string>
  <key>CFBundleIdentifier</key><string>dev.rpatty.turbine</string>
  <key>CFBundleVersion</key><string>1.0.0</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleExecutable</key><string>Turbine</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
</dict></plist>
PLIST
codesign --force -s - "$APP"
echo "Built $APP"
