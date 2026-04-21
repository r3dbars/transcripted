#!/usr/bin/env bash
set -euo pipefail

# One-shot check for BET-88 QA gate comments.
# Mirrors workflow rules:
# - only comments authored by the designated owner
# - first non-empty line must be PASS / PASS: ... / FAIL / FAIL: ...
#
# Usage:
#   bash scripts/ops/qa-gate-check.sh [repo] [issue_number] [owner_login]
# Example:
#   bash scripts/ops/qa-gate-check.sh r3dbars/transcripted 428 r3dbars

REPO="${1:-r3dbars/transcripted}"
ISSUE_NUMBER="${2:-428}"
OWNER_LOGIN="${3:-r3dbars}"

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI is required" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 2
fi

comments_json="$(gh api --paginate \
  "repos/${REPO}/issues/${ISSUE_NUMBER}/comments" \
  --jq '.[]' | jq -s '.')"

result_json="$(jq -c --arg owner "$OWNER_LOGIN" '
  def first_line:
    (.body // ""
      | gsub("\\r"; "")
      | split("\n")
      | map(gsub("^\\s+|\\s+$"; ""))
      | map(select(length > 0))
      | .[0] // "");

  def gate_status:
    (first_line) as $line
    | if ($line | test("^PASS([[:space:]]*:[[:space:]]*.*)?$"; "i")) then "PASS"
      elif ($line | test("^FAIL([[:space:]]*:[[:space:]]*.*)?$"; "i")) then "FAIL"
      else "NONE"
      end;

  [ .[]
    | select(.user.login == $owner)
    | . as $c
    | { id: .id,
        created_at: .created_at,
        author: .user.login,
        first_line: ($c | first_line),
        gate: ($c | gate_status) }
    | select(.gate != "NONE")
  ] as $matches
  | if ($matches | length) == 0 then
      {
        status: "PENDING",
        gate_matches: 0,
        latest_gate: null
      }
    else
      {
        status: ((($matches | last).gate | ascii_downcase)),
        gate_matches: ($matches | length),
        latest_gate: ($matches | last)
      }
    end
' <<<"$comments_json")"

echo "$result_json"

status="$(jq -r '.status' <<<"$result_json")"
case "$status" in
  pass|fail)
    exit 0
    ;;
  PENDING)
    exit 3
    ;;
  *)
    echo "ERROR: unexpected status '$status'" >&2
    exit 2
    ;;
esac
