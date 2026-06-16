#!/bin/bash
# Download AMI ES2002 scenario series (a/b/c/d) — Mix-Headset audio + ground-truth RTTMs.
# AMI Meeting Corpus: research-use license (https://groups.inf.ed.ac.uk/ami/corpus/).
# Internal eval only — NOT redistributed. Everything lands under data/ami/ (gitignored).
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="data/ami"
mkdir -p "$DEST/audio" "$DEST/rttm"
SERIES="${1:-ES2002a ES2002b ES2002c ES2002d}"
AUDIO_BASE="http://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus"
RTTM_BASE="https://raw.githubusercontent.com/pyannote/AMI-diarization-setup/main/only_words/rttms/train"
for m in $SERIES; do
  echo "[ami] $m audio..."
  curl -fsSL --retry 3 -o "$DEST/audio/$m.Mix-Headset.wav" "$AUDIO_BASE/$m/audio/$m.Mix-Headset.wav"
  echo "[ami] $m rttm..."
  curl -fsSL --retry 3 -o "$DEST/rttm/$m.rttm" "$RTTM_BASE/$m.rttm" \
    || curl -fsSL --retry 3 -o "$DEST/rttm/$m.rttm" "${RTTM_BASE/train/dev}/$m.rttm"
done
echo "[ami] done."
ls -la "$DEST/audio" "$DEST/rttm"
