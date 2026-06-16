#!/bin/bash
# Download AMI Meeting Corpus subsets — Mix-Headset audio + ground-truth RTTMs.
#
# AMI Meeting Corpus: research-use license (https://groups.inf.ed.ac.uk/ami/corpus/).
# Ground-truth RTTMs: pyannote/AMI-diarization-setup `only_words` set
# (https://github.com/pyannote/AMI-diarization-setup, MIT-licensed tooling over the
# AMI annotations). Internal eval only — NOT redistributed. Everything lands under
# data/ami/ (gitignored).
#
# AMI speaker IDs are GLOBALLY UNIQUE per real person (FEE005, MEE006, ...). Within a
# scenario series the same 4 people recur across sessions a–d; different series are
# different people. So a multi-series pull yields many distinct *recurring* identities
# — ideal for the cross-meeting re-ID / false-positive test.
#
# Usage:
#   scripts/download_ami.sh                 # default: ES2002 a–d  (4 meetings, 1 group)
#   scripts/download_ami.sh scale           # 8 scenario series   (~32 meetings, ~32 ids)
#   scripts/download_ami.sh full            # ALL scenario+non-scenario (~170 meetings, ~100h)
#   scripts/download_ami.sh ES2002a ES2003a # explicit meeting ids
#   AMI_SET=scale scripts/download_ami.sh   # same via env
#
# Compute/footprint guide (Mix-Headset 16 kHz mono ≈ 1.7 MB/audio-min):
#   default  4 meetings  ~230 MB   download minutes
#   scale   32 meetings  ~1.8 GB   download ~tens of min on the Edinburgh mirror
#   full   ~170 meetings ~9–10 GB  download HOURS — gated heavy tier, do not run blind
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="data/ami"
mkdir -p "$DEST/audio" "$DEST/rttm"

AUDIO_BASE="http://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus"
RTTM_BASE="https://raw.githubusercontent.com/pyannote/AMI-diarization-setup/main/only_words/rttms"
LIST_BASE="https://raw.githubusercontent.com/pyannote/AMI-diarization-setup/main/lists"

# ---- resolve the meeting set ---------------------------------------------------------
expand_series() { for s in "$@"; do for x in a b c d; do printf '%s%s ' "$s" "$x"; done; done; }

ARG="${1:-${AMI_SET:-es2002}}"
case "$ARG" in
  es2002)  MEETINGS="ES2002a ES2002b ES2002c ES2002d" ;;
  # 8 train-split scenario series, 4 disjoint people each -> ~32 distinct recurring ids.
  scale)   MEETINGS="$(expand_series ES2002 ES2003 ES2005 ES2006 ES2007 ES2008 ES2009 ES2010)" ;;
  # Everything pyannote ships RTTMs for (train+dev+test), scenario + non-scenario.
  full)    MEETINGS="$(for sp in train dev test; do \
              curl -fsSL "$LIST_BASE/$sp.meetings.txt"; done | tr '\n' ' ')" ;;
  *)       MEETINGS="$*" ;;   # explicit meeting ids
esac

echo "[ami] set='$ARG' -> $(echo "$MEETINGS" | wc -w | tr -d ' ') meeting(s)"

# ---- fetch -----------------------------------------------------------------------------
for m in $MEETINGS; do
  wav="$DEST/audio/$m.Mix-Headset.wav"
  rttm="$DEST/rttm/$m.rttm"
  if [ ! -s "$wav" ]; then
    echo "[ami] $m audio..."
    curl -fsSL --retry 3 -o "$wav" "$AUDIO_BASE/$m/audio/$m.Mix-Headset.wav" \
      || { echo "[ami] !! audio fetch failed for $m" >&2; rm -f "$wav"; }
  fi
  if [ ! -s "$rttm" ]; then
    echo "[ami] $m rttm..."
    fetched=0
    for sp in train dev test; do
      if curl -fsSL --retry 3 -o "$rttm" "$RTTM_BASE/$sp/$m.rttm" 2>/dev/null; then fetched=1; break; fi
    done
    [ "$fetched" = 1 ] || { echo "[ami] !! rttm not found for $m in train/dev/test" >&2; rm -f "$rttm"; }
  fi
done
echo "[ami] done: $(ls "$DEST/audio" | wc -l | tr -d ' ') audio, $(ls "$DEST/rttm" | wc -l | tr -d ' ') rttm under $DEST"
