#!/bin/bash
# One immutable file per event; concurrent writers never rewrite shared state.
# The app removes consumed files after saving session state. Unread events are not evicted.
set -u
umask 077
DIR="${PWEBAR_EVENT_DIR:-$HOME/.cache/pwe-ai-bar}/events"
mkdir -p "$DIR" 2>/dev/null || exit 0
KIND="${1:-waiting}"
case "$KIND" in waiting|answered|finished|failed) ;; *) exit 0 ;; esac

# /usr/bin/python3 is only a real interpreter once the Command Line Tools (or Xcode) are
# installed. Without them it is a stub that offers to install them, and a hook that shells out
# to it silently records nothing. `xcode-select -p` answers without prompting.
if [ -z "${PWEBAR_NO_PYTHON:-}" ] && [ -x /usr/bin/python3 ] \
   && { [ "$(uname)" != "Darwin" ] || /usr/bin/xcode-select -p >/dev/null 2>&1; }; then
PWEBAR_KIND="$KIND" PWEBAR_SPOOL="$DIR" /usr/bin/python3 -c '
import json, os, sys, time, uuid
try:
    o = json.load(sys.stdin)
    if not isinstance(o, dict):
        sys.exit(0)
    kind = os.environ["PWEBAR_KIND"]
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
fi

# No Python: the same record, built with what every Mac has. The fields are lifted out of the
# payload as JSON string bodies — escapes and all — and written back into JSON strings, so they
# never need decoding here. A field that is too long to trust is left empty rather than cut,
# since cutting could split an escape; the app shortens the text itself.
{
PAYLOAD="$(head -c 262144 | tr '\n\r' '  ')"
# Same rule as the Python path: a payload that is not a JSON object is not an event.
case "${PAYLOAD#"${PAYLOAD%%[![:space:]]*}"}" in \{*) ;; *) exit 0 ;; esac
field() {
    local v
    v="$(printf '%s' "$PAYLOAD" | sed -nE 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p')"
    [ "${#v}" -le 4096 ] && printf '%s' "$v"
}
SESSION="$(field session_id)"
CWD="$(field cwd)"
TEXT=""
[ "$KIND" = "answered" ] || TEXT="$(field message)"
IDENT="$(/usr/bin/uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null)"
IDENT="$(printf '%s' "$IDENT" | tr -d '-' | tr 'A-F' 'a-f')"
[ -n "$IDENT" ] || exit 0
AT="$(date +%s)"
TMP="$DIR/$IDENT.tmp"
( set -o noclobber
  printf '{"event_id":"%s","kind":"%s","provider":"claude","at":%s,"session":"%s","cwd":"%s","text":"%s"}' \
      "$IDENT" "$KIND" "$AT" "$SESSION" "$CWD" "$TEXT" > "$TMP" ) || exit 0
mv -f "$TMP" "$DIR/$IDENT.json"
case "$IDENT" in 0*) find "$DIR" -type f -mtime +7 -delete ;; esac
} 2>/dev/null || true
exit 0
