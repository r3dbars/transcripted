#!/usr/bin/env bash
# Runs a test command and samples the xctest process whenever its output goes
# quiet, so a CI stall leaves every thread's stack behind instead of only
# XCTest's "A stall was detected" line.
#
# Usage: bash scripts/dev/swift-test-stall-watch.sh swift test [args...]
#
# The command's output streams through unchanged and its exit status is
# returned. Samples land in $STALL_WATCH_DIR (default
# $RUNNER_TEMP/xctest-stall-samples); CI prints them only when the step fails.
#
# NSUnbufferedIO=YES makes xctest flush each line, so quiet output means a
# test is really not progressing (block-buffered pipe output arrives in
# multi-second bursts and would trigger false samples).

set -uo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <command> [args...]" >&2
  exit 2
fi

quiet_after="${STALL_WATCH_QUIET_SECONDS:-10}"
max_samples="${STALL_WATCH_MAX_SAMPLES:-8}"
out_dir="${STALL_WATCH_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/xctest-stall-samples}"
mkdir -p "$out_dir"
log="$out_dir/output.log"
status_file="$out_dir/.exit-status"
: > "$log"
rm -f "$status_file"

export NSUnbufferedIO=YES

{ "$@" 2>&1; echo "$?" > "$status_file"; } | tee "$log" &
pipeline=$!

sample_process() {
  local pid="$1" file="$2"
  # xctest is a platform binary, so an unprivileged sample is usually denied.
  # Hosted runners have passwordless sudo; fall back to a plain attempt.
  if sudo -n true 2>/dev/null; then
    sudo -n /usr/bin/sample "$pid" 3 -mayDie -file "$file" >/dev/null 2>&1 && return 0
  fi
  /usr/bin/sample "$pid" 3 -mayDie -file "$file" >/dev/null 2>&1
}

samples=0
last_size=-1
quiet_since=$(date +%s)
while kill -0 "$pipeline" 2>/dev/null; do
  sleep 1
  size=$(wc -c < "$log" | tr -d ' ')
  now=$(date +%s)
  if [ "$size" != "$last_size" ]; then
    last_size="$size"
    quiet_since="$now"
    continue
  fi
  if [ $((now - quiet_since)) -lt "$quiet_after" ] || [ "$samples" -ge "$max_samples" ]; then
    continue
  fi
  for pid in $(pgrep -x xctest || true); do
    samples=$((samples + 1))
    file="$out_dir/xctest-$pid-sample-$samples.txt"
    {
      echo "sampled at $(date -u +%Y-%m-%dT%H:%M:%SZ) after $((now - quiet_since))s without test output"
      echo "last test output line: $(tail -n 1 "$log")"
    } > "$file.header"
    if ! sample_process "$pid" "$file"; then
      echo "sample of xctest pid $pid failed" >> "$file.header"
    fi
  done
  # Re-arm so a long stall is sampled again later, not every second.
  quiet_since=$(date +%s)
done

wait "$pipeline"
status=$(cat "$status_file" 2>/dev/null || echo 1)
exit "$status"
