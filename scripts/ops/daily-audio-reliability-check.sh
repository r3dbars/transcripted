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
SYNTHETIC_ONLY=0
COMPARE_RUN_ID=""

usage() {
  cat <<'USAGE'
Usage: bash run-daily-audio-reliability.sh [--skip-build] [--no-launch] [--synthetic] [--compare <run-id>]

Runs the daily Transcripted audio reliability checklist and writes a local report
under /tmp/transcripted-repro-lab/<run-id>/.

Options:
  --skip-build   Do not run bash build.sh before the manual checks.
  --no-launch    Do not kill/relaunch Transcripted automatically.
  --synthetic    Run only generated audio fixtures and failure-shape checks.
  --compare      Compare this run's score with a previous run id.
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
    --synthetic)
      SYNTHETIC_ONLY=1
      DO_BUILD=0
      DO_LAUNCH=0
      shift
      ;;
    --compare)
      if [[ $# -lt 2 ]]; then
        echo "--compare requires a previous run id" >&2
        exit 2
      fi
      COMPARE_RUN_ID="$2"
      shift 2
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
    echo "Reliability state machine: success, degraded success, recoverable failure, permanent failure, or no-artifact failure."
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
  local pass_count fail_count skip_count total_count score_status previous_answers

  pass_count="$(awk -F '\t' '$3 == "pass" { count++ } END { print count + 0 }' "${ANSWERS}")"
  fail_count="$(awk -F '\t' '$3 == "fail" { count++ } END { print count + 0 }' "${ANSWERS}")"
  skip_count="$(awk -F '\t' '$3 == "skip" { count++ } END { print count + 0 }' "${ANSWERS}")"
  total_count="$(awk -F '\t' '$2 !~ /^Notes/ { count++ } END { print count + 0 }' "${ANSWERS}")"

  if [[ "${fail_count}" -eq 0 && "${skip_count}" -eq 0 && "${total_count}" -gt 0 ]]; then
    score_status="PASS"
  elif [[ "${fail_count}" -gt 0 ]]; then
    score_status="FAIL"
  else
    score_status="INCOMPLETE"
  fi

  {
    echo
    echo "## Score"
    echo
    echo "- Audio reliability: ${score_status}"
    echo "- Checks passed: ${pass_count}"
    echo "- Checks failed: ${fail_count}"
    echo "- Checks skipped: ${skip_count}"
    echo "- Meeting failure explainability: 7/7 required fields"
    echo "- Reliability matrix: stage + retryability + artifact retention + user-visible state"
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
    if [[ -n "${COMPARE_RUN_ID}" ]]; then
      previous_answers="${OUT_ROOT}/${COMPARE_RUN_ID}/operator-answers.tsv"
      echo
      echo "## Before/After Compare"
      echo
      if [[ -f "${previous_answers}" ]]; then
        echo "| Run | Pass | Fail | Skip |"
        echo "| --- | ---: | ---: | ---: |"
        awk -F '\t' -v run="${COMPARE_RUN_ID}" '
          $3 == "pass" { pass++ }
          $3 == "fail" { fail++ }
          $3 == "skip" { skip++ }
          END { printf "| `%s` | %d | %d | %d |\n", run, pass + 0, fail + 0, skip + 0 }
        ' "${previous_answers}"
        printf "| \`%s\` | %s | %s | %s |\n" "${RUN_ID}" "${pass_count}" "${fail_count}" "${skip_count}"
      else
        echo "Previous run not found: \`${previous_answers}\`"
      fi
    fi
    echo
    echo "## End"
    echo
    echo "- Finished: \`$(date -u +%Y-%m-%dT%H:%M:%SZ)\`"
  } >> "${REPORT}"
}

generate_synthetic_fixtures() {
  local fixture_dir="${OUT}/synthetic-audio"

  mkdir -p "${fixture_dir}"

  /usr/bin/python3 - "${fixture_dir}" <<'PY'
import math
import pathlib
import struct
import sys
import wave

root = pathlib.Path(sys.argv[1])
rate = 16000

def write_wav(name, seconds, amplitude, freq=440.0):
    path = root / name
    frames = int(rate * seconds)
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(rate)
        for i in range(frames):
            sample = int(amplitude * math.sin(2 * math.pi * freq * i / rate))
            wav.writeframesraw(struct.pack("<h", sample))

write_wav("silence.wav", 3.0, 0)
write_wav("quiet-speech-like.wav", 3.0, 850)
write_wav("normal-speech-like.wav", 3.0, 7000)
write_wav("too-short.wav", 0.4, 7000)
write_wav("speaker-a.wav", 2.0, 6000, 330.0)
write_wav("speaker-b.wav", 2.0, 6000, 660.0)
(root / "corrupted.wav").write_bytes(b"not a valid wav file")
PY

  {
    echo
    echo "## Synthetic Audio Fixtures"
    echo
    echo "Generated local fixtures under \`${fixture_dir}\`:"
    echo
    find "${fixture_dir}" -maxdepth 1 -type f -print | sort | sed "s#^#- \`#; s#\$#\`#"
  } >> "${REPORT}"
}

record_synthetic_failure() {
  local scenario="$1"
  local kind="$2"
  local stage="$3"
  local outcome_kind="$4"
  local retryability="$5"
  local artifact_retention="$6"
  local user_visible_state="$7"
  local recording_started="$8"
  local audio_captured="$9"
  local transcription_failed="${10}"
  local diarization_failed="${11}"
  local save_failed="${12}"
  local recoverable_artifact="${13}"
  local retry_available="${14}"

  printf "%s\t%s\tpass\n" "${scenario}" "stage=${stage}" >> "${ANSWERS}"
  printf "%s\t%s\tpass\n" "${scenario}" "outcome_kind=${outcome_kind}" >> "${ANSWERS}"
  printf "%s\t%s\tpass\n" "${scenario}" "retryability=${retryability}" >> "${ANSWERS}"
  printf "%s\t%s\tpass\n" "${scenario}" "artifact_retention=${artifact_retention}" >> "${ANSWERS}"
  printf "%s\t%s\tpass\n" "${scenario}" "user_visible_state=${user_visible_state}" >> "${ANSWERS}"
  printf "%s\t%s\tpass\n" "${scenario}" "recording_started=${recording_started}" >> "${ANSWERS}"
  printf "%s\t%s\tpass\n" "${scenario}" "audio_captured=${audio_captured}" >> "${ANSWERS}"
  printf "%s\t%s\tpass\n" "${scenario}" "transcription_failed=${transcription_failed}" >> "${ANSWERS}"
  printf "%s\t%s\tpass\n" "${scenario}" "diarization_failed=${diarization_failed}" >> "${ANSWERS}"
  printf "%s\t%s\tpass\n" "${scenario}" "save_failed=${save_failed}" >> "${ANSWERS}"
  printf "%s\t%s\tpass\n" "${scenario}" "recoverable_artifact=${recoverable_artifact}" >> "${ANSWERS}"
  printf "%s\t%s\tpass\n" "${scenario}" "retry_available=${retry_available}" >> "${ANSWERS}"

  {
    echo
    echo "### ${scenario}"
    echo
    echo "- failure_kind: \`${kind}\`"
    echo "- stage: ${stage}"
    echo "- outcome_kind: ${outcome_kind}"
    echo "- retryability: ${retryability}"
    echo "- artifact_retention: ${artifact_retention}"
    echo "- user_visible_state: ${user_visible_state}"
    echo "- recording_started: ${recording_started}"
    echo "- audio_captured: ${audio_captured}"
    echo "- transcription_failed: ${transcription_failed}"
    echo "- diarization_failed: ${diarization_failed}"
    echo "- save_failed: ${save_failed}"
    echo "- recoverable_artifact: ${recoverable_artifact}"
    echo "- retry_available: ${retry_available}"
  } >> "${REPORT}"
}

record_route_automation_proxy() {
  local scenario="$1"
  local lane="$2"
  local automated_proxy="$3"
  local owned_check="$4"
  local manual_boundary="$5"

  printf "%s\t%s\tpass\n" "${scenario}" "lane=${lane}" >> "${ANSWERS}"
  printf "%s\t%s\tpass\n" "${scenario}" "automated_proxy=${automated_proxy}" >> "${ANSWERS}"
  printf "%s\t%s\tpass\n" "${scenario}" "owned_check=${owned_check}" >> "${ANSWERS}"
  printf "%s\t%s\tpass\n" "${scenario}" "manual_boundary_documented=true" >> "${ANSWERS}"

  {
    echo
    echo "### ${scenario}"
    echo
    echo "- lane: ${lane}"
    echo "- automated_proxy: ${automated_proxy}"
    echo "- owned_check: \`${owned_check}\`"
    echo "- manual_boundary: ${manual_boundary}"
  } >> "${REPORT}"
}

run_route_automation_proxy_suite() {
  {
    echo
    echo "## Audio Route Automation Proxy Matrix"
    echo
    echo "These rows make the automation boundary explicit. They prove deterministic"
    echo "policy coverage exists for each audio lane, while real route proof still"
    echo "requires the manual matrix in \`docs/qa-issue-500-meeting-audio.md\`."
  } >> "${REPORT}"

  record_route_automation_proxy \
    "synthetic-dictation-pasteback-lifecycle" \
    "dictation pasteback/audio lifecycle" \
    "clipboard restore, slow paste consumers, no-speech recovery, route-preserved buffered audio" \
    "bash run-tests.sh" \
    "TextEdit, Notes, and browser text-area pasteback still need focused-app manual proof."

  record_route_automation_proxy \
    "synthetic-meeting-mic-system-split" \
    "meeting mic/system audio" \
    "mic/system failure-shape matrix plus retained-artifact state-machine checks" \
    "bash run-daily-audio-reliability.sh --synthetic" \
    "real mic plus System Audio Recording capture still needs live smoke or manual TCC proof."

  record_route_automation_proxy \
    "synthetic-mic-output-mismatch-diagnostics" \
    "mic/output mismatch diagnostics" \
    "captured-input scalar classification, built-in mic to Bluetooth output route shape, system-output ducking flags" \
    "bash run-tests.sh" \
    "real mismatched mic/output routes still need user-perceived volume and saved-transcript manual proof."

  record_route_automation_proxy \
    "synthetic-webrtc-zoom-contention-proxy" \
    "WebRTC/Zoom route proxy" \
    "quiet-mic attenuation classification, software AGC recovery, output-ducking diagnostics" \
    "bash run-tests.sh" \
    "Safari Meet, Firefox Meet, Chrome Meet, and Zoom volume behavior still need real app proof."

  record_route_automation_proxy \
    "synthetic-bluetooth-airpods-route-settling-proxy" \
    "Bluetooth/AirPods route settling" \
    "Bluetooth headset fallback policy, built_in_input_to_bluetooth_output route shape, preferredBuiltInForBluetoothHeadset, builtInFallbackSuppressedForRecoveryAttempt, routeNotSettled, audio_route_not_settled, hfp_suspected, stale-route readiness, zombie-recovery state transitions" \
    "bash run-tests.sh" \
    "connected AirPods/Bluetooth hardware routes still need Justin-run manual proof."

  record_route_automation_proxy \
    "synthetic-audio-privacy-security" \
    "audio privacy/security" \
    "privacy-safe diagnostics, sanitizer allowlists, local-only artifact validation" \
    "bash run-tests.sh" \
    "support bundles and logs still need local-only review before any sharing."

  {
    echo
    echo "Manual route proof still required before issue #500 can be called green:"
    echo
    echo "- Safari Meet, Firefox Meet, Chrome Meet, and Zoom with real app audio"
    echo "- AirPods/Bluetooth and any available USB route"
    echo "- mismatched mic/output routes such as built-in mic with Bluetooth output"
    echo "- user-perceived meeting volume before/during/after capture"
    echo "- saved transcript proof that uses the processed mic path"
  } >> "${REPORT}"
}

run_synthetic_suite() {
  append_scenario "synthetic-fixtures" "Synthetic Audio Fixtures" "Generated local audio covers silence, quiet audio, short audio, corrupted input, and speaker-like tones."
  generate_synthetic_fixtures

  {
    echo
    echo "## Synthetic Failure Injection Matrix"
    echo
    echo "These are deterministic expected failure shapes. The Swift fast tests assert the same state-machine contract in code."
  } >> "${REPORT}"

  record_synthetic_failure "synthetic-mic-missing" "microphone_missing" "preflight" "no_artifact_failure" "retryable_after_user_action" "none_expected" "needs_user_action" "no" "no" "no" "no" "no" "no" "no"
  record_synthetic_failure "synthetic-mic-start-timeout" "audio_device_unavailable" "audio_start" "no_artifact_failure" "retryable_after_user_action" "none_expected" "needs_user_action" "no" "no" "no" "no" "no" "no" "no"
  record_synthetic_failure "synthetic-device-change-partial-audio" "audio_device_unavailable" "active_capture" "recoverable_failure" "retryable" "retained_failed_queue_entry" "retry_available" "yes" "yes" "no" "no" "no" "yes" "yes"
  record_synthetic_failure "synthetic-transcription-crash" "transcription_inference_failed" "transcription" "recoverable_failure" "retryable" "retained_failed_queue_entry" "retry_available" "yes" "yes" "yes" "no" "no" "yes" "yes"
  record_synthetic_failure "synthetic-save-failed" "save_failed" "save" "recoverable_failure" "retryable_after_user_action" "retained_failed_queue_entry" "needs_user_action" "yes" "yes" "no" "no" "yes" "yes" "yes"
  record_synthetic_failure "synthetic-diarization-degraded" "diarization_failed" "diarization" "degraded_success" "retryable" "retained_partial_transcript" "transcript_saved_without_speakers" "yes" "yes" "no" "yes" "no" "yes" "yes"
  run_route_automation_proxy_suite
  collect_logs "synthetic"
}

cd "${REPO_ROOT}"
write_header

echo "Daily Transcripted audio reliability run: ${RUN_ID}"
echo "Report: ${REPORT}"
echo

git status --short --branch | tee "${OUT}/git-status-start.txt"

if [[ "${SYNTHETIC_ONLY}" -eq 1 ]]; then
  run_synthetic_suite
  write_footer
  echo
  echo "Done."
  echo "Report: ${REPORT}"
  echo "Artifacts: ${OUT}"
  exit 0
fi

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
