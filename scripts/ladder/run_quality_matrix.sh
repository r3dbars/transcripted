#!/usr/bin/env bash
# run_quality_matrix.sh — drive a corpus × audio-quality matrix.
#
# Diarization is GPU-bound and does NOT parallelize (measured: 3 concurrent dump processes
# gave ~0% speedup and paid 3× model loads), so cells run SERIALLY for the dump stage. Per
# cell, degradation is CPU-parallel internally and degraded WAVs are deleted after dumping.
#
# Usage:
#   run_quality_matrix.sh CORPUS [MAX_FILES] [-- q1 q2 ...]
#   QUALITIES env overrides the default quality list.
# Examples:
#   run_quality_matrix.sh voxceleb
#   run_quality_matrix.sh ami
#   MAX_FILES=60 run_quality_matrix.sh voxconverse 60 -- orig mp3_32 opus_8k tel_g711 noisy_snr5
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
ROOT="$(pwd)"
CORPUS="${1:?corpus}"; shift || true
MAX=0
if [ "${1:-}" != "" ] && [ "${1:-}" != "--" ]; then MAX="$1"; shift || true; fi
[ "${1:-}" = "--" ] && shift || true

DEFAULT_Q="orig mp3_64 mp3_32 mp3_16 opus_16k opus_8k aac_32 tel_g711 noisy_snr10 noisy_snr5 reverb"
if [ "$#" -gt 0 ]; then QLIST="$*"; else QLIST="${QUALITIES:-$DEFAULT_Q}"; fi

LOG="$ROOT/data/eval/_logs/qmatrix_${CORPUS}_driver.log"
mkdir -p "$ROOT/data/eval/_logs"
echo "$(date '+%F %T') [matrix:$CORPUS] qualities: $QLIST  max=$MAX" | tee -a "$LOG"

t0=$(date +%s)
for q in $QLIST; do
  echo "$(date '+%T') [matrix:$CORPUS] === cell $CORPUS/$q ===" | tee -a "$LOG"
  bash scripts/ladder/run_quality_cell.sh "$CORPUS" "$q" "$MAX" 2>&1 | tail -1 | tee -a "$LOG"
done
echo "$(date '+%F %T') [matrix:$CORPUS] ALL DONE in $(( ($(date +%s) - t0) / 60 ))min" | tee -a "$LOG"
