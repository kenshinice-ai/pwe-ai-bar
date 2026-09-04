#!/bin/bash
# PWE AI Bar — session event bridge.
#
# Claude Code pipes one JSON object per hook firing on stdin; we append a line to a log the app
# tails. Deliberately dumb: no network, no lock beyond an atomic rename, and it exits 0 whatever
# happens — a hook that can fail is a hook that can break a coding session.
#
# The payload travels in an environment variable rather than on stdin, because stdin is already
# spoken for: the Python program itself arrives there.
set -u
DIR="$HOME/.cache/pwe-ai-bar"
mkdir -p "$DIR" 2>/dev/null || exit 0

KIND="${1:-waiting}"
PWEBAR_PAYLOAD="$(cat 2>/dev/null || true)"
export PWEBAR_PAYLOAD

PWEBAR_KIND="$KIND" PWEBAR_LOG="$DIR/events.jsonl" /usr/bin/python3 -c '
import json, os, time
kind = os.environ.get("PWEBAR_KIND", "waiting")
log  = os.environ["PWEBAR_LOG"]
try:
    o = json.loads(os.environ.get("PWEBAR_PAYLOAD") or "{}")
except Exception:
    o = {}
if not isinstance(o, dict):
    o = {}
rec = {
    "kind": kind,
    "provider": "claude",
    "at": time.time(),
    "session": o.get("session_id", ""),
    "cwd": o.get("cwd", ""),
    "text": (o.get("message") or "")[:200],
}
# A ring of recent events, not an archive.
lines = []
if os.path.exists(log):
    try:
        lines = open(log).readlines()[-40:]
    except Exception:
        lines = []
lines.append(json.dumps(rec, ensure_ascii=False) + "\n")
tmp = log + ".tmp"
with open(tmp, "w") as f:
    f.writelines(lines)
os.replace(tmp, log)
' 2>/dev/null || true
exit 0
