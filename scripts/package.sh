#!/bin/bash
#
# Build, sign and package PWE AI Bar as a distributable .dmg.
#
#   ./scripts/package.sh              build + sign + dmg
#   ./scripts/package.sh --notarize   also submit to Apple and staple the ticket
#
# RUN THIS ON THE RELEASE MACHINE. The Developer ID private key lives there, not on the
# development Mac — a build signed here is ad-hoc and Gatekeeper will refuse it everywhere else.
# The script still runs on a dev machine; it just prints the warning and produces a local dmg.
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="PWE AI Bar"
TEAM_ID="2SQV3H5MH9"
VERSION="$(cat VERSION)"
DIST="dist"
STAGE="$DIST/stage"

NOTARIZE=0
[[ "${1:-}" == "--notarize" ]] && NOTARIZE=1

# ---------------------------------------------------------------- pick identity
IDENTITY="$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" | grep -v CSSMERR | head -1 \
  | sed -E 's/.*"(.*)".*/\1/' || true)"
KIND="developer-id"
if [[ -z "$IDENTITY" ]]; then IDENTITY="-"; KIND="ad-hoc"; fi
echo "▸ Signing identity : $IDENTITY  ($KIND)"

if [[ "$KIND" != "developer-id" ]]; then
  cat <<'WARN'

  ⚠  No "Developer ID Application" identity in this keychain.
     The .dmg will build, but Gatekeeper will block it on any other Mac and it
     cannot be notarised. This is expected on the development machine — do the
     release build on the machine that holds the private key.

WARN
fi

./scripts/build-app.sh release
APP="build/$APP_NAME.app"
mkdir -p "$DIST"
DMG="$DIST/$APP_NAME $VERSION.dmg"

echo "▸ Signing…"
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$APP"
else
  codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo "▸ Disk image…"
rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# The menu-bar-only design is the most common "I installed it and nothing happened" report,
# and the DMG window is the last place we can say so before the customer is on their own.
cat > "$STAGE/Read Me First.txt" <<'READ'
PWE AI Bar
────────────────────────────────────────────────────────────

INSTALL
  Drag PWE AI Bar onto the Applications folder beside it, then
  open it from your Applications folder.

IT LIVES IN THE MENU BAR
  There is no Dock icon. Look for the wing at the top right of
  your screen, near the clock.

  Click it for the panel. Right-click for settings and quit.

FIRST LAUNCH
  macOS will ask once for permission to read the Claude Code
  credential from your keychain. Choose "Always Allow" — the
  app needs it to read your real quota, and it is sent only to
  api.anthropic.com, never stored anywhere.

  Not logged in yet? Run  claude auth login  in Terminal.
  Without it the app falls back to reading local session logs,
  which give totals but no plan percentages.

SESSION ALERTS
  Settings → 会话事件 → 安装 adds two hooks to Claude Code so
  the app can tell you when Claude is waiting on you.

A Paradise Production
READ

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
rm -rf "$STAGE"
[[ "$IDENTITY" != "-" ]] && codesign --force --sign "$IDENTITY" --timestamp "$DMG"
echo "▸ Done: $DMG"

if [[ "$NOTARIZE" == "1" ]]; then
  [[ "$KIND" == "developer-id" ]] || { echo "✗ Notarisation needs a Developer ID identity."; exit 1; }
  # Credentials come from a keychain profile you create once on the release machine:
  #   xcrun notarytool store-credentials PWE_NOTARY \
  #     --apple-id <apple-id> --team-id 2SQV3H5MH9 --password <app-specific-password>
  PROFILE="${NOTARY_PROFILE:-PWE_NOTARY}"
  echo "▸ Submitting to Apple (profile: $PROFILE)…"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  echo "▸ Notarised and stapled: $DMG"
fi
