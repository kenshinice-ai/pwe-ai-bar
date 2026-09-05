#!/bin/bash
# One immutable file per event; concurrent writers never rewrite shared state.
# The app removes consumed files after saving session state. Unread events are not evicted.
set -u
umask 077
DIR="${PWEBAR_EVENT_DIR:-$HOME/.cache/pwe-ai-bar}/events"
mkdir -p "$DIR" 2>/dev/null || exit 0
PWEBAR_KIND="${1:-waiting}" PWEBAR_SPOOL="$DIR" /usr/bin/python3 -c '
import json, os, sys, time, uuid
try:
    o = json.load(sys.stdin)
    if not isinstance(o, dict):
        sys.exit(0)
    kind = os.environ["PWEBAR_KIND"]
    if kind not in ("waiting", "answered", "finished", "failed"):
        sys.exit(0)
    ident = uuid.uuid4().hex
    rec = {"event_id": ident, "kind": kind, "provider": "claude", "at": time.time(),
           "session": str(o.get("session_id") or ""), "cwd": str(o.get("cwd") or ""),
           "text": "" if kind == "answered" else str(o.get("message") or "")[:200]}
    path = os.path.join(os.environ["PWEBAR_SPOOL"], ident)
    with open(path + ".tmp", "x") as f:
        json.dump(rec, f, ensure_ascii=False)
        f.flush()
        os.fsync(f.fileno())
    os.replace(path + ".tmp", path + ".json")
    # If the app is gone but the hooks are still installed, nothing ever drains this directory.
    # Sweep occasionally rather than on every event: a week-old event can no longer be reported.
    if int(ident[:2], 16) < 6:
        cutoff = time.time() - 7 * 86400
        with os.scandir(os.environ["PWEBAR_SPOOL"]) as it:
            for entry in it:
                try:
                    if entry.is_file() and entry.stat().st_mtime < cutoff:
                        os.unlink(entry.path)
                except OSError:
                    pass
except Exception:
    pass
' 2>/dev/null || true
exit 0
