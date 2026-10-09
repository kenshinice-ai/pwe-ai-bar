#!/bin/bash
# Have the app draw the pictures the film is cut from, in one interface language, and turn each into a take.
#
#   tools/stills.sh en | zh-Hans
#
# PWE AI Bar is a readout: nothing on it moves unless a quota moves, and a quota state cannot be
# waited for. So the film is cut from stills, and the app draws all of them with its own renderers:
#   --panel      the panel, the settings and the cost page, from this Mac's real data at this moment
#   --endurance  the verdict states, from sample figures (the app prints that they are synthetic)
# The panel renderer steps through the three panel modes and leaves the last one saved; this puts
# back the mode that was there. The settings sections are opened on the command line, not saved.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${AIBAR_APP:-/Applications/PWE AI Bar.app/Contents/MacOS/PWEAIBar}"
LANG_ARG="${1:-en}"; TAG=en; [[ "$LANG_ARG" == zh* ]] && TAG=zh
OUT="$ROOT/build/work/stills-$TAG"; mkdir -p "$OUT"
ID=com.paradiseproduction.pweaibar
MODE=$(defaults read "$ID" panelMode 2>/dev/null || echo full)
"$APP" --panel "$OUT" -language "$LANG_ARG" -settings.open.alerts 1 -settings.open.sources 1 -settings.open.general 0 | sed 's/^/  /'
defaults write "$ID" panelMode "$MODE"
"$APP" --endurance "$OUT" -language "$LANG_ARG" >/dev/null
take() {   # take <name> <png> [crop w:h:x:y]
  local vf="format=yuv444p"; [[ -n "${3:-}" ]] && vf="crop=$3,format=yuv444p"
  ffmpeg -v error -y -loop 1 -framerate 60 -t 4 -i "$OUT/$2" -vf "$vf" -c:v libx264 -crf 10 -g 30 "$ROOT/build/work/$1-$TAG.cfr.mp4"
  echo "  $1-$TAG  $(ffprobe -v error -show_entries stream=width,height -of csv=p=0 "$ROOT/build/work/$1-$TAG.cfr.mp4")"
}
take panel panel-full-dark.png
take makes endurance-comfortable-dark.png
take close endurance-tooclose-dark.png
take short endurance-short-dark.png
take gap endurance-measured-dark.png      # the falling-short state the product page describes; the page loop uses it
take cost trophy-dark.png
take settings settings-dark.png
