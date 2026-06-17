#!/bin/bash
# AMI codec re-ID sweep — one compression arm, end to end (measurement only).
#
# Encodes the AMI scale set through a VoIP/telephone codec, diarizes the degraded
# audio with the app's real pipeline, then sweeps the cross-meeting MATCH threshold
# with re-ID scoring (AMI participant ids recur across a meeting series, so re-ID and
# cross-series false-merge are both measurable). The whole point: find the match
# threshold X that best re-identifies a returning speaker WITHOUT fusing strangers,
# and watch how X moves as compression degrades the embeddings.
#
# Usage:
#   scripts/run_ami_codec_sweep.sh <tag> <mode> [bitrate]
#     <tag>     output namespace, e.g. clean, opus24k, opus12k, g711u
#     <mode>    clean | opus | g711u
#     [bitrate] opus bitrate (e.g. 24k, 12k); ignored for clean/g711u
#   MEETINGS="ES2002a ES2002b ..."  subset (default = all RTTMs)
#   MATCH="0.40 0.45 ..."           match grid (default fine 0.40-0.70)
#   CONS="none"                     consolidation grid (default none; 0.88 known inert)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

TAG="${1:?tag}"; MODE="${2:?mode: clean|opus|g711u}"; BR="${3:-}"
CLEAN="$ROOT/data/ami/audio"; RTTM="$ROOT/data/ami/rttm"
AUD="$ROOT/data/ami_codec/$TAG/audio"
DUMPS="$ROOT/data/eval/ami_$TAG/dumps"
RESULTS="$ROOT/data/eval/ami_$TAG/results"
REPORTS="$ROOT/data/eval/ami_$TAG/reports"
BIN="$ROOT/Tools/SpeakerEvalHarness/.build/release/speaker-eval-harness"
mkdir -p "$AUD" "$DUMPS" "$RESULTS" "$REPORTS"

MEETINGS="${MEETINGS:-$(ls "$RTTM" | sed 's/\.rttm$//' | sort | tr '\n' ' ')}"
MATCH="${MATCH:-0.40 0.45 0.50 0.55 0.60 0.65 0.70}"
CONS="${CONS:-none}"
FF="ffmpeg -hide_banner -loglevel error -y"

echo "==> [$TAG] mode=$MODE br=${BR:-n/a} meetings=$(echo $MEETINGS|wc -w|tr -d ' ')  match='$MATCH'"

encode() {  # $1=clean src wav  $2=dest 16k mono wav
  local src="$1" dst="$2" tmp
  case "$MODE" in
    clean) cp -c "$src" "$dst" 2>/dev/null || cp "$src" "$dst" ;;
    opus)  tmp="$AUD/.tmp.opus"
           $FF -i "$src" -c:a libopus -b:a "$BR" -ar 16000 -ac 1 "$tmp"
           $FF -i "$tmp" -ar 16000 -ac 1 -c:a pcm_s16le "$dst"; rm -f "$tmp" ;;
    g711u) tmp="$AUD/.tmp.mulaw.wav"
           $FF -i "$src" -ar 8000 -ac 1 -c:a pcm_mulaw "$tmp"          # narrowband telephone
           $FF -i "$tmp" -ar 16000 -ac 1 -c:a pcm_s16le "$dst"; rm -f "$tmp" ;;
    *) echo "bad mode $MODE"; exit 2 ;;
  esac
}

echo "==> [$TAG] encode + diarize (cached)"
INPUTS=""
for m in $MEETINGS; do
  dump="$DUMPS/$m.json"
  if [ ! -s "$dump" ]; then
    src="$CLEAN/$m.Mix-Headset.wav"
    [ -s "$src" ] || { echo "   !! missing clean $src — skip $m" >&2; continue; }
    wav="$AUD/$m.wav"
    [ -s "$wav" ] || encode "$src" "$wav"
    "$BIN" dump --audio "$wav" --meeting "$m" --out "$dump" 2>&1 | grep -E "^\[dump\] $m:" || true
    # keep dumps (small); drop the decoded wav to save disk (clean keeps originals elsewhere)
    [ -s "$dump" ] && [ "$MODE" != clean ] && rm -f "$wav"
  fi
  [ -s "$dump" ] && INPUTS="${INPUTS:+$INPUTS,}$dump"
done
[ -n "$INPUTS" ] || { echo "[$TAG] no dumps produced"; exit 1; }

echo "==> [$TAG] match sweep (re-ID on; AMI global ids — no --per-file-ids)"
SCORES=""
for cons in $CONS; do
  for mt in $MATCH; do
    tag="cons_${cons}_match_${mt}"
    "$BIN" replay --inputs "$INPUTS" --consolidation "$cons" --match "$mt" \
      --out "$RESULTS/$tag.json" 2>&1 | grep -vE "\.pcm|while processing" | tail -1
    python3 "$ROOT/scripts/score_speaker_eval.py" --result "$RESULTS/$tag.json" \
      --rttm-dir "$RTTM" --out-json "$REPORTS/$tag.json" >/dev/null
    SCORES="${SCORES:+$SCORES,}$REPORTS/$tag.json"
  done
done

echo "==> [$TAG] aggregate + bands"
python3 "$ROOT/scripts/aggregate_sweep.py" --scores "$SCORES" --corpus "ami_$TAG" --out-md "$REPORTS/SWEEP.md" >/dev/null
python3 "$ROOT/scripts/analyze_ami_codec_bands.py" --dumps "$DUMPS" --rttm-dir "$RTTM" --tag "$TAG" --out-json "$REPORTS/bands.json" >/dev/null
echo "==> [$TAG] done -> $REPORTS/SWEEP.md , bands.json"
