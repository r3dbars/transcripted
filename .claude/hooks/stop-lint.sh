#!/bin/bash
# Claude Code Stop hook: before an agent ends its turn, lint what this branch
# changed (scripts/dev/lint.py --changed). New findings exit 2 with the report on
# stderr, which keeps the agent going so it fixes them. Exit 0 otherwise.
#
# Fails open: a missing python3, an unreadable hook payload, a crash in lint.py, or a
# rule-load error never blocks stopping. When the payload says
# stop_hook_active (the agent is already continuing because of this hook), exit
# 0 so a finding the agent can't fix doesn't loop forever.

payload="$(cat 2>/dev/null || true)"

if ! command -v python3 >/dev/null 2>&1; then
    exit 0
fi

active="$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read() or "{}")
    if not isinstance(data, dict):
        raise ValueError
    print("yes" if data.get("stop_hook_active") is True else "no")
except Exception:
    print("bad")
' 2>/dev/null)"
# Already continuing because of this hook, or a payload we can't read (so we
# can't tell): let the agent stop.
if [ "$active" != "no" ]; then
    exit 0
fi

root="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$root" ] || [ ! -f "$root/scripts/dev/lint.py" ]; then
    root="$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)"
fi
lint="$root/scripts/dev/lint.py"
if [ ! -f "$lint" ]; then
    exit 0
fi

output="$(cd "$root" && python3 "$lint" --changed 2>&1)"
status=$?

# lint.py exits 1 for findings over baseline, but also for rule-load errors,
# and a Python crash exits 1 too. Only block on real findings: lint.py's
# summary line starts with "lint: FAIL:" exactly then.
if [ "$status" -eq 1 ] && printf '%s\n' "$output" | grep -q '^lint: FAIL:'; then
    {
        echo "Stop hook: lint.py --changed found new findings in files this branch changed."
        echo "Fix them before you finish; each finding says how. A lint-allow needs a reason, an expiry and a human approver."
        echo
        printf '%s\n' "$output"
    } >&2
    exit 2
fi
exit 0
