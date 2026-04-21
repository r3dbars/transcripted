#!/usr/bin/env bash
set -euo pipefail

# qa-gate-check.sh - Check a GitHub issue for a top-level QA PASS/FAIL gate comment.
# Usage:
#   bash scripts/ops/qa-gate-check.sh <owner/repo> <issue-number>
# Exit codes:
#   0 => PASS found
#   2 => FAIL found
#   3 => no PASS/FAIL found yet (pending)
#   1 => usage/auth/tooling error

usage() {
  echo "Usage: bash scripts/ops/qa-gate-check.sh <owner/repo> <issue-number>"
  echo "Example: bash scripts/ops/qa-gate-check.sh r3dbars/transcripted 428"
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

# Only top-level issue comments are checked here (not review comments).
COMMENTS_JSON=$(gh api "repos/$REPO/issues/$ISSUE_NUMBER/comments")

LATEST_RESULT=$(
  echo "$COMMENTS_JSON" | jq -r '
    map({
      id: .id,
      body: (.body // ""),
      created_at: .created_at
    })
    | map(. + {
        result:
          (if (.body | test("(^|\\n)[[:space:]]*PASS([[:space:]]|$)"; "m")) then "PASS"
           elif (.body | test("(^|\\n)[[:space:]]*FAIL([[:space:]]|$)"; "m")) then "FAIL"
           else ""
           end)
      })
    | map(select(.result != ""))
    | sort_by(.created_at)
    | last
    | .result // ""
  '
)

if [[ "$LATEST_RESULT" == "PASS" ]]; then
  echo "PASS: issue #$ISSUE_NUMBER has a top-level PASS comment"
  exit 0
fi

if [[ "$LATEST_RESULT" == "FAIL" ]]; then
  echo "FAIL: issue #$ISSUE_NUMBER has a top-level FAIL comment"
  exit 2
fi

echo "PENDING: no top-level PASS/FAIL comment on issue #$ISSUE_NUMBER"
exit 3
