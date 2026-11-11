#!/bin/bash
# Compila CursorTrail.app. Serve solo Xcode Command Line Tools (xcode-select --install).
#   ./build.sh               per questo Mac
#   ./build.sh --universal   Apple Silicon + Intel, e crea CursorTrail.zip da distribuire
set -e
cd "$(dirname "$0")"
APP=CursorTrail.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
BIN="$APP/Contents/MacOS/CursorTrail"
if [ "$1" = "--universal" ]; then
  for arch in arm64 x86_64; do
    xcrun swiftc -O -swift-version 5 -target $arch-apple-macos14.0 main.swift -o "/tmp/CursorTrail-$arch"
  done
  lipo -create /tmp/CursorTrail-arm64 /tmp/CursorTrail-x86_64 -output "$BIN"
  rm -f /tmp/CursorTrail-arm64 /tmp/CursorTrail-x86_64
else
  xcrun swiftc -O -swift-version 5 main.swift -o "$BIN"
fi
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
  <key>NSHumanReadableCopyright</key><string>Made by mdrzn</string>
</dict></plist>
PLIST
codesign --force -s - "$APP"   # firma "ad hoc": basta per avviarla, non per Gatekeeper
if [ "$1" = "--universal" ]; then
  rm -f CursorTrail.zip
  ditto -c -k --keepParent "$APP" CursorTrail.zip
  echo "ok: $PWD/CursorTrail.zip ($(lipo -archs "$BIN"))"
else
  echo "ok: $PWD/$APP"
fi
