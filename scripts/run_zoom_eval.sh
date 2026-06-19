#!/bin/bash
# Validate embedding models on a REAL recording (Zoom/Meet/phone) vs ground-truth labels —
# closes the AMI->real-audio domain gap. Same metrics as the AMI bench (within-meeting
# coverage/DER + cross-call AUC). Measurement only.
#
#   scripts/run_zoom_eval.sh <recording.wav> <ground_truth.rttm> [name] ["model1 model2 ..."]
#
# - recording.wav: any wav (resampled to 16k mono internally). Ideally the SAME captured
#   "system audio" Transcripted records, with 2+ known speakers.
# - ground_truth.rttm: who-spoke-when (see scripts/csv2rttm.py to build it from a CSV).
# - models: default "campplus" (WeSpeaker baseline is always included). e.g. "campplus eres2net ecapa".
set -uo pipefail
cd "$(dirname "$0")/.."
WAV="${1:?recording.wav}"; RTTM="${2:?ground_truth.rttm}"; NAME="${3:-zoom}"; MODELS="${4:-campplus}"
BIN="Tools/SpeakerEvalHarness/.build/release/speaker-eval-harness"
VENV=".venv_emb/bin/python"
RTTMDIR="$(mktemp -d)"; cp "$RTTM" "$RTTMDIR/$NAME.rttm"

BASE="data/eval/zoom_${NAME}/dumps"; mkdir -p "$BASE"
echo "==> diarize $WAV (WeSpeaker baseline)"
[ -s "$BASE/$NAME.json" ] || "$BIN" dump --audio "$WAV" --meeting "$NAME" --out "$BASE/$NAME.json" 2>&1 | grep -E "^\[dump\]" || true
echo; echo "### WeSpeaker (current) on $NAME:"
python3 scripts/model_scorecard.py --arm "$NAME" --dumps "$BASE" --rttm-dir "$RTTMDIR" 2>/dev/null \
  | python3 -c "import json,sys;d=json.load(sys.stdin);w=d['within'];c=d['cross_meeting'];print(f\"  coverage={w['coverage_frac']} DER={w['mean_der']} purity={w['mean_purity']} cross-call-AUC={c['auc_raw']}\")"

for model in $MODELS; do
  OUT="data/eval/zoom_${NAME}_${model}/dumps"; mkdir -p "$OUT"
  echo; echo "==> extract $model embeddings"
  "$VENV" scripts/extract_embeddings.py --arm "$NAME" --model "$model" --base-dumps "$BASE" --audio "$WAV" --out-dir "$OUT" 2>&1 | grep -E "^\[embed\] done" || true
  echo "### $model on $NAME:"
  python3 scripts/model_scorecard.py --arm "$NAME" --dumps "$OUT" --rttm-dir "$RTTMDIR" 2>/dev/null \
    | python3 -c "import json,sys;d=json.load(sys.stdin);w=d['within'];c=d['cross_meeting'];print(f\"  coverage={w['coverage_frac']} DER={w['mean_der']} purity={w['mean_purity']} cross-call-AUC={c['auc_raw']}\")"
done
echo; echo "### done — compare each model's DER/coverage/AUC vs WeSpeaker on YOUR real recording."
