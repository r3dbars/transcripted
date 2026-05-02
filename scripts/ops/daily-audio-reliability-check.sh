#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_ROOT="${TRANSCRIPTED_REPRO_LAB_SKILL:-${HOME}/.codex/skills/transcripted-repro-lab}"
COLLECT_SCRIPT="${SKILL_ROOT}/scripts/collect_repro_logs.sh"
RUN_ID="${TRANSCRIPTED_AUDIO_RUN_ID:-audio-daily-$(date +%Y%m%d-%H%M%S)}"
OUT_ROOT="${TRANSCRIPTED_AUDIO_RELIABILITY_OUT:-/tmp/transcripted-repro-lab}"
OUT="${OUT_ROOT}/${RUN_ID}"
REPORT="${OUT}/daily-audio-reliability-report.md"
ANSWERS="${OUT}/operator-answers.tsv"
DO_BUILD=1
DO_LAUNCH=1

usage() {
  cat <<'USAGE'
Usage: bash run-daily-audio-reliability.sh [--skip-build] [--no-launch]

Runs the daily Transcripted audio reliability checklist and writes a local report
under /tmp/transcripted-repro-lab/<run-id>/.

Options:
  --skip-build   Do not run bash build.sh before the manual checks.
  --no-launch    Do not kill/relaunch Transcripted automatically.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      DO_BUILD=0
      shift
      ;;
    --no-launch)
      DO_LAUNCH=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

mkdir -p "${OUT}/scenario-logs"
: > "${ANSWERS}"

prompt() {
  local label="$1"
  local answer

  printf "%s " "${label}" >&2
  if ! IFS= read -r answer; then
    answer="skip"
  fi
  printf "%s" "${answer}"
}

prompt_pass_fail() {
  local scenario="$1"
  local question="$2"
  local answer

  while true; do
    answer="$(prompt "${question} [pass/fail/skip]:")"
    case "${answer}" in
      pass|fail|skip)
        printf "%s\t%s\t%s\n" "${scenario}" "${question}" "${answer}" >> "${ANSWERS}"
        return 0
        ;;
      *)
        echo "Please type pass, fail, or skip."
        ;;
    esac
  done
}

prompt_text() {
  local scenario="$1"
  local question="$2"
  local answer

  answer="$(prompt "${question}")"
  printf "%s\t%s\t%s\n" "${scenario}" "${question}" "${answer}" >> "${ANSWERS}"
}

collect_logs() {
  local scenario="$1"
  local collected

  if [[ -x "${COLLECT_SCRIPT}" ]]; then
    collected="$("${COLLECT_SCRIPT}" "${RUN_ID}/${scenario}" 2>/dev/null || true)"
    if [[ -n "${collected}" && -d "${collected}" ]]; then
      ln -sfn "${collected}" "${OUT}/scenario-logs/${scenario}"
    fi
  else
    echo "Log collector not found at ${COLLECT_SCRIPT}; skipping collector for ${scenario}."
  fi
}

append_scenario() {
  local scenario="$1"
  local title="$2"
  local purpose="$3"

  {
    echo
    echo "## ${title}"
    echo
    echo "Scenario id: \`${scenario}\`"
    echo
    echo "Purpose: ${purpose}"
    echo
  } >> "${REPORT}"
}

run_scenario() {
  local scenario="$1"
  local title="$2"
  local purpose="$3"

  append_scenario "${scenario}" "${title}" "${purpose}"
  echo
  echo "================================================================================"
  echo "${title}"
  echo "Purpose: ${purpose}"
  echo "Artifacts: ${OUT}/scenario-logs/${scenario}"
  echo "================================================================================"
}

