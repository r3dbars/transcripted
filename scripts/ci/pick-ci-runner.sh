#!/usr/bin/env bash
# Picks where Swift CI's `checks` and `spm-tests` jobs run: the owner's Mac
# (self-hosted runners labelled transcripted-mac) when it has said recently
# that it is free, otherwise a GitHub-hosted macos-26 runner.
#
# The Mac reports in through the MAC_RUNNER_HEARTBEAT repository variable
# (written by scripts/ci/mac-runner.sh heartbeat every 30s). The value is a
# Unix timestamp while at least one Mac runner is online and idle, or a word
# (busy, paused, battery) when it should not take new jobs. A missing, stale,
# or non-numeric heartbeat falls back to hosted, so a closed laptop only costs
# the fallback, never a stuck queue.
#
# Inputs (env): HEARTBEAT, MODE (MAC_RUNNER_MODE; "off" forces hosted), EVENT,
# HEAD_REPO, REPO, and optionally NOW and MAX_AGE_SECONDS.
# Output: runs-on=<JSON> in $GITHUB_OUTPUT, plus a one-line reason.
#
# Usage: bash scripts/ci/pick-ci-runner.sh [--self-test]

set -euo pipefail

HOSTED='"macos-26"'
MAC='["self-hosted","transcripted-mac"]'

# decide <event> <repo> <head_repo> <heartbeat> <mode> <now> <max_age>
# Prints "hosted|mac <reason>".
decide() {
  local event="$1" repo="$2" head_repo="$3" heartbeat="$4" mode="$5" now="$6" max_age="$7"

  if [ "$mode" = "off" ]; then
    echo "hosted MAC_RUNNER_MODE is off"
    return
  fi
  case "$event" in
    push|workflow_dispatch) ;;
    pull_request)
      # Fork PRs never reach the Mac. The Mac's job-started hook refuses
      # them too, since a fork can edit this workflow.
      if [ -z "$head_repo" ] || [ "$head_repo" != "$repo" ]; then
        echo "hosted pull request comes from a fork"
        return
      fi
      ;;
    *)
      echo "hosted event $event is not routed to the Mac"
      return
      ;;
  esac
  if ! [[ "$heartbeat" =~ ^[0-9]+$ ]]; then
    echo "hosted Mac heartbeat is '${heartbeat:-unset}'"
    return
  fi
  local age=$((now - heartbeat))
  # Allow a minute of clock skew in the Mac's favour, no more.
  if [ "$age" -lt -60 ] || [ "$age" -gt "$max_age" ]; then
    echo "hosted Mac heartbeat is ${age}s old"
    return
  fi
  echo "mac Mac reported idle ${age}s ago"
}

self_test() {
  local failures=0 now=1000000
  check() {
    local want="$1"; shift
    local got
    got="$(decide "$@")"
    if [ "${got%% *}" != "$want" ]; then
      echo "FAIL: decide $* -> '$got', want $want" >&2
      failures=$((failures + 1))
    fi
  }
  local r="r3dbars/transcripted"
  check mac    pull_request      "$r" "$r"          "$((now - 10))"  ""    "$now" 150
  check mac    push              "$r" ""            "$now"           ""    "$now" 150
  check mac    workflow_dispatch "$r" ""            "$((now - 150))" ""    "$now" 150
  check hosted pull_request      "$r" "someone/fork" "$now"          ""    "$now" 150
  check hosted pull_request      "$r" ""            "$now"           ""    "$now" 150
  check hosted pull_request_target "$r" "$r"        "$now"           ""    "$now" 150
  check hosted pull_request      "$r" "$r"          "$((now - 151))" ""    "$now" 150
  check hosted pull_request      "$r" "$r"          "$((now + 61))"  ""    "$now" 150
  check mac    pull_request      "$r" "$r"          "$((now + 30))"  ""    "$now" 150
  check hosted pull_request      "$r" "$r"          ""               ""    "$now" 150
  check hosted pull_request      "$r" "$r"          "busy"           ""    "$now" 150
  check hosted pull_request      "$r" "$r"          "paused"         ""    "$now" 150
  check hosted pull_request      "$r" "$r"          "12 34"          ""    "$now" 150
  check hosted push              "$r" ""            "$now"           "off" "$now" 150
  if [ "$failures" -ne 0 ]; then
    echo "pick-ci-runner self-test: $failures failure(s)" >&2
    exit 1
  fi
  echo "pick-ci-runner self-test: ok"
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit 0
fi

result="$(decide "${EVENT:-}" "${REPO:-}" "${HEAD_REPO:-}" "${HEARTBEAT:-}" "${MODE:-}" \
  "${NOW:-$(date +%s)}" "${MAX_AGE_SECONDS:-150}")"
choice="${result%% *}"
reason="${result#* }"
if [ "$choice" = "mac" ]; then
  runs_on="$MAC"
else
  runs_on="$HOSTED"
fi

echo "checks + spm-tests -> $runs_on ($reason)"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "runs-on=$runs_on" >> "$GITHUB_OUTPUT"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "checks + spm-tests run on \`$runs_on\`: $reason" >> "$GITHUB_STEP_SUMMARY"
fi
