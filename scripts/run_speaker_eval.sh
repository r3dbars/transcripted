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
#            MATCH, COLLAR, ALLOW_PARTIAL_CORPUS=1.
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
ALLOW_PARTIAL_CORPUS="${ALLOW_PARTIAL_CORPUS:-0}"

BIN="$ROOT/Tools/SpeakerEvalHarness/.build/release/speaker-eval-harness"
DUMPS="$ROOT/data/eval/$CORPUS/dumps"
RESULTS="$ROOT/data/eval/$CORPUS/results"
REPORTS="$ROOT/data/eval/$CORPUS/reports"
mkdir -p "$DUMPS" "$RESULTS" "$REPORTS"

echo "==> CORPUS=$CORPUS  meetings=$(echo "$MEETINGS" | wc -w | tr -d ' ')  (audio=$AUDIO_DIR rttm=$RTTM_DIR)"

usable_meetings=()
missing_inputs=()
for m in $MEETINGS; do
  audio="$ROOT/$AUDIO_DIR/$m$SUFFIX"
  rttm="$ROOT/$RTTM_DIR/$m.rttm"
  if [ ! -s "$rttm" ]; then
    missing_inputs+=("missing RTTM $rttm")
    continue
  fi
  if [ ! -s "$audio" ]; then
    missing_inputs+=("missing audio $audio")
    continue
  fi
  usable_meetings+=("$m")
done

if [ "${#missing_inputs[@]}" -gt 0 ]; then
  printf '    !! %s\n' "${missing_inputs[@]}" >&2
  if [ "$ALLOW_PARTIAL_CORPUS" != "1" ]; then
    echo "Partial corpus refused. Fetch the missing inputs or rerun with ALLOW_PARTIAL_CORPUS=1 for local iteration only." >&2
    exit 1
  fi
  echo "    !! continuing with partial corpus because ALLOW_PARTIAL_CORPUS=1" >&2
fi
[ "${#usable_meetings[@]}" -gt 0 ] || { echo "no complete audio+RTTM meetings found for CORPUS=$CORPUS"; exit 1; }

echo "==> build harness"
( cd "$ROOT/Tools/SpeakerEvalHarness" && swift build -c release 2>&1 | grep -vE "\.pcm|while processing" | tail -1 )

echo "==> dump-diarize sessions (cached)"
INPUTS=""
dump_failures=()
for m in "${usable_meetings[@]}"; do
  dump="$DUMPS/$m.json"
  audio="$ROOT/$AUDIO_DIR/$m$SUFFIX"
  if [ ! -s "$dump" ]; then
    echo "    diarizing $m ..."
    "$BIN" dump --audio "$audio" --meeting "$m" --out "$dump" \
      2>&1 | grep -E "^\[dump\] $m:" | grep -v processing || true
  else
    echo "    cached $m"
  fi
  if [ -s "$dump" ]; then
    INPUTS="${INPUTS:+$INPUTS,}$dump"
  else
    dump_failures+=("dump failed or produced empty output for $m")
  fi
done
if [ "${#dump_failures[@]}" -gt 0 ]; then
  printf '    !! %s\n' "${dump_failures[@]}" >&2
  if [ "$ALLOW_PARTIAL_CORPUS" != "1" ]; then
    echo "Partial corpus refused after dump failures. Fix the dump errors or rerun with ALLOW_PARTIAL_CORPUS=1 for local iteration only." >&2
    exit 1
  fi
  echo "    !! continuing after dump failures because ALLOW_PARTIAL_CORPUS=1" >&2
fi
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
      --collar "$COLLAR" --out-json "$score" >/dev/null
    SWEEP_JSONS="${SWEEP_JSONS:+$SWEEP_JSONS,}$score"
  done
done

echo "==> aggregate"
python3 "$ROOT/scripts/aggregate_sweep.py" --scores "$SWEEP_JSONS" --corpus "$CORPUS" \
  --out-md "$REPORTS/SWEEP.md"
echo "==> wrote $REPORTS/SWEEP.md"
