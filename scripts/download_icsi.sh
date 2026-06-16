#!/bin/bash
# Download ICSI Meeting Corpus subsets — interaction-mix audio + ground-truth RTTMs.
#
# ICSI Meeting Corpus: research-use license (https://groups.inf.ed.ac.uk/ami/icsi/,
# license at .../icsi/license.shtml). 75 meetings of the same lab's research groups, so
# speakers RECUR heavily across meetings (global IDs like mn005/fe008) — a strong
# cross-meeting re-ID surface with real, varied identities. NOT redistributed.
# Everything lands under data/icsi/ (gitignored).
#
#   - Audio : Edinburgh ICSIsignals mirror, beamformed interaction mix (no auth).
#             https://groups.inf.ed.ac.uk/ami/ICSIsignals/NXT/<MTG>.interaction.wav
#   - RTTMs : HF dataset `diarizers-community/icsi` (diarization-ready ground truth).
#             GATED: needs `huggingface-cli login` + accepting the dataset terms, plus
#             `pip install datasets soundfile`. Materialized to loose <MTG>.rttm by
#             scripts/icsi_rttm_from_hf.py.
#
# GATED HEAVY TIER — interaction WAVs are ~70–190 MB each (long meetings). Wire it,
# don't run it blind. One-liners:
#   scripts/download_icsi.sh                       # default 6-meeting sample
#   ICSI_SET="Bmr001 Bmr002 Bmr005 Bro003 Bro004"  scripts/download_icsi.sh
#   ICSI_SET=full scripts/download_icsi.sh         # all 75 meetings (~10 GB)
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="data/icsi"
mkdir -p "$DEST/audio" "$DEST/rttm"

AUDIO_BASE="https://groups.inf.ed.ac.uk/ami/ICSIsignals/NXT"

# Default sample: two Bmr-series + Bro/Bed/Bns/Btr meetings — overlapping attendee pools
# so the same researchers recur across recordings.
DEFAULT_SAMPLE="Bmr001 Bmr002 Bro003 Bed002 Bns001 Btr001"
# The 75-meeting ICSI list (Bdb/Bed/Bmr/Bns/Bro/Bsr/Btr/Buw families).
FULL_LIST="Bdb001 Bed002 Bed003 Bed004 Bed005 Bed006 Bed008 Bed009 Bed010 Bed011 Bed012 \
Bed013 Bed014 Bed015 Bed016 Bed017 Bmr001 Bmr002 Bmr003 Bmr005 Bmr006 Bmr007 Bmr008 Bmr009 \
Bmr010 Bmr011 Bmr012 Bmr013 Bmr014 Bmr015 Bmr016 Bmr018 Bmr019 Bmr020 Bmr021 Bmr022 Bmr023 \
Bmr024 Bmr025 Bmr026 Bmr027 Bmr029 Bmr030 Bmr031 Bns001 Bns002 Bns003 Bro003 Bro004 Bro005 \
Bro007 Bro008 Bro010 Bro011 Bro012 Bro013 Bro014 Bro015 Bro016 Bro017 Bro018 Bro019 Bro021 \
Bro022 Bro023 Bro024 Bro025 Bro026 Bro027 Bro028 Bsr001 Btr001 Btr002 Buw001"

ARG="${1:-${ICSI_SET:-sample}}"
case "$ARG" in
  sample) MEETINGS="$DEFAULT_SAMPLE" ;;
  full)   MEETINGS="$FULL_LIST" ;;
  *)      MEETINGS="$*" ;;
esac
echo "[icsi] set='$ARG' -> $(echo "$MEETINGS" | wc -w | tr -d ' ') meeting(s)"

for m in $MEETINGS; do
  wav="$DEST/audio/$m.wav"
  if [ ! -s "$wav" ]; then
    echo "[icsi] $m audio..."
    curl -fsSL --retry 3 -o "$wav" "$AUDIO_BASE/$m.interaction.wav" \
      || { echo "[icsi] !! audio fetch failed for $m" >&2; rm -f "$wav"; }
  fi
done

echo "[icsi] materializing RTTMs from HF diarizers-community/icsi (needs HF auth + datasets)..."
python3 scripts/icsi_rttm_from_hf.py --out-dir "$DEST/rttm" --meetings "$MEETINGS" \
  || echo "[icsi] !! RTTM step skipped/failed — see scripts/icsi_rttm_from_hf.py header for auth setup" >&2

echo "[icsi] done: $(ls "$DEST/audio" 2>/dev/null | wc -l | tr -d ' ') audio, $(ls "$DEST/rttm" 2>/dev/null | wc -l | tr -d ' ') rttm under $DEST"
