#!/usr/bin/env bash
set -euo pipefail

# qa-gate-closeout.sh - Close a QA-gated issue automatically when PASS is detected.
# Usage:
#   bash scripts/ops/qa-gate-closeout.sh <owner/repo> <issue-number>
# Exit codes:
#   0 => issue closed (PASS)
#   2 => FAIL detected (issue left open)
#   3 => PENDING (issue left open)
#   1 => usage/auth/tooling error

usage() {
  echo "Usage: bash scripts/ops/qa-gate-closeout.sh <owner/repo> <issue-number>"
  echo "Example: bash scripts/ops/qa-gate-closeout.sh r3dbars/transcripted 428"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 2 ]]; then
  usage
  exit 1
fi

REPO="$1"
ISSUE_NUMBER="$2"

if ! [[ "$ISSUE_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "ERROR: issue-number must be numeric"
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI not found"
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh is not authenticated (run 'gh auth login')"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_CHECK="$SCRIPT_DIR/qa-gate-check.sh"

if [[ ! -x "$GATE_CHECK" ]]; then
  echo "ERROR: missing executable $GATE_CHECK"
  exit 1
fi

set +e
STATUS_JSON="$("$GATE_CHECK" --json "$REPO" "$ISSUE_NUMBER" 2>/dev/null)"
RC=$?
set -e

STATUS="$(echo "$STATUS_JSON" | jq -r '.status // ""')"

if [[ "$STATUS" == "PASS" && $RC -eq 0 ]]; then
  gh issue close "$ISSUE_NUMBER" -R "$REPO" \
    --comment "Auto-close: QA gate check detected top-level PASS for this issue."
  echo "CLOSED: #$ISSUE_NUMBER (PASS)"
  exit 0
fi

if [[ "$STATUS" == "FAIL" || $RC -eq 2 ]]; then
  echo "FAIL: top-level FAIL detected on #$ISSUE_NUMBER (left open)"
  exit 2
fi

echo "PENDING: no top-level PASS/FAIL on #$ISSUE_NUMBER (left open)"
exit 3
