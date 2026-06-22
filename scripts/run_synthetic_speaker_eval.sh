#!/bin/bash
# A/B the speaker write-path fixes (#6 write-time contamination gate + #8 cross-cluster link/merge
# decouple) on the network-free synthetic corpora from gen_synthetic_speaker_eval.py.
#
# For each corpus it replays the meetings IN ORDER through the real TranscriptedCore clusterer + DB
# matcher with the fixes OFF (legacy) and ON, then scores both against the ground-truth RTTMs and
# prints the before/after metrics (DER / fragmentation / false-merge / re-ID).
#
# Usage:
#   scripts/gen_synthetic_speaker_eval.py        # once, to (re)generate data/eval/synthetic
#   scripts/run_synthetic_speaker_eval.sh        # all corpora, match=0.65
#   MATCH=0.70 scripts/run_synthetic_speaker_eval.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

MATCH="${MATCH:-0.65}"
COLLAR="${COLLAR:-0.25}"
CONS="${CONS:-none}"
CORPORA="${CORPORA:-normal twopeople contamination}"
BASE="$ROOT/data/eval/synthetic"
BIN="$ROOT/Tools/SpeakerEvalHarness/.build/release/speaker-eval-harness"

[ -x "$BIN" ] || { echo "build first: swift build --package-path Tools/SpeakerEvalHarness -c release"; exit 1; }
[ -d "$BASE" ] || { echo "generate first: python3 scripts/gen_synthetic_speaker_eval.py"; exit 1; }

for corpus in $CORPORA; do
  dumps_dir="$BASE/$corpus/dumps"; rttm_dir="$BASE/$corpus/rttm"
  [ -d "$dumps_dir" ] || { echo "missing $dumps_dir"; continue; }
  # chronological order (filenames sort lexicographically: *_M01, *_M02, ...)
  inputs="$(ls "$dumps_dir"/*.json | sort | tr '\n' ',' | sed 's/,$//')"
  out="$BASE/$corpus/results"; mkdir -p "$out"
  echo "============================================================"
  echo "CORPUS: $corpus  (match=$MATCH consolidation=$CONS)"
  echo "============================================================"
  for mode in off on; do
    res="$out/replay_fixes_${mode}.json"
    "$BIN" replay --inputs "$inputs" --match "$MATCH" --consolidation "$CONS" \
      --write-path-fixes "$mode" --out "$res" 2>/dev/null
    echo "----- fixes=$mode -----"
    python3 "$ROOT/scripts/score_speaker_eval.py" --result "$res" --rttm-dir "$rttm_dir" \
      --collar "$COLLAR" 2>/dev/null \
      | grep -E "mean|Fragmentation|False-merge|re-ID|Profiles at end|…" || true
  done
  echo
done
