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
  echo "Optional: --json (print structured status output)"
  echo "Optional: --state-file <path> (persist last seen gate state)"
  echo "Optional: --quiet-no-change (suppress output if state did not change)"
  echo "Example: bash scripts/ops/qa-gate-check.sh r3dbars/transcripted 428"
}

JSON_MODE=0
STATE_FILE=""
QUIET_NO_CHANGE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      JSON_MODE=1
      shift
      ;;
    --state-file)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --state-file requires a path"
        exit 1
      fi
      STATE_FILE="$2"
      shift 2
      ;;
    --quiet-no-change)
      QUIET_NO_CHANGE=1
      shift
      ;;
    *)
      break
      ;;
  esac
done

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
COMMENTS_COUNT=$(echo "$COMMENTS_JSON" | jq -r 'length')
LATEST_COMMENT_ID=$(echo "$COMMENTS_JSON" | jq -r 'sort_by(.created_at) | last | .id // 0')

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
  STATUS="PASS"
  EXIT_CODE=0
elif [[ "$LATEST_RESULT" == "FAIL" ]]; then
  STATUS="FAIL"
  EXIT_CODE=2
else
  STATUS="PENDING"
  EXIT_CODE=3
fi

NO_CHANGE=0
if [[ -n "$STATE_FILE" && -f "$STATE_FILE" ]]; then
  PREV_STATUS=$(jq -r '.status // ""' "$STATE_FILE" 2>/dev/null || echo "")
  PREV_COUNT=$(jq -r '.comments_count // ""' "$STATE_FILE" 2>/dev/null || echo "")
  PREV_LATEST_ID=$(jq -r '.latest_comment_id // ""' "$STATE_FILE" 2>/dev/null || echo "")
  if [[ "$PREV_STATUS" == "$STATUS" && "$PREV_COUNT" == "$COMMENTS_COUNT" && "$PREV_LATEST_ID" == "$LATEST_COMMENT_ID" ]]; then
    NO_CHANGE=1
  fi
fi

if [[ -n "$STATE_FILE" ]]; then
  mkdir -p "$(dirname "$STATE_FILE")"
  jq -n \
    --arg repo "$REPO" \
    --argjson issue "$ISSUE_NUMBER" \
    --arg status "$STATUS" \
    --argjson comments_count "$COMMENTS_COUNT" \
    --argjson latest_comment_id "$LATEST_COMMENT_ID" \
    '{repo: $repo, issue: $issue, status: $status, comments_count: $comments_count, latest_comment_id: $latest_comment_id}' \
    > "$STATE_FILE"
fi

if [[ $QUIET_NO_CHANGE -eq 1 && $NO_CHANGE -eq 1 ]]; then
  exit "$EXIT_CODE"
fi

if [[ $JSON_MODE -eq 1 ]]; then
  jq -n \
    --arg repo "$REPO" \
    --argjson issue "$ISSUE_NUMBER" \
    --arg status "$STATUS" \
    --argjson comments_count "$COMMENTS_COUNT" \
    --argjson latest_comment_id "$LATEST_COMMENT_ID" \
    --argjson no_change "$NO_CHANGE" \
    '{repo: $repo, issue: $issue, status: $status, comments_count: $comments_count, latest_comment_id: $latest_comment_id, no_change: $no_change}'
else
  if [[ "$STATUS" == "PASS" ]]; then
    echo "PASS: issue #$ISSUE_NUMBER has a top-level PASS comment"
  elif [[ "$STATUS" == "FAIL" ]]; then
    echo "FAIL: issue #$ISSUE_NUMBER has a top-level FAIL comment"
  else
    echo "PENDING: no top-level PASS/FAIL comment on issue #$ISSUE_NUMBER"
  fi
fi

exit "$EXIT_CODE"
