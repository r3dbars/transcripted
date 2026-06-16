#!/bin/bash
# Download VoxConverse (in-the-wild multi-speaker diarization) — audio + ground-truth RTTMs.
#
# VoxConverse: CC-BY 4.0 (https://www.robots.ox.ac.uk/~vgg/data/voxconverse/).
#   - Audio  : official KAIST mirror, dev + test WAV zips.
#   - RTTMs  : github.com/joonson/voxconverse (dev/ + test/ .rttm).
# In-the-wild YouTube audio: overlapping speech, varied recording conditions, unknown
# speaker counts — the hardest diarizer stress + a clean re-ID/false-positive surface.
# Everything lands under data/voxconverse/ (gitignored).
#
# GATED HEAVY TIER — ~4 GB download. Wire it, don't run it blind. One-liner:
#   scripts/download_voxconverse.sh            # dev (216 files) + test (232 files)
#   VOXCONVERSE_SPLITS="dev" scripts/download_voxconverse.sh   # dev only (~2 GB)
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="data/voxconverse"
mkdir -p "$DEST/audio" "$DEST/rttm" "$DEST/_tmp"

SPLITS="${VOXCONVERSE_SPLITS:-dev test}"
AUDIO_BASE="https://mm.kaist.ac.kr/datasets/voxconverse/data"
RTTM_TARBALL="https://github.com/joonson/voxconverse/archive/refs/heads/master.tar.gz"

echo "[vox] fetching ground-truth RTTMs (joonson/voxconverse)..."
curl -fsSL --retry 3 -o "$DEST/_tmp/vc.tar.gz" "$RTTM_TARBALL"
tar -xzf "$DEST/_tmp/vc.tar.gz" -C "$DEST/_tmp"
for sp in $SPLITS; do
  if [ -d "$DEST/_tmp/voxconverse-master/$sp" ]; then
    cp "$DEST/_tmp/voxconverse-master/$sp"/*.rttm "$DEST/rttm/" 2>/dev/null || true
  fi
done
echo "[vox] rttm files: $(ls "$DEST/rttm" | wc -l | tr -d ' ')"

for sp in $SPLITS; do
  zip="$DEST/_tmp/voxconverse_${sp}_wav.zip"
  echo "[vox] $sp audio zip..."
  curl -fsSL --retry 3 -o "$zip" "$AUDIO_BASE/voxconverse_${sp}_wav.zip"
  echo "[vox] $sp extracting..."
  unzip -oq "$zip" -d "$DEST/_tmp/${sp}_extract"
  # zips extract to .../audio/<id>.wav — flatten into data/voxconverse/audio/
  find "$DEST/_tmp/${sp}_extract" -name '*.wav' -exec cp {} "$DEST/audio/" \;
done

rm -rf "$DEST/_tmp"
echo "[vox] done: $(ls "$DEST/audio" | wc -l | tr -d ' ') audio, $(ls "$DEST/rttm" | wc -l | tr -d ' ') rttm under $DEST"
