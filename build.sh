#!/bin/bash
# Compila CursorTrail.app (serve solo Xcode Command Line Tools)
set -e
cd "$(dirname "$0")"
APP=CursorTrail.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/CursorTrail"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.cursortrail</string>
  <key>CFBundleName</key><string>CursorTrail</string>
  <key>CFBundleExecutable</key><string>CursorTrail</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force -s - "$APP"
echo "ok: $PWD/$APP"
