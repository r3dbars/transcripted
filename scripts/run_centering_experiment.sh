#!/bin/bash
# Mean-centering matcher experiment (measurement only — no app code touched).
# For each codec arm and centering mode: transform the cached dump embeddings, replay them
# through the REAL clusterer + DB matcher, score vs AMI RTTMs, aggregate. Re-uses the
# already-diarized dumps (no re-encode / re-diarize), so this is fast.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BIN="$ROOT/Tools/SpeakerEvalHarness/.build/release/speaker-eval-harness"
RTTM="$ROOT/data/ami/rttm"
ARMS="${ARMS:-clean opus24k opus16k opus12k opus8k g711u}"
MODES="${MODES:-normonly global running}"
MATCH="${MATCH:-0.40 0.45 0.50 0.55 0.60 0.65 0.70}"

for arm in $ARMS; do
  IN="$ROOT/data/eval/ami_$arm/dumps"
  [ -d "$IN" ] || { echo "!! missing baseline dumps for $arm ($IN)"; continue; }
  for mode in $MODES; do
    OUT="$ROOT/data/eval/ami_${arm}_${mode}"
    mkdir -p "$OUT/dumps" "$OUT/results" "$OUT/reports"
    echo "############ $arm / $mode ############"
    python3 "$ROOT/scripts/center_dumps.py" --in-dumps "$IN" --out-dumps "$OUT/dumps" --mode "$mode" || { echo "center failed"; continue; }
    INPUTS="$(ls "$OUT"/dumps/*.json | sort | tr '\n' ',' | sed 's/,$//')"
    SCORES=""
    for mt in $MATCH; do
      "$BIN" replay --inputs "$INPUTS" --consolidation none --match "$mt" \
        --out "$OUT/results/match_$mt.json" 2>&1 | grep -vE "\.pcm|while processing" | tail -1
      python3 "$ROOT/scripts/score_speaker_eval.py" --result "$OUT/results/match_$mt.json" \
        --rttm-dir "$RTTM" --out-json "$OUT/reports/cons_none_match_$mt.json" >/dev/null
      SCORES="${SCORES:+$SCORES,}$OUT/reports/cons_none_match_$mt.json"
    done
    python3 "$ROOT/scripts/aggregate_sweep.py" --scores "$SCORES" --corpus "ami_${arm}_${mode}" --out-md "$OUT/reports/SWEEP.md" >/dev/null
    python3 "$ROOT/scripts/analyze_ami_codec_bands.py" --dumps "$OUT/dumps" --rttm-dir "$RTTM" --tag "${arm}_${mode}" --out-json "$OUT/reports/bands.json" >/dev/null
    echo "### $arm/$mode done"
  done
done
echo "### CENTERING EXPERIMENT DONE"
