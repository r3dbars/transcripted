#!/bin/bash
# Real-audio robustness campaign for the ERes2Net speaker-embedding path.
# Runs the gated end-to-end test (real PyAnnote+VBx diarizer -> ERes2Net re-embed
# -> SpeakerDatabase match) across several 16kHz wavs and reports per-arm
# pass/fail + the [e2e] summary line. Also runs one file twice to confirm the
# pipeline is deterministic.
#
# Usage: scripts/run_eres2net_e2e_campaign.sh "name:/path/a.wav" "name:/path/b.wav" ...
# With no args, uses the /tmp/ami_e2e_*.wav clips prepared during testing.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

ARMS=("$@")
if [ ${#ARMS[@]} -eq 0 ]; then
  ARMS=(
    "clean_meeting1:/tmp/ami_e2e_90s.wav"
    "clean_meeting2:/tmp/ami_e2e_file2.wav"
    "opus_8kbps:/tmp/ami_e2e_opus8k.wav"
    "g711_phoneband:/tmp/ami_e2e_g711.wav"
    "short_8s:/tmp/ami_e2e_short.wav"
  )
fi

run_arm() {  # $1=wav -> prints the [e2e] line plus the "with N failures" summary
  local wav="$1"
  TRANSCRIPTED_E2E_WAV="$wav" TRANSCRIPTED_DISABLE_FILE_LOGGER=1 \
    swift test --filter ERes2NetDiarizationE2ETests 2>&1 \
    | grep -iE "\[e2e\]|with [0-9]+ failure|error:|XCTSkip" | tail -4
}

pass=0; fail=0
echo "================ ERes2Net real-audio campaign ================"
for entry in "${ARMS[@]}"; do
  name="${entry%%:*}"; wav="${entry#*:}"
  if [ ! -f "$wav" ]; then echo "[$name] SKIP (missing $wav)"; continue; fi
  echo "---- arm: $name ($wav) ----"
  out="$(run_arm "$wav")"
  echo "$out"
  if echo "$out" | grep -qiE "0 failures"; then pass=$((pass+1)); else fail=$((fail+1)); fi
done

echo "---- determinism: clean_meeting1 run twice ----"
a="$(run_arm /tmp/ami_e2e_90s.wav | grep -i '\[e2e\]')"
b="$(run_arm /tmp/ami_e2e_90s.wav | grep -i '\[e2e\]')"
echo "run A: $a"
echo "run B: $b"
[ "$a" = "$b" ] && echo "DETERMINISTIC: identical segment/speaker/dim summary" || { echo "WARN: runs differ"; fail=$((fail+1)); }

echo "================ campaign done: $pass passed, $fail failed ================"
exit "$fail"
