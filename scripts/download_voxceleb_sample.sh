#!/bin/bash
# SAMPLE-ONLY VoxCeleb1 fetch + multi-identity "session" build for the speaker-DB test.
#
# VoxCeleb1: CC-BY-SA 4.0 (https://www.robots.ox.ac.uk/~vgg/data/voxceleb/). ~1200
# identities — we NEVER pull all of it. This STREAMS a HF mirror and stops at a HARD CAP
# of distinct identities. Default mirror `s3prl/mini_voxceleb1` is PUBLIC (no HF login);
# point VOXCELEB_DATASET at a larger/gated mirror to exceed mini's identity count.
# Everything under data/voxceleb/ (gitignored).
#
# Needs `pip install datasets` + `ffmpeg` (audio read via fsspec, transcoded by ffmpeg —
# no torch/soundfile). Footprint bounded by the cap, NOT the full ~30 GB corpus.
#
# MODE (why singles is the default): `singles` makes each clip its own single-speaker
# "meeting", so the diarizer trivially sees one clean voice and the eval isolates the DB
# MATCHER (cross-recording re-ID / false-positive). `sessions` stitches clips into
# multi-speaker recordings — more realistic, but it routes through the diarizer, whose
# under-segmentation then dominates the metric (measured: it collapses 4 voices to 1–2
# clusters), re-introducing the AMI confound. Use singles to test the matcher; sessions
# to stress the whole pipeline.
#
# Env knobs:
#   VOXCELEB_IDENTITY_CAP   distinct identities to sample (default 300; HARD CAP, max 1211)
#   VOXCELEB_CLIPS_PER_ID   clips kept per identity (default 10)
#   VOXCELEB_DATASET        HF mirror (default s3prl/mini_voxceleb1, public)
#   VOXCELEB_MODE           singles | sessions (default singles)
#   VOXCELEB_SESSIONS       sessions-mode: # sessions to build (default 20)
#   VOXCELEB_SPK_PER_SESS   sessions-mode: identities per session (default 4)
#
# One-liner:
#   scripts/download_voxceleb_sample.sh                              # 300-cap, singles
#   VOXCELEB_IDENTITY_CAP=6 scripts/download_voxceleb_sample.sh      # tiny smoke sample
#   VOXCELEB_MODE=sessions scripts/download_voxceleb_sample.sh       # multi-speaker sessions
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="data/voxceleb"
RAW="$DEST/raw"
CAP="${VOXCELEB_IDENTITY_CAP:-300}"
CLIPS="${VOXCELEB_CLIPS_PER_ID:-10}"
DATASET="${VOXCELEB_DATASET:-s3prl/mini_voxceleb1}"
MODE="${VOXCELEB_MODE:-singles}"
SESSIONS="${VOXCELEB_SESSIONS:-20}"
SPK="${VOXCELEB_SPK_PER_SESS:-4}"

echo "[voxceleb] HARD CAP = $CAP identities × $CLIPS clips from $DATASET (sample-only; never the full corpus)"
python3 scripts/voxceleb_sample.py --out-dir "$RAW" \
  --identity-cap "$CAP" --clips-per-id "$CLIPS" --dataset "$DATASET"

echo "[voxceleb] building '$MODE' meetings..."
python3 scripts/build_voxceleb_sessions.py --raw-dir "$RAW" \
  --out-dir "$DEST/sessions" --mode "$MODE" \
  --num-sessions "$SESSIONS" --speakers-per-session "$SPK"

echo "[voxceleb] done: meetings under $DEST/sessions (audio/ + rttm/). Run: CORPUS=voxceleb scripts/run_speaker_eval.sh"
