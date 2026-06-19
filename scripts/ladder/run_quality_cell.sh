#!/usr/bin/env bash
# run_quality_cell.sh CORPUS QUALITY [MAX_FILES]
#
# One cell of the corpus × audio-quality matrix:
#   degrade source audio -> QUALITY  ->  dump-batch (real diarizer)  ->  ladder-fingerprints
#   ->  ladder-sweep, tagged <corpus>_<quality>.  Degraded WAVs are deleted after dumping to
#   keep disk bounded; the dump JSON (idempotent) is the durable checkpoint.
#
# MAX_FILES (optional) caps how many source meetings are processed (logged), for big corpora
# like AMI-full / VoxConverse where a full quality matrix would be many hours.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
ROOT="$(pwd)"
CORPUS="${1:?corpus}"; QUALITY="${2:?quality}"; MAX="${3:-0}"
BIN="$ROOT/Tools/SpeakerEvalHarness/.build/release/speaker-eval-harness"
LOG="$ROOT/data/eval/_logs/qmatrix_${CORPUS}_${QUALITY}.log"
mkdir -p "$ROOT/data/eval/_logs"

case "$CORPUS" in
  ami)         SRC="$ROOT/data/ami/audio";               SUF=".Mix-Headset.wav"; RTTM="$ROOT/data/ami/rttm";              NS="" ;;
  ami_scale)   SRC="$ROOT/data/ami_scale/audio";         SUF=".Mix-Headset.wav"; RTTM="$ROOT/data/ami/rttm";              NS="" ;;
  voxceleb)    SRC="$ROOT/data/voxceleb/sessions/audio";  SUF=".wav";             RTTM="$ROOT/data/voxceleb/sessions/rttm"; NS="" ;;
  voxconverse) SRC="$ROOT/data/voxconverse/audio";        SUF=".wav";             RTTM="$ROOT/data/voxconverse/rttm";      NS="--namespace-speakers" ;;
  *) echo "unknown corpus $CORPUS" | tee -a "$LOG"; exit 1 ;;
esac

TAG="${CORPUS}_${QUALITY}"
CELL="$ROOT/data/eval/qmatrix/$TAG"
DEG="$CELL/audio"; DUMPS="$CELL/dumps"; FP="$CELL/fingerprints.json"
mkdir -p "$DEG" "$DUMPS" "$CELL/ladder"

ts() { date '+%H:%M:%S'; }
log() { echo "$(ts) [$TAG] $*" | tee -a "$LOG"; }

[ -x "$BIN" ] || { log "harness binary missing"; exit 1; }
[ -d "$SRC" ] || { log "source audio dir missing: $SRC"; exit 1; }

# Optionally cap source files (deterministic subset) for huge corpora.
if [ "$MAX" -gt 0 ]; then
  TMPSRC="$CELL/_srclist"; ls "$SRC"/*"$SUF" 2>/dev/null | sort | head -n "$MAX" > "$TMPSRC"
  STAGED="$CELL/src"; rm -rf "$STAGED"; mkdir -p "$STAGED"
  while read -r f; do ln -sf "$f" "$STAGED/$(basename "$f")"; done < "$TMPSRC"
  SRC="$STAGED"
  log "capped to $MAX source meetings (logged)"
fi

nsrc=$(ls "$SRC"/*"$SUF" 2>/dev/null | wc -l | tr -d ' ')
log "start: $nsrc source meetings, quality=$QUALITY"

# 1. degrade (parallel, CPU)
python3 scripts/ladder/degrade_corpus.py --audio-dir "$SRC" --out-dir "$DEG" \
  --quality "$QUALITY" --suffix "$SUF" >>"$LOG" 2>&1 || { log "degrade FAILED"; exit 1; }

# 2. dump-batch (real diarizer; idempotent)
"$BIN" dump-batch --audio-dir "$DEG" --out-dir "$DUMPS" --suffix .wav >>"$LOG" 2>&1 || { log "dump FAILED"; exit 1; }
ndump=$(ls "$DUMPS"/*.json 2>/dev/null | wc -l | tr -d ' ')
log "dumped $ndump meetings"

# 3. free disk: degraded WAVs no longer needed
rm -rf "$DEG"; rm -rf "$CELL/src" 2>/dev/null

# 4. fingerprints (uses ORIGINAL rttm; ground truth is quality-independent)
"$BIN" ladder-fingerprints --dumps "$DUMPS" --rttm "$RTTM" --corpus "$TAG" --out "$FP" $NS >>"$LOG" 2>&1 \
  || { log "fingerprints FAILED"; exit 1; }

# 5. sweep
"$BIN" ladder-sweep --fingerprints "$FP" --corpus "$TAG" --out-dir "$CELL/ladder" >>"$LOG" 2>&1 \
  || { log "sweep FAILED"; exit 1; }

log "DONE -> $CELL/ladder/ladder_policies_${TAG}.csv"
