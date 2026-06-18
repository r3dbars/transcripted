#!/bin/bash
# End-to-end: replay a candidate model's dumps through the REAL clusterer + DB matcher and
# score vs AMI RTTM, sweeping the cross-meeting match threshold (each embedding has its own
# cosine scale, so don't inherit WeSpeaker's 0.60). Measurement only.
#   scripts/run_model_endtoend.sh <model>   [ARMS="clean opus8k g711u"] [MATCH="0.3 .. 0.7"]
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"; BIN="$ROOT/Tools/SpeakerEvalHarness/.build/release/speaker-eval-harness"
MODEL="${1:?model}"; ARMS="${ARMS:-clean opus12k opus8k g711u}"
MATCH="${MATCH:-0.30 0.40 0.45 0.50 0.55 0.60 0.65 0.70}"
for arm in $ARMS; do
  D="$ROOT/data/eval/ami_${arm}__${MODEL}"
  [ -d "$D/dumps" ] || { echo "no dumps for $arm/$MODEL"; continue; }
  INPUTS="$(ls "$D"/dumps/*.json | sort | tr '\n' ',' | sed 's/,$//')"
  mkdir -p "$D/results" "$D/reports"
  echo "### $arm/$MODEL"
  for m in $MATCH; do
    "$BIN" replay --inputs "$INPUTS" --consolidation none --match "$m" --out "$D/results/e2e_$m.json" 2>&1 | grep -vE "\.pcm|while proc" | tail -1
    python3 "$ROOT/scripts/score_speaker_eval.py" --result "$D/results/e2e_$m.json" --rttm-dir "$ROOT/data/ami/rttm" --out-json "$D/reports/e2e_$m.json" >/dev/null 2>&1
  done
done
echo "### E2E DONE ($MODEL)"
