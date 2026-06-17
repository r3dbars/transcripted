#!/bin/bash
# Online-centering estimator sweep (measurement only — additive, no app code touched).
# Q2: does a better ONLINE/causal centering approach the oracle 'global'?
# For opus12k & opus8k: running EMA at alpha in {0.005,0.01,0.02} + frozen-warmup.
# center -> replay (match 0.55/0.60/0.65) -> score -> bands. Outputs to a tmp tree.
set -uo pipefail
ROOT="/Users/redbars/transcripted/.claude/worktrees/objective-noyce-06bac2"
BIN="$ROOT/Tools/SpeakerEvalHarness/.build/release/speaker-eval-harness"
RTTM="$ROOT/data/ami/rttm"
TMP="$ROOT/data/eval/_online_sweep"
ARMS="opus12k opus8k"
MATCH="0.55 0.60 0.65"

run_cfg () {
  local arm="$1" label="$2" mode="$3" alpha="$4"
  local IN="$ROOT/data/eval/ami_$arm/dumps"
  local OUT="$TMP/${arm}__${label}"
  mkdir -p "$OUT/dumps" "$OUT/results" "$OUT/reports"
  echo "############ $arm / $label (mode=$mode alpha=$alpha) ############"
  if [ "$mode" = "running" ]; then
    python3 "$ROOT/scripts/center_dumps.py" --in-dumps "$IN" --out-dumps "$OUT/dumps" --mode running --alpha "$alpha" || { echo "center failed"; return; }
  else
    python3 "$ROOT/scripts/center_dumps.py" --in-dumps "$IN" --out-dumps "$OUT/dumps" --mode "$mode" || { echo "center failed"; return; }
  fi
  local INPUTS
  INPUTS="$(ls "$OUT"/dumps/*.json | sort | tr '\n' ',' | sed 's/,$//')"
  for mt in $MATCH; do
    "$BIN" replay --inputs "$INPUTS" --consolidation none --match "$mt" \
      --out "$OUT/results/match_$mt.json" 2>&1 | grep -vE "\.pcm|while processing" | tail -1
    python3 "$ROOT/scripts/score_speaker_eval.py" --result "$OUT/results/match_$mt.json" \
      --rttm-dir "$RTTM" --out-json "$OUT/reports/cons_none_match_$mt.json" >/dev/null 2>&1
  done
  python3 "$ROOT/scripts/analyze_ami_codec_bands.py" --dumps "$OUT/dumps" --rttm-dir "$RTTM" \
    --tag "${arm}_${label}" --out-json "$OUT/reports/bands.json" >/dev/null 2>&1
  echo "### $arm/$label done"
}

for arm in $ARMS; do
  run_cfg "$arm" "running_a0.005" running 0.005
  run_cfg "$arm" "running_a0.01"  running 0.01
  run_cfg "$arm" "running_a0.02"  running 0.02
  run_cfg "$arm" "frozen"         frozen  0
done
echo "### ONLINE CENTERING SWEEP DONE"
