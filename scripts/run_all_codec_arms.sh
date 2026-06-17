#!/bin/bash
# Drive all AMI codec arms end to end (measurement only). Sequential by design — one
# diarizer process at a time avoids Neural-Engine contention; the per-arm dumps cache,
# so re-runs are cheap. Brackets real usage: clean -> Opus wideband (Zoom/Meet) ->
# narrowband telephone (G.711). ~1.5-2h cold for 32 meetings x 6 arms.
set -uo pipefail
cd "$(dirname "$0")/.."
export MATCH="${MATCH:-0.40 0.45 0.50 0.55 0.60 0.65 0.70}"
export CONS="${CONS:-none}"

# tag        mode    bitrate   (real-world analogue)
ARMS=(
  "clean    clean   -"        # control: pristine 16 kHz headset
  "opus24k  opus    24k"      # Zoom/Meet typical wideband
  "opus16k  opus    16k"      # Zoom low / Meet
  "opus12k  opus    12k"      # aggressive VoIP (the BASELINE point)
  "opus8k   opus    8k"       # very aggressive VoIP
  "g711u    g711u   -"        # PSTN / narrowband telephone (8 kHz mu-law)
)

echo "### codec arms run start | match='$MATCH' cons='$CONS'"
for row in "${ARMS[@]}"; do
  set -- $row; tag="$1"; mode="$2"; br="$3"
  echo; echo "############ ARM $tag (mode=$mode br=$br) ############"
  if bash scripts/run_ami_codec_sweep.sh "$tag" "$mode" "$br"; then
    echo "### ARM $tag OK"
  else
    echo "### ARM $tag FAILED (continuing)"
  fi
done
echo; echo "### ALL ARMS DONE"
ls -d data/eval/ami_*/reports/SWEEP.md 2>/dev/null
