#!/bin/bash
# SAMPLE-ONLY VoxCeleb1 fetch + synthetic multi-identity session build.
#
# VoxCeleb1: CC-BY-SA 4.0 (https://www.robots.ox.ac.uk/~vgg/data/voxceleb/). ~1200
# identities — we NEVER pull all of it. This streams a HF mirror and stops at a HARD CAP
# of distinct identities, then stitches them into conversational sessions with exact RTTMs
# for the cross-recording re-ID / false-positive test. Everything under data/voxceleb/
# (gitignored).
#
# GATED TIER — VoxCeleb on HF is access-gated: `huggingface-cli login` (or HF_TOKEN) +
# accept terms, and `pip install datasets soundfile`. Footprint is bounded by the cap
# (default 300 ids × 10 clips ≈ a few GB streamed, NOT the full ~30 GB corpus).
#
# Env knobs:
#   VOXCELEB_IDENTITY_CAP   distinct identities to sample (default 300; HARD CAP, max 1211)
#   VOXCELEB_CLIPS_PER_ID   clips kept per identity (default 10)
#   VOXCELEB_SESSIONS       synthetic sessions to build (default 20)
#   VOXCELEB_SPK_PER_SESS   identities per session (default 4)
#
# One-liner:
#   scripts/download_voxceleb_sample.sh
#   VOXCELEB_IDENTITY_CAP=50 scripts/download_voxceleb_sample.sh   # tiny smoke sample
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="data/voxceleb"
RAW="$DEST/raw"
CAP="${VOXCELEB_IDENTITY_CAP:-300}"
CLIPS="${VOXCELEB_CLIPS_PER_ID:-10}"
SESSIONS="${VOXCELEB_SESSIONS:-20}"
SPK="${VOXCELEB_SPK_PER_SESS:-4}"

echo "[voxceleb] HARD CAP = $CAP identities × $CLIPS clips (sample-only; never the full corpus)"
python3 scripts/voxceleb_sample.py --out-dir "$RAW" \
  --identity-cap "$CAP" --clips-per-id "$CLIPS"

echo "[voxceleb] building $SESSIONS synthetic sessions ($SPK identities each)..."
python3 scripts/build_voxceleb_sessions.py --raw-dir "$RAW" \
  --out-dir "$DEST/sessions" --num-sessions "$SESSIONS" --speakers-per-session "$SPK"

echo "[voxceleb] done: sessions under $DEST/sessions (audio/ + rttm/)"