write_header() {
  {
    echo "# Daily Audio Reliability Check"
    echo
    echo "- Run id: \`${RUN_ID}\`"
    echo "- Started: \`$(date -u +%Y-%m-%dT%H:%M:%SZ)\`"
    echo "- Repo: \`${REPO_ROOT}\`"
    echo "- Artifacts: \`${OUT}\`"
    echo
    echo "Privacy rule: keep this report local. Use synthetic speech only."
    echo
    echo "Daily promise under test: a meeting should either become memory, or fail in a way the user understands and can retry."
    echo
    echo "## Meeting Failure Questions"
    echo
    echo "Every failed meeting should answer:"
    echo
    echo "- did recording start?"
    echo "- was audio captured?"
    echo "- did transcription fail?"
    echo "- did diarization fail?"
    echo "- did save fail?"
    echo "- was there a recoverable artifact?"
    echo "- can the user retry?"
  } > "${REPORT}"
}

write_footer() {
  {
    echo
    echo "## Operator Answers"
    echo
    if [[ -s "${ANSWERS}" ]]; then
      echo
      echo "| Scenario | Check | Answer |"
      echo "| --- | --- | --- |"
      awk -F '\t' '{ gsub(/\|/, "\\|", $1); gsub(/\|/, "\\|", $2); gsub(/\|/, "\\|", $3); printf "| `%s` | %s | %s |\n", $1, $2, $3 }' "${ANSWERS}"
    else
      echo
      echo "No operator answers captured."
    fi
    echo
    echo "## Suggested Log Review"
    echo
    echo "Review the matching scenario folder under \`${OUT}/scenario-logs/\` and search for:"
    echo
    echo "- \`recording_started\`, \`meeting_recording_started\`, \`meeting_capture_health_snapshot\`"
    echo "- \`audio_format_unavailable\`, \`audio_engine_start_failed\`, \`microphone_start_timeout\`"
    echo "- \`device_change\`, \`recover\`, \`retry\`, \`meeting_transcript_saved\`, \`meeting_transcription_failed\`"
    echo
    echo "## End"
    echo
    echo "- Finished: \`$(date -u +%Y-%m-%dT%H:%M:%SZ)\`"
  } >> "${REPORT}"
}

cd "${REPO_ROOT}"
write_header

echo "Daily Transcripted audio reliability run: ${RUN_ID}"
echo "Report: ${REPORT}"
echo

git status --short --branch | tee "${OUT}/git-status-start.txt"

if [[ "${DO_BUILD}" -eq 1 ]]; then
  echo
  echo "Building fresh app..."
  bash build.sh | tee "${OUT}/build.log"
fi

if [[ "${DO_LAUNCH}" -eq 1 ]]; then
  echo
  echo "Stopping duplicate Transcripted/Draft processes..."
  pkill -x Transcripted 2>/dev/null || true
  pkill -x Draft 2>/dev/null || true
  sleep 1

  if [[ ! -d "build/Transcripted.app" ]]; then
    echo "build/Transcripted.app was not found. Run without --skip-build or build first." >&2
    exit 1
  fi

  echo "Launching build/Transcripted.app..."
  open "build/Transcripted.app"
  sleep 3
fi

collect_logs "00-preflight"

run_scenario "01-launch-dictation" "Start Dictation After Launch" "Normal fresh-launch dictation must be boring."
echo "Say: Transcripted daily test one two three."
echo "Start dictation, speak the phrase, stop dictation, and confirm it completes."
prompt_pass_fail "01-launch-dictation" "Did dictation start after launch?"
prompt_pass_fail "01-launch-dictation" "Was speech captured and transcribed?"
prompt_pass_fail "01-launch-dictation" "Did the UI recover to an idle/ready state?"
prompt_text "01-launch-dictation" "Notes, if any:"
collect_logs "01-launch-dictation"

run_scenario "02-sleep-wake-dictation" "Start Dictation After Sleep/Wake" "Wake recovery must not strand the mic, hotkey, or model."
echo "Put the Mac to sleep, wake it, wait 5-10 seconds, then run a short dictation."
prompt_pass_fail "02-sleep-wake-dictation" "Did dictation start after wake?"
prompt_pass_fail "02-sleep-wake-dictation" "If the first start failed, did retry work calmly?"
prompt_pass_fail "02-sleep-wake-dictation" "Was the user message clear if capture could not start?"
prompt_text "02-sleep-wake-dictation" "Notes, if any:"
collect_logs "02-sleep-wake-dictation"

