#!/bin/bash
#
# The three images pwestudio.site/aibar shows, rebuilt from the app itself.
#
#   ./scripts/site-shots.sh [destination]     default: ../PWE Loan Bar/site/public/aibar/img
#
# They were assembled by hand once and then could not be made again, so they kept showing a
# typeface, a wordmark and a summary band the app had already stopped drawing. Anything the
# website claims about this app should come out of this script.
#
# Prints the pixel dimensions at the end: the product page and the home-page shelf both state
# width and height on every <img>, and a stale pair is a layout shift on every load.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="${1:-../PWE Loan Bar/site/public/aibar/img}"
APP="build/PWE AI Bar.app/Contents/MacOS/PWEAIBar"
[[ -x "$APP" ]] || { echo "✗ build/PWE AI Bar.app is not there — run ./scripts/build-app.sh first"; exit 1; }
[[ -d "$DEST" ]] || { echo "✗ no such destination: $DEST"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Chinese, because that is what the page shows. `-language` is read before any drawing happens.
echo "▸ rendering (zh-Hans)…"
"$APP" --panel     "$WORK" -language zh-Hans >/dev/null
"$APP" --endurance "$WORK" -language zh-Hans >/dev/null
"$APP" --icon      "$WORK" -language zh-Hans >/dev/null

python3 - "$WORK" "$DEST" <<'PY'
import sys
from PIL import Image

work, dest = sys.argv[1], sys.argv[2]

# The panel at standard density — the one the page's hero shows.
panel = Image.open(f"{work}/panel-standard-dark.png")
panel.save(f"{dest}/panel-dark.png")

# Three endurance verdicts stacked: comfortable, too close to call, falls short. One image
# because the page's point is the comparison between them.
states = ["comfortable", "tooclose", "short"]
tiles = [Image.open(f"{work}/endurance-{s}-dark.png") for s in states]
gap = 12
ground = tiles[0].getpixel((4, 4))
sheet = Image.new("RGBA", (tiles[0].width, sum(t.height for t in tiles) + gap * (len(tiles) - 1)), ground)
y = 0
for t in tiles:
    sheet.paste(t, (0, y))
    y += t.height + gap
sheet.save(f"{dest}/verdicts-dark.png")

# The menu bar. The app draws its own sheet at roughly 6.7×, which downsamples to a clean 2×.
bar = Image.open(f"{work}/icon-full-dark.png")
height = 52
bar.resize((round(bar.width * height / bar.height), height), Image.LANCZOS).save(f"{dest}/menubar.png")

print()
print("  check every <img> that points at these — the page states width and height on each,")
print("  and a stale pair is a layout shift on every load:")
for name, scale in [("panel-dark", 1), ("verdicts-dark", 1), ("menubar", 2)]:
    w, h = Image.open(f"{dest}/{name}.png").size
    print(f"    {name}.png".ljust(24) + f"{w}×{h} on disk"
          + f"   →   width=\"{w // scale}\" height=\"{h // scale}\""
          + ("   (@2x)" if scale == 2 else ""))
PY
