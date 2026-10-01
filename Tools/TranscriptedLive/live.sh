#!/usr/bin/env bash
# Try the live meeting mod: starts the transcripted-live helper in the
# background, then Claude Code (fullscreen, mod loaded) in the repo root.
#
#   Tools/TranscriptedLive/live.sh                 wait for a real Transcripted recording
#   Tools/TranscriptedLive/live.sh replay FILE     pretend meeting from an audio file, in real time
#   Tools/TranscriptedLive/live.sh replay --mic MIC --system SYSTEM
#
# Quitting Claude Code stops the helper.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BIN="$HERE/.build/release/transcripted-live"
LOG="${TMPDIR:-/tmp}/transcripted-live.log"

if [ ! -x "$BIN" ]; then
  echo "building transcripted-live (first time only)…"
  (cd "$HERE" && swift build -c release)
fi

if [ "${1:-watch}" = "replay" ]; then
  shift
  "$BIN" replay "$@" >"$LOG" 2>&1 &
else
  "$BIN" watch >"$LOG" 2>&1 &
fi
HELPER=$!
trap 'kill "$HELPER" 2>/dev/null || true' EXIT

echo "transcripted-live running (log: $LOG)"
cd "$REPO"
CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 CLAUDE_CODE_NO_FLICKER=1 claude --plugin-dir "$HERE/claude-mod"
