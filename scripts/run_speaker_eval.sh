#!/bin/bash
# Re-runnable speaker-naming eval against ground-truth RTTMs — ANY corpus, one driver.
#
#   1. build the harness (reuses prebuilt deps under deps-libs/ etc.)
#   2. dump-diarize each session once (cached in data/eval/<CORPUS>/dumps/)
#   3. replay the sessions IN ORDER through the real clusterer + DB matcher
#      for every (consolidation × match) threshold combo
#   4. score each combo vs the RTTMs (DER, fragmentation, false-merge, re-ID curve)
#      and aggregate a sweep table
#
# The CORPUS env var selects the dataset; everything else (dump -> sweep -> score) is shared.
# Each corpus just needs WAVs in its audio dir and matching <meeting>.rttm in its rttm dir,
# fetched by the per-corpus downloader (download_ami.sh / download_icsi.sh /
# download_voxconverse.sh / download_voxceleb_sample.sh).
#
# Usage:
#   scripts/run_speaker_eval.sh                              # CORPUS=ami, all downloaded RTTMs
#   CORPUS=ami SERIES="ES2002a ES2002b ES2002c ES2002d" scripts/run_speaker_eval.sh
#   CORPUS=voxconverse scripts/run_speaker_eval.sh
#   CORPUS=voxceleb scripts/run_speaker_eval.sh             # synthetic re-ID/false-positive sessions
#   CONSOLIDATION="none 0.85 0.88" MATCH="0.55 0.6 0.65" scripts/run_speaker_eval.sh
#
# Env knobs: CORPUS, SERIES (subset; default = all meetings with RTTMs), CONSOLIDATION,
#            MATCH, COLLAR.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

CORPUS="${CORPUS:-ami}"

# ---- per-corpus layout: audio dir, rttm dir, audio filename suffix ----
case "$CORPUS" in
  ami)         AUDIO_DIR="data/ami/audio";              RTTM_DIR="data/ami/rttm";              SUFFIX=".Mix-Headset.wav" ;;
  icsi)        AUDIO_DIR="data/icsi/audio";             RTTM_DIR="data/icsi/rttm";             SUFFIX=".wav" ;;
  voxconverse) AUDIO_DIR="data/voxconverse/audio";      RTTM_DIR="data/voxconverse/rttm";      SUFFIX=".wav" ;;
  voxceleb)    AUDIO_DIR="data/voxceleb/sessions/audio"; RTTM_DIR="data/voxceleb/sessions/rttm"; SUFFIX=".wav" ;;
  *) echo "unknown CORPUS='$CORPUS' (ami|icsi|voxconverse|voxceleb)"; exit 2 ;;
esac

# VoxConverse RTTM labels (spk00, spk01, ...) are PER-FILE and reused across files —
# namespace true ids by file so the cross-file overlap matrix doesn't conflate distinct
# people. AMI/ICSI use globally-recurring participant ids; VoxCeleb sessions are built
# with globally-unique ids — those leave it off so cross-meeting re-ID stays meaningful.
PERFILE=""; [ "$CORPUS" = "voxconverse" ] && PERFILE="--per-file-ids"

# Meeting list: explicit SERIES, else every meeting that has an RTTM (sorted -> stable
# replay order; for AMI this keeps each series' a–d consecutive).
if [ -n "${SERIES:-}" ]; then
  MEETINGS="$SERIES"
else
  MEETINGS="$(ls "$ROOT/$RTTM_DIR" 2>/dev/null | sed 's/\.rttm$//' | sort | tr '\n' ' ')"
fi
[ -n "${MEETINGS// /}" ] || { echo "no meetings found for CORPUS=$CORPUS (run the downloader first; looked in $RTTM_DIR)"; exit 1; }

# Sweep grids — consolidation around the 0.88 same-voice bar, match around 0.6.
CONSOLIDATION="${CONSOLIDATION:-none 0.82 0.85 0.88 0.91}"
MATCH="${MATCH:-0.50 0.55 0.60 0.65 0.70}"
COLLAR="${COLLAR:-0.25}"

BIN="$ROOT/Tools/SpeakerEvalHarness/.build/release/speaker-eval-harness"
DUMPS="$ROOT/data/eval/$CORPUS/dumps"
RESULTS="$ROOT/data/eval/$CORPUS/results"
REPORTS="$ROOT/data/eval/$CORPUS/reports"
mkdir -p "$DUMPS" "$RESULTS" "$REPORTS"

echo "==> CORPUS=$CORPUS  meetings=$(echo "$MEETINGS" | wc -w | tr -d ' ')  (audio=$AUDIO_DIR rttm=$RTTM_DIR)"

echo "==> build harness"
( cd "$ROOT/Tools/SpeakerEvalHarness" && swift build -c release 2>&1 | grep -vE "\.pcm|while processing" | tail -1 )

echo "==> dump-diarize sessions (cached)"
INPUTS=""
for m in $MEETINGS; do
  dump="$DUMPS/$m.json"
  audio="$ROOT/$AUDIO_DIR/$m$SUFFIX"
  if [ ! -s "$dump" ]; then
    if [ ! -s "$audio" ]; then echo "    !! missing audio $audio — skipping $m" >&2; continue; fi
    echo "    diarizing $m ..."
    "$BIN" dump --audio "$audio" --meeting "$m" --out "$dump" \
      2>&1 | grep -E "^\[dump\] $m:" | grep -v processing || true
  else
    echo "    cached $m"
  fi
  [ -s "$dump" ] && INPUTS="${INPUTS:+$INPUTS,}$dump"
done
[ -n "$INPUTS" ] || { echo "no dumps produced — check audio files"; exit 1; }

echo "==> threshold sweep (consolidation × match)"
SWEEP_JSONS=""
for cons in $CONSOLIDATION; do
  for mt in $MATCH; do
    tag="cons_${cons}_match_${mt}"
    res="$RESULTS/$tag.json"
    score="$REPORTS/$tag.json"
    "$BIN" replay --inputs "$INPUTS" --consolidation "$cons" --match "$mt" --out "$res" \
      2>&1 | grep -vE "\.pcm|while processing" | tail -1
    python3 "$ROOT/scripts/score_speaker_eval.py" --result "$res" --rttm-dir "$ROOT/$RTTM_DIR" \
      --collar "$COLLAR" $PERFILE --out-json "$score" >/dev/null
    SWEEP_JSONS="${SWEEP_JSONS:+$SWEEP_JSONS,}$score"
  done
done

echo "==> aggregate"
python3 "$ROOT/scripts/aggregate_sweep.py" --scores "$SWEEP_JSONS" --corpus "$CORPUS" \
  --out-md "$REPORTS/SWEEP.md"
echo "==> wrote $REPORTS/SWEEP.md"
