#!/usr/bin/env bash
set -euo pipefail

# Closeout helper for BET-88 QA gate issue.
# Uses scripts/ops/qa-gate-check.sh for a single deterministic status read.
#
# Usage:
#   bash scripts/ops/qa-gate-closeout.sh [repo] [issue_number] [owner_login]

REPO="${1:-r3dbars/transcripted}"
ISSUE_NUMBER="${2:-428}"
OWNER_LOGIN="${3:-r3dbars}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/qa-gate-check.sh"

if [[ ! -x "$CHECK_SCRIPT" ]]; then
  echo "ERROR: missing executable check helper: $CHECK_SCRIPT" >&2
  exit 2
fi

check_output=""
check_exit=0
set +e
check_output="$(bash "$CHECK_SCRIPT" "$REPO" "$ISSUE_NUMBER" "$OWNER_LOGIN")"
check_exit=$?
set -e

echo "$check_output"

if [[ $check_exit -eq 0 ]]; then
  status="$(jq -r '.status' <<<"$check_output")"
  case "$status" in
    pass)
      echo "CLOSEOUT: PASS detected for #$ISSUE_NUMBER"
      echo "ACTION: none (workflow should auto-close; manual closeout can proceed)"
      ;;
    fail)
      echo "CLOSEOUT: FAIL detected for #$ISSUE_NUMBER"
      echo "ACTION: open/continue follow-up fix issue and link it back to #$ISSUE_NUMBER"
      ;;
    *)
      echo "ERROR: unexpected success status '$status'" >&2
      exit 2
      ;;
  esac
  exit 0
fi

if [[ $check_exit -eq 3 ]]; then
  echo "CLOSEOUT: PENDING (no valid owner-authored PASS/FAIL gate comment yet)"
  echo "UNBLOCK_OWNER: @$OWNER_LOGIN"
  echo "UNBLOCK_ACTION: post top-level comment on #$ISSUE_NUMBER with first non-empty line PASS / PASS: ... / FAIL / FAIL: ..."
  exit 3
fi

echo "ERROR: qa-gate-check failed (exit $check_exit)" >&2
exit "$check_exit"
