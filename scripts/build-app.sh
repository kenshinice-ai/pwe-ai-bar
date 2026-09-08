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

# Gate, not a reminder. A key used in Sources but absent from zh-Hans ships as one English row
# inside an otherwise Chinese panel — the kind of defect that survives a demo. Building the
# checker costs about a second; discovering the gap from a screenshot costs a release.
echo "▸ Checking the string tables…"
LOCCHECK="${PWEBAR_BUILD_ROOT:-.build}/loccheck"
mkdir -p "$(dirname "$LOCCHECK")"
if [[ ! -x "$LOCCHECK" || Tools/loccheck/main.swift -nt "$LOCCHECK" ]]; then
  swiftc -O Tools/loccheck/main.swift -o "$LOCCHECK"
fi
"$LOCCHECK" .

echo "▸ Building ($CONFIG)…"
BUILD_ARGS=(-c "$CONFIG")
[[ -n "${PWEBAR_BUILD_ROOT:-}" ]] && BUILD_ARGS+=(--scratch-path "$PWEBAR_BUILD_ROOT")
[[ -n "${PWEBAR_CACHE_PATH:-}" ]] && BUILD_ARGS+=(--cache-path "$PWEBAR_CACHE_PATH")
[[ "${PWEBAR_DISABLE_SANDBOX:-0}" == 1 ]] && BUILD_ARGS+=(--disable-sandbox)
# One pass, not two. Asking for --show-bin-path is itself a build invocation: it re-resolves
# and re-parses the package graph every time the app is assembled, for a path that the same
# arguments already determine.
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
swift build "${BUILD_ARGS[@]}" > /dev/null
BIN="$BIN_DIR/PWEAIBar"
[[ -f "$BIN" ]] || { echo "✗ $BIN not found"; exit 1; }

APP="${PWEBAR_APP_OUTPUT:-build/$APP_NAME.app}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/PWEAIBar"

# SPM emits resources as a bundle beside the binary; carry it along or the fonts, the price
# list and the hook script all go missing at runtime.
for b in "$BIN_DIR"/*.bundle; do
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

# Sign with a real identity when the keychain has one, ad-hoc only as a fallback.
#
# This is not about distribution — Developer ID signing happens on the release machine. It is
# about the keychain: macOS grants access to a *signature*, so an ad-hoc build gets a fresh
# identity on every compile and re-asks for permission to read the Claude Code credential every
# single time. A stable Apple Development identity makes that grant stick across rebuilds.
IDENTITY="${PWEBAR_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
IDENTITY="$(security find-identity -v -p codesigning \
  | grep -E "Developer ID Application|Apple Development" | grep -v CSSMERR | head -1 \
  | sed -E 's/.*"(.*)".*/\1/' || true)"
fi
[[ -z "$IDENTITY" ]] && IDENTITY="-"
codesign --force --deep --sign "$IDENTITY" "$APP" 2>/dev/null || \
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "▸ Signed with: $IDENTITY"
echo "▸ Done: $APP"
