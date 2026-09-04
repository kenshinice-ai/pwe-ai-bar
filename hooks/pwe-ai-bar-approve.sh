#!/bin/bash
# PWE AI Bar — remote permission approval (PreToolUse).
#
# Lets you answer a permission prompt from a notification instead of the terminal, so a run does
# not sit blocked while you are away from the desk.
#
# Every branch is built to fail open, back to Claude Code's own prompt:
#   · off by default — the app writes the enable flag only when you turn it on
#   · allowlist only — a tool that is not on the list is never answered remotely
#   · timeout — nobody answers, we exit 0 silently and the normal prompt appears
#   · any error at all — exit 0
# Exiting 0 with no output means "no opinion", which is the safe thing to say.
set -u
DIR="$HOME/.cache/pwe-ai-bar"
FLAG="$DIR/remote-approval.on"
[[ -f "$FLAG" ]] || exit 0

ALLOW="$DIR/approval-allowlist.txt"
[[ -f "$ALLOW" ]] || exit 0

PWEBAR_PAYLOAD="$(cat 2>/dev/null || true)"
export PWEBAR_PAYLOAD PWEBAR_DIR="$DIR" PWEBAR_ALLOW="$ALLOW"

/usr/bin/python3 -c '
import json, os, sys, time, uuid

payload = os.environ.get("PWEBAR_PAYLOAD") or "{}"
try:
    o = json.loads(payload)
    if not isinstance(o, dict):
        raise ValueError
except Exception:
    sys.exit(0)

tool = o.get("tool_name", "")
tin  = o.get("tool_input") or {}
subject = tin.get("command") or tin.get("file_path") or ""

# Allowlist: one "Tool" or "Tool:prefix" per line. A Bash entry matches on command prefix, so
# "Bash:git " covers git and nothing else. Anything unmatched falls through to the real prompt.
allowed = False
for raw in open(os.environ["PWEBAR_ALLOW"]):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    name, _, prefix = line.partition(":")
    if name != tool:
        continue
    if not prefix or str(subject).startswith(prefix):
        allowed = True
        break
if not allowed:
    sys.exit(0)

d = os.environ["PWEBAR_DIR"]
os.makedirs(d + "/pending", exist_ok=True)
os.makedirs(d + "/decisions", exist_ok=True)
rid = uuid.uuid4().hex[:12]
req = {
    "id": rid, "tool": tool, "subject": str(subject)[:300],
    "session": o.get("session_id", ""), "cwd": o.get("cwd", ""), "at": time.time(),
}
tmp = f"{d}/pending/{rid}.json.tmp"
with open(tmp, "w") as f:
    json.dump(req, f, ensure_ascii=False)
os.replace(tmp, f"{d}/pending/{rid}.json")

# Ninety seconds is long enough to reach for a phone and short enough that a forgotten prompt
# does not hold a session hostage.
deadline = time.time() + 90
decision = None
while time.time() < deadline:
    path = f"{d}/decisions/{rid}.json"
    if os.path.exists(path):
        try:
            decision = json.load(open(path))
        except Exception:
            decision = None
        try:
            os.remove(path)
        except Exception:
            pass
        break
    time.sleep(0.4)

try:
    os.remove(f"{d}/pending/{rid}.json")
except Exception:
    pass

if not decision or decision.get("verdict") not in ("allow", "deny"):
    sys.exit(0)          # nobody answered — hand it back to the normal prompt

print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": decision["verdict"],
    "permissionDecisionReason": "PWE AI Bar — 你在通知里" + ("批准" if decision["verdict"] == "allow" else "拒绝") + "了",
}}, ensure_ascii=False))
' 2>/dev/null || true
exit 0