run_scenario "03-bluetooth-dictation" "Start Dictation After Bluetooth Change" "Bluetooth churn must settle or fail with a clear retry path."
echo "Connect/disconnect Bluetooth audio, or switch input devices, then immediately start dictation."
prompt_pass_fail "03-bluetooth-dictation" "Did dictation avoid getting stuck?"
prompt_pass_fail "03-bluetooth-dictation" "Did it either capture speech or show a clear recoverable message?"
prompt_pass_fail "03-bluetooth-dictation" "Did a second retry work after the route settled?"
prompt_text "03-bluetooth-dictation" "Notes, if any:"
collect_logs "03-bluetooth-dictation"

run_scenario "04-meeting-device-change" "Start Meeting After Device Change" "Meeting capture must start after the route changes, with mic/system capture status visible in evidence."
echo "Change input/output device, start a short meeting recording, speak the synthetic phrase, then stop it."
prompt_pass_fail "04-meeting-device-change" "Did meeting recording start?"
prompt_pass_fail "04-meeting-device-change" "Was mic audio captured?"
prompt_pass_fail "04-meeting-device-change" "Was system audio captured or clearly marked unavailable?"
prompt_pass_fail "04-meeting-device-change" "Did stop move into save/transcription without a stuck recording UI?"
prompt_text "04-meeting-device-change" "Notes, if any:"
collect_logs "04-meeting-device-change"

run_scenario "05-weird-route-recovery" "Recover When Mic/Audio Route Is Weird" "A weird route should produce a calm message, preserved artifact, and retry path."
echo "Use the oddest available route: Bluetooth mic, monitor output, USB mic, or rapid input/output switch."
echo "Start a meeting, stop it, and inspect whether a failed run leaves recoverable audio."
prompt_pass_fail "05-weird-route-recovery" "Did recording start?"
prompt_pass_fail "05-weird-route-recovery" "Was any audio captured?"
prompt_pass_fail "05-weird-route-recovery" "If transcription failed, was that clear?"
prompt_pass_fail "05-weird-route-recovery" "If diarization failed, was that clear and non-fatal?"
prompt_pass_fail "05-weird-route-recovery" "If save failed, was that clear?"
prompt_pass_fail "05-weird-route-recovery" "Was there a recoverable artifact?"
prompt_pass_fail "05-weird-route-recovery" "Could the user retry?"
prompt_text "05-weird-route-recovery" "Notes, if any:"
collect_logs "05-weird-route-recovery"

run_scenario "06-short-stop-race" "Short Meeting Stop Race" "Fast start/stop must not crash or leave the recording UI stuck."
echo "Start a meeting and stop within 1-3 seconds. Repeat 5 times."
prompt_pass_fail "06-short-stop-race" "Did all fast stop attempts avoid crashing?"
prompt_pass_fail "06-short-stop-race" "Did the UI return to a sane state every time?"
prompt_pass_fail "06-short-stop-race" "Did each failure/success answer what happened?"
prompt_text "06-short-stop-race" "Notes, if any:"
collect_logs "06-short-stop-race"

run_scenario "07-final-core-smoke" "Final Core Workflow Smoke" "End the daily run with one normal dictation and one normal meeting."
echo "Run one boring dictation and one boring meeting on the stable route."
prompt_pass_fail "07-final-core-smoke" "Did normal dictation still work?"
prompt_pass_fail "07-final-core-smoke" "Did normal meeting recording save a transcript?"
prompt_pass_fail "07-final-core-smoke" "Were logs free of new obvious audio/retry failures?"
prompt_text "07-final-core-smoke" "Notes, if any:"
collect_logs "07-final-core-smoke"

write_footer

echo
echo "Done."
echo "Report: ${REPORT}"
echo "Artifacts: ${OUT}"
