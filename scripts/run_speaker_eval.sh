#!/bin/bash
# Re-runnable speaker-naming eval against AMI ground truth.
#
#   1. build the harness (reuses prebuilt deps under deps-libs/ etc.)
#   2. dump-diarize each AMI session once (cached in data/eval/dumps/)
#   3. replay the session series IN ORDER through the real clusterer + DB matcher
#      for every (consolidation × match) threshold combo
#   4. score each combo vs the AMI RTTMs and aggregate a sweep table
#
# Usage:
#   scripts/run_speaker_eval.sh                 # full sweep on the default ES2002 series
#   SERIES="ES2002a ES2002b ES2002c ES2002d" scripts/run_speaker_eval.sh
#   CONSOLIDATION="none 0.85 0.88" MATCH="0.55 0.6 0.65" scripts/run_speaker_eval.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

SERIES="${SERIES:-ES2002a ES2002b ES2002c ES2002d}"
# Sweep grids — consolidation around the 0.88 same-voice bar, match around 0.6.
CONSOLIDATION="${CONSOLIDATION:-none 0.82 0.85 0.88 0.91}"
MATCH="${MATCH:-0.50 0.55 0.60 0.65 0.70}"
COLLAR="${COLLAR:-0.25}"

BIN="$ROOT/Tools/SpeakerEvalHarness/.build/release/speaker-eval-harness"
DUMPS="$ROOT/data/eval/dumps"
RESULTS="$ROOT/data/eval/results"
REPORTS="$ROOT/data/eval/reports"
mkdir -p "$DUMPS" "$RESULTS" "$REPORTS"

echo "==> build harness"
( cd "$ROOT/Tools/SpeakerEvalHarness" && swift build -c release 2>&1 | grep -vE "\.pcm|while processing" | tail -1 )

echo "==> dump-diarize sessions (cached)"
INPUTS=""
for m in $SERIES; do
  dump="$DUMPS/$m.json"
  if [ ! -s "$dump" ]; then
    echo "    diarizing $m ..."
    "$BIN" dump --audio "$ROOT/data/ami/audio/$m.Mix-Headset.wav" --meeting "$m" --out "$dump" \
      2>&1 | grep -E "^\[dump\] $m:" | grep -v processing || true
  else
    echo "    cached $m"
  fi
  INPUTS="${INPUTS:+$INPUTS,}$dump"
done

echo "==> threshold sweep (consolidation × match)"
SWEEP_JSONS=""
for cons in $CONSOLIDATION; do
  for mt in $MATCH; do
    tag="cons_${cons}_match_${mt}"
    res="$RESULTS/$tag.json"
    score="$REPORTS/$tag.json"
    "$BIN" replay --inputs "$INPUTS" --consolidation "$cons" --match "$mt" --out "$res" \
      2>&1 | grep -vE "\.pcm|while processing" | tail -1
    python3 "$ROOT/scripts/score_speaker_eval.py" --result "$res" --rttm-dir "$ROOT/data/ami/rttm" \
      --collar "$COLLAR" --out-json "$score" >/dev/null
    SWEEP_JSONS="${SWEEP_JSONS:+$SWEEP_JSONS,}$score"
  done
done

echo "==> aggregate"
python3 "$ROOT/scripts/aggregate_sweep.py" --scores "$SWEEP_JSONS" --out-md "$REPORTS/SWEEP.md"
echo "==> wrote $REPORTS/SWEEP.md"
