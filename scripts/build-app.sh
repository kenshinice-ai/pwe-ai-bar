#!/bin/bash
#
# Assemble PWE AI Bar.app from the SPM build. Local builds are ad-hoc signed, which is enough to
# run on this machine — Developer ID signing and notarisation happen on the release machine via
# package.sh, since the private key lives there.
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="PWE AI Bar"
BUNDLE_ID="com.paradiseproduction.pweaibar"
VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"
CONFIG="${1:-release}"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG" > /dev/null

BIN=".build/$CONFIG/PWEAIBar"
[[ -f "$BIN" ]] || { echo "✗ $BIN not found"; exit 1; }

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/PWEAIBar"

# SPM emits resources as a bundle beside the binary; carry it along or the fonts, the price
# list and the hook script all go missing at runtime.
for b in ".build/$CONFIG"/*.bundle; do
  [[ -e "$b" ]] && cp -R "$b" "$APP/Contents/Resources/"
done

# Icon: the plain mark on navy, straight from the brand assets.
ICONSET="build/icon.iconset"
SRC="$(find Sources/PWEAIBar/Resources -name 'AppIcon512.png' | head -1)"
if [[ -n "$SRC" ]]; then
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 64 128 256 512; do
    sips -z $s $s "$SRC" --out "$ICONSET/icon_${s}x${s}.png" > /dev/null 2>&1
    sips -z $((s*2)) $((s*2)) "$SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" > /dev/null 2>&1
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true
  rm -rf "$ICONSET"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>PWEAIBar</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- Menu bar only: no Dock icon, no app switcher entry. -->
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>A Paradise Production</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "▸ Done: $APP"
