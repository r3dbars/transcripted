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

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 2
fi

fetch_comments_json() {
  if command -v gh >/dev/null 2>&1; then
    gh api --paginate \
      "repos/${REPO}/issues/${ISSUE_NUMBER}/comments" \
      --jq '.[]' | jq -s '.'
    return
  fi

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl -fsSL \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${REPO}/issues/${ISSUE_NUMBER}/comments?per_page=100"
    return
  fi

  echo "ERROR: neither gh CLI nor GITHUB_TOKEN fallback is available" >&2
  return 2
}

comments_json="$(fetch_comments_json)"

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
