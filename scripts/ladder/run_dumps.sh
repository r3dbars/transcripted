#!/usr/bin/env bash
# run_dumps.sh — Stage 1 of the multi-meeting confidence-ladder eval.
#
# Dump-only driver: runs the REAL diarizer (FluidAudio PyAnnote + 256-dim WeSpeaker
# embeddings, via the existing `speaker-eval-harness dump`) on every meeting WAV of a
# corpus and caches one JSON per meeting under data/eval/<CORPUS>/dumps/. Idempotent:
# a non-empty dump is skipped, so a long run survives interruption and resumes.
#
# This deliberately does NOT run the old `replay` threshold sweep — the ladder sweep
# is a separate stage that consumes these dumps (see ladder-fingerprints / ladder-sweep).
#
# Usage:
#   scripts/ladder/run_dumps.sh ami         # uses AUDIO_DIR=data/ami/audio  SUFFIX=.Mix-Headset.wav
#   scripts/ladder/run_dumps.sh voxceleb    # uses data/voxceleb/sessions/audio  SUFFIX=.wav
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
ROOT="$(pwd)"
CORPUS="${1:-ami}"

case "$CORPUS" in
  ami)        AUDIO_DIR="$ROOT/data/ami/audio";              SUFFIX=".Mix-Headset.wav" ;;
  icsi)       AUDIO_DIR="$ROOT/data/icsi/audio";             SUFFIX=".wav" ;;
  voxconverse)AUDIO_DIR="$ROOT/data/voxconverse/audio";      SUFFIX=".wav" ;;
  voxceleb)   AUDIO_DIR="$ROOT/data/voxceleb/sessions/audio";SUFFIX=".wav" ;;
  *) echo "unknown corpus $CORPUS"; exit 1 ;;
esac

BIN="$ROOT/Tools/SpeakerEvalHarness/.build/release/speaker-eval-harness"
DUMPS="$ROOT/data/eval/$CORPUS/dumps"
LOG="$ROOT/data/eval/_logs/dump_${CORPUS}.log"
mkdir -p "$DUMPS" "$ROOT/data/eval/_logs"

[ -x "$BIN" ] || { echo "harness binary missing: $BIN — run 'swift build -c release' in Tools/SpeakerEvalHarness" | tee -a "$LOG"; exit 1; }
[ -d "$AUDIO_DIR" ] || { echo "audio dir missing: $AUDIO_DIR" | tee -a "$LOG"; exit 1; }

shopt -s nullglob
files=("$AUDIO_DIR"/*"$SUFFIX")
total=${#files[@]}
echo "$(date '+%H:%M:%S') [dumps:$CORPUS] $total meetings in $AUDIO_DIR" | tee -a "$LOG"
[ "$total" -gt 0 ] || { echo "no audio files matching *$SUFFIX" | tee -a "$LOG"; exit 1; }

i=0; done=0; failed=0
for audio in "${files[@]}"; do
  i=$((i+1))
  base="$(basename "$audio")"
  m="${base%$SUFFIX}"
  out="$DUMPS/$m.json"
  if [ -s "$out" ]; then
    echo "$(date '+%H:%M:%S') [dumps:$CORPUS] ($i/$total) skip $m (cached)" | tee -a "$LOG"
    done=$((done+1)); continue
  fi
  echo "$(date '+%H:%M:%S') [dumps:$CORPUS] ($i/$total) diarizing $m ..." | tee -a "$LOG"
  if "$BIN" dump --audio "$audio" --meeting "$m" --out "$out" >>"$LOG" 2>&1; then
    if [ -s "$out" ]; then done=$((done+1)); else failed=$((failed+1)); echo "  -> EMPTY dump $m" | tee -a "$LOG"; fi
  else
    failed=$((failed+1)); echo "  -> FAILED $m (see log)" | tee -a "$LOG"
  fi
done
echo "$(date '+%H:%M:%S') [dumps:$CORPUS] DONE: $done ok, $failed failed, of $total" | tee -a "$LOG"
if [ "$failed" -gt 0 ]; then
  exit 1
fi
