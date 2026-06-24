#!/usr/bin/env bash
set -u -o pipefail

# Transcripted QA bench.
#
# This is an orchestrator, not a second test framework. It runs the repo-owned
# checks, captures logs, and writes one local report.

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MODE="quick"
OUT_ROOT="${TRANSCRIPTED_QA_BENCH_OUT:-/tmp/transcripted-qa-bench}"
RUN_ID="${TRANSCRIPTED_QA_BENCH_RUN_ID:-qa-$(date +%Y%m%d-%H%M%S)}"
SKIP_BUILD=0
STRICT_ARTIFACTS=0
GEMMA_EXECUTE="${TRANSCRIPTED_QA_GEMMA_EXECUTE:-0}"
LIVE_DURATION="${TRANSCRIPTED_QA_LIVE_DURATION:-2.0}"
CORPUS_ROOT="${TRANSCRIPTED_QA_CORPUS_ROOT:-${HOME}/Downloads/meeting-corpus}"
CORPUS_IDS="${TRANSCRIPTED_QA_CORPUS_IDS:-}"
CORPUS_COMPARE_DEFAULT_IDS="meeting-0024,meeting-0025"
if [[ -n "${TRANSCRIPTED_QA_CORPUS_OUTPUT_DIR:-}" ]]; then
  CORPUS_OUTPUT_DIR="${TRANSCRIPTED_QA_CORPUS_OUTPUT_DIR}"
  CORPUS_OUTPUT_DIR_EXPLICIT=1
else
  CORPUS_OUTPUT_DIR="${CORPUS_ROOT}/transcripted-output"
  CORPUS_OUTPUT_DIR_EXPLICIT=0
fi
CORPUS_CANDIDATE_MAP="${TRANSCRIPTED_QA_CORPUS_CANDIDATE_MAP:-}"
CORPUS_MIN_RECALL="${TRANSCRIPTED_QA_CORPUS_MIN_RECALL:-0.45}"
CORPUS_MIN_CONTENT_RECALL="${TRANSCRIPTED_QA_CORPUS_MIN_CONTENT_RECALL:-0.35}"
PACKAGED_USER_NAME="${TRANSCRIPTED_QA_PACKAGED_USER_NAME:-${USER:-codex}}"

usage() {
  cat <<'USAGE'
Usage: bash scripts/ops/transcripted-qa-bench.sh [--mode quick|deep|full|ui|sparkle-update|packaged|artifact|audio-synthetic|pasteback-synthetic|corpus|corpus-compare|scorecard|live] [options]

Runs a local Transcripted QA bench and writes:
  /tmp/transcripted-qa-bench/<run-id>/qa-report.md

Modes:
  quick            build, fast tests, deterministic E2E smoke, slow pasteback smoke
  deep             quick + integration, Core tests, QA CLI, synthetic audio
  full             deep + release-health and local Gemma summary dry-run gates
  ui               build + Accessibility-driven menu bar/Home/Settings smoke
  sparkle-update   build + no-publish fake Sparkle available/downloading UI smoke
  packaged         no-publish build-beta smoke + packaged app/version/Sparkle/dSYM/log checks
  artifact         validate current saved Transcripted artifacts strictly
  audio-synthetic  run only the deterministic audio failure-shape matrix
  pasteback-synthetic
                   run only the fake slow Cmd+V pasteback target smoke
  corpus           validate a local private meeting corpus
  corpus-compare   validate corpus, then compare Transcripted Markdown to Zoom truth
  scorecard        aggregate per-board QA evidence into a scorecard
  live             full + live mic/system-audio smoke

Options:
  --skip-build          Do not run build.sh in quick/deep/live modes.
  --strict-artifacts    Make live artifact validation blocking in deep/full/live mode.
  --gemma-execute       Run real Gemma/MLX proof where the bench has local inputs.
                       Equivalent to TRANSCRIPTED_QA_GEMMA_EXECUTE=1.
  --duration seconds    Live capture duration. Default: 2.0
  --corpus-root path    Meeting corpus root. Default: ~/Downloads/meeting-corpus
  --corpus-ids ids      Comma-separated meeting ids to validate.
  --corpus-output-dir path
                       Transcripted Markdown output dir for corpus-compare.
                       Default: <corpus-root>/transcripted-output
  --corpus-candidate-map path
                       JSON map of meeting id to Transcripted Markdown path.
  --corpus-min-recall n
                       Minimum full-word recall for corpus-compare. Default: 0.45
  --corpus-min-content-recall n
                       Minimum content-word recall for corpus-compare. Default: 0.35
  --out-root path       Output root. Default: /tmp/transcripted-qa-bench
  --run-id id           Run id. Default: qa-YYYYMMDD-HHMMSS
  -h, --help            Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      if [[ $# -lt 2 ]]; then
        echo "--mode requires a value" >&2
        exit 2
      fi
      MODE="$2"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --strict-artifacts)
      STRICT_ARTIFACTS=1
      shift
      ;;
    --gemma-execute)
      GEMMA_EXECUTE=1
      shift
      ;;
    --duration)
      if [[ $# -lt 2 ]]; then
        echo "--duration requires a value" >&2
        exit 2
      fi
      LIVE_DURATION="$2"
      shift 2
      ;;
    --corpus-root)
      if [[ $# -lt 2 ]]; then
        echo "--corpus-root requires a value" >&2
        exit 2
      fi
      CORPUS_ROOT="$2"
      if [[ "$CORPUS_OUTPUT_DIR_EXPLICIT" -eq 0 ]]; then
        CORPUS_OUTPUT_DIR="${CORPUS_ROOT}/transcripted-output"
      fi
      shift 2
      ;;
    --corpus-ids)
      if [[ $# -lt 2 ]]; then
        echo "--corpus-ids requires a value" >&2
        exit 2
      fi
      CORPUS_IDS="$2"
      shift 2
      ;;
    --corpus-output-dir)
      if [[ $# -lt 2 ]]; then
        echo "--corpus-output-dir requires a value" >&2
        exit 2
      fi
      CORPUS_OUTPUT_DIR="$2"
      CORPUS_OUTPUT_DIR_EXPLICIT=1
      shift 2
      ;;
    --corpus-candidate-map)
      if [[ $# -lt 2 ]]; then
        echo "--corpus-candidate-map requires a value" >&2
        exit 2
      fi
      CORPUS_CANDIDATE_MAP="$2"
      shift 2
      ;;
    --corpus-min-recall)
      if [[ $# -lt 2 ]]; then
        echo "--corpus-min-recall requires a value" >&2
        exit 2
      fi
      CORPUS_MIN_RECALL="$2"
      shift 2
      ;;
    --corpus-min-content-recall)
      if [[ $# -lt 2 ]]; then
        echo "--corpus-min-content-recall requires a value" >&2
        exit 2
      fi
      CORPUS_MIN_CONTENT_RECALL="$2"
      shift 2
      ;;
    --out-root)
      if [[ $# -lt 2 ]]; then
        echo "--out-root requires a value" >&2
        exit 2
      fi
      OUT_ROOT="$2"
      shift 2
      ;;
    --run-id)
      if [[ $# -lt 2 ]]; then
        echo "--run-id requires a value" >&2
        exit 2
      fi
      RUN_ID="$2"
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

case "$MODE" in
  quick|deep|full|ui|sparkle-update|packaged|artifact|audio-synthetic|pasteback-synthetic|corpus|corpus-compare|scorecard|live) ;;
  *)
    echo "Unknown mode: $MODE" >&2
    usage >&2
    exit 2
    ;;
esac

resolve_out_root() {
  case "$1" in
    /*) printf "%s" "$1" ;;
    *) printf "%s/%s" "${PWD}" "$1" ;;
  esac
}

OUT_ROOT="$(resolve_out_root "${OUT_ROOT}")"
OUT="${OUT_ROOT}/${RUN_ID}"
LOG_DIR="${OUT}/logs"
RAW_DIR="${OUT}/raw"
RESULTS="${OUT}/results.tsv"
REPORT="${OUT}/qa-report.md"
MANUAL="${OUT}/manual-scenarios.md"

fail_io() {
  echo "[qa] ERROR: $1" >&2
  exit 2
}

shell_quote() {
  printf "%q" "$1"
}

mkdir -p "${LOG_DIR}" "${RAW_DIR}" || fail_io "Unable to create output directories under ${OUT}."
: > "${RESULTS}" || fail_io "Unable to write results file at ${RESULTS}."

append_result() {
  local id="$1"
  local title="$2"
  local status="$3"
  local exit_code="$4"
  local duration="$5"
  local log_path="$6"

  printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
    "${id}" "${title}" "${status}" "${exit_code}" "${duration}" "${log_path}" >> "${RESULTS}" \
    || fail_io "Unable to append results file at ${RESULTS}."
}

run_step() {
  local id="$1"
  local title="$2"
  local blocking="$3"
  local command="$4"
  local log_path="${LOG_DIR}/${id}.log"
  local started finished duration exit_code status

  started="$(date -u +%s)"
  if ! {
    echo "$ ${command}"
    echo
  } > "${log_path}"; then
    fail_io "Unable to write step log at ${log_path}."
  fi

  echo "[qa] ${title}"
  (
    cd "${REPO_ROOT}" || exit 1
    bash -lc "${command}"
  ) >> "${log_path}" 2>&1
  exit_code=$?

  finished="$(date -u +%s)"
  duration=$((finished - started))

  if [[ "${exit_code}" -eq 0 ]]; then
    status="PASS"
  elif [[ "${exit_code}" -eq 3 ]]; then
    status="WARN"
  elif [[ "${blocking}" == "yes" ]]; then
    status="FAIL"
  else
    status="WARN"
  fi

  append_result "${id}" "${title}" "${status}" "${exit_code}" "${duration}" "${log_path}"
  echo "[qa] ${status} ${title} (${duration}s)"
  return "${exit_code}"
}

run_step_when_present() {
  local id="$1"
  local title="$2"
  local blocking="$3"
  local relative_path="$4"
  local command="$5"

  if [[ -e "${REPO_ROOT}/${relative_path}" ]]; then
    run_step "${id}" "${title}" "${blocking}" "${command}"
  else
    skip_step "${id}" "${title} (missing ${relative_path})"
  fi
}

run_warnings_only_step() {
  local id="$1"
  local title="$2"
  local command="$3"
  local log_path started finished duration exit_code status

  log_path="${LOG_DIR}/${id}.log"
  started="$(date -u +%s)"
  if ! {
    echo "$ ${command}"
    echo
  } > "${log_path}"; then
    fail_io "Unable to write step log at ${log_path}."
  fi

  echo "[qa] ${title}"
  (
    cd "${REPO_ROOT}" || exit 1
    bash -lc "${command}"
  ) >> "${log_path}" 2>&1
  exit_code=$?

  finished="$(date -u +%s)"
  duration=$((finished - started))
  status="$(warnings_only_status_from_log "${log_path}" "${exit_code}")"

  if [[ "${status}" == "WARN" ]]; then
    echo "[qa] WARNINGS_ONLY: non-strict local artifact warnings are recorded in the report and do not hold this gate." >> "${log_path}"
  fi

  append_result "${id}" "${title}" "${status}" "${exit_code}" "${duration}" "${log_path}"
  echo "[qa] ${status} ${title} (${duration}s)"
  if [[ "${status}" == "FAIL" ]]; then
    return "${exit_code}"
  fi
  return 0
}

warnings_only_status_from_log() {
  local log_path="$1"
  local exit_code="$2"

  python3 - "${log_path}" "${exit_code}" <<'PY'
import json
import sys

path = sys.argv[1]
exit_code = int(sys.argv[2])
try:
    text = open(path, encoding="utf-8", errors="replace").read()
except OSError:
    print("FAIL")
    raise SystemExit(0)

report = None
decoder = json.JSONDecoder()
for index, char in enumerate(text):
    if char != "{":
        continue
    try:
        candidate, _ = decoder.raw_decode(text[index:])
    except json.JSONDecodeError:
        continue
    if isinstance(candidate, dict) and isinstance(candidate.get("summary"), dict):
        report = candidate
        break

if report is not None:
    summary = report["summary"]
    failed = int(summary.get("failed", 0) or 0)
    warnings = int(summary.get("warnings", 0) or 0)
    if failed:
        print("FAIL")
    elif warnings:
        print("WARN")
    else:
        print("PASS")
elif exit_code == 0:
    print("PASS")
else:
    print("FAIL")
PY
}

skip_step() {
  local id="$1"
  local title="$2"
  append_result "${id}" "${title}" "SKIP" "0" "0" ""
  echo "[qa] SKIP ${title}"
}

write_manual_scenarios() {
  if ! cat > "${MANUAL}" <<'MARKDOWN'
# Transcripted Manual QA Scenarios

Keep this local. Use synthetic speech only.

## Codex UI Automation Permissions

Run before any Codex computer-use, screenshot, or click-flow proof:

```bash
TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift run --package-path Tools/TranscriptedQA transcripted-qa permission-state --mode computer-use
```

Pass bar:
- Accessibility, Event Posting, Input Monitoring, Screen Recording, and Automation are ready for the app that runs Codex or the terminal host.
- Transcripted app bundle identity matches the expected bundle id.
- No duplicate or wrong running Transcripted app instance makes UI targeting ambiguous.
- Every automated click proves a visible state change after the event.

If this command warns, report `INCOMPLETE: harness permission blocked`.
Do not call it a Transcripted app failure.

## Meeting Capture

- Start a meeting from the menu bar.
- Speak: `Transcripted QA meeting test one two three.`
- Play a short system tone or meeting audio.
- Stop the meeting.
- Pass bar: transcript saved, mic audio present, system audio present or clearly unavailable, UI returns to idle.

## Meeting Apps And Volume

Use `docs/qa-issue-500-meeting-audio.md`.

Matrix:
- Chrome Meet
- Safari Meet
- Firefox Meet
- Zoom
- Teams or WhatsApp Mac if installed
- no meeting app

Routes:
- built-in mic/speakers
- AirPods or Bluetooth
- USB mic if available

Mocked Bluetooth/AirPods route contracts are automated policy proof, not hardware proof.
Real connected AirPods/Bluetooth hardware remains manual proof.

Stop immediately if the user's meeting gets quieter.

## Speaker Names

- Run one fixture with default local mic behavior. Pass bar: local mic stays `You`.
- Enable local speaker review and record two synthetic local voices if practical.
- Rename a speaker manually.
- Pass bar: Markdown uses the chosen name, known people stay stable, unknown is preferred over a confidently wrong name.

## Dictation

- Dictate into TextEdit.
- Dictate into Notes.
- Dictate into a browser text area.
- Dictate with Auto Enter disabled and enabled for a safe app.
- Pass bar: text is pasted or copied as reported, saved dictation Markdown has source app, delivery, word count, and final text.

## Recovery

- Try dictation after sleep/wake.
- Try dictation after input-device change.
- Try meeting start/stop in under 3 seconds.
- Try imported audio.
- Pass bar: no stuck recording UI, clear retry path, recoverable artifacts are retained when capture succeeded but transcription failed.
MARKDOWN
  then
    fail_io "Unable to write manual scenario file at ${MANUAL}."
  fi
}

write_report() {
  local fail_count warn_count soft_warn_count hard_warn_count skip_count pass_count flag_count hold_flag_count total_count verdict branch commit app_version started finished short_summary
  local working_status regressed_status needs_human_status release_status
  local ui_status artifact_status packaged_status audio_status gemma_status release_health_status live_status

  fail_count="$(awk -F '\t' '$3 == "FAIL" { count++ } END { print count + 0 }' "${RESULTS}")"
  warn_count="$(awk -F '\t' '$3 == "WARN" { count++ } END { print count + 0 }' "${RESULTS}")"
  soft_warn_count="$(awk -F '\t' '$3 == "WARN" && $2 ~ /warnings-only local state/ { count++ } END { print count + 0 }' "${RESULTS}")"
  hard_warn_count=$((warn_count - soft_warn_count))
  skip_count="$(awk -F '\t' '$3 == "SKIP" { count++ } END { print count + 0 }' "${RESULTS}")"
  pass_count="$(awk -F '\t' '$3 == "PASS" { count++ } END { print count + 0 }' "${RESULTS}")"
  flag_count=$((fail_count + warn_count + skip_count))
  hold_flag_count=$((fail_count + hard_warn_count + skip_count))
  total_count=$((pass_count + flag_count))

  if [[ "${fail_count}" -gt 0 ]]; then
    verdict="FAIL"
  elif [[ "${hard_warn_count}" -gt 0 || "${skip_count}" -gt 0 ]]; then
    verdict="INCOMPLETE"
  else
    verdict="PASS"
  fi

  branch="$(cd "${REPO_ROOT}" && git branch --show-current 2>/dev/null || true)"
  if [[ -z "${branch}" ]]; then
    branch="detached"
  fi
  commit="$(cd "${REPO_ROOT}" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${REPO_ROOT}/Info.plist" 2>/dev/null || echo unknown)"
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  finished="${started}"

  if [[ "${verdict}" == "PASS" && "${soft_warn_count}" -gt 0 ]]; then
    short_summary="PASS: completed ${total_count} checks with ${soft_warn_count} non-blocking local warning(s)."
  elif [[ "${verdict}" == "PASS" ]]; then
    short_summary="PASS: tested ${pass_count}/${total_count} checks. Good to go."
  elif [[ "${verdict}" == "FAIL" ]]; then
    short_summary="FAIL: tested ${pass_count}/${total_count} checks. Not good yet: ${flag_count} flagged."
  else
    short_summary="INCOMPLETE: tested ${pass_count}/${total_count} checks. Not good yet: ${flag_count} flagged."
  fi

  if [[ "${fail_count}" -gt 0 ]]; then
    working_status="NO"
    regressed_status="YES"
  elif [[ "${hard_warn_count}" -gt 0 || "${skip_count}" -gt 0 ]]; then
    working_status="PARTIAL"
    regressed_status="NO automated regression, but proof is incomplete"
  elif [[ "${soft_warn_count}" -gt 0 ]]; then
    working_status="YES"
    regressed_status="NO automated regression; non-blocking local artifact warnings recorded"
  else
    working_status="YES"
    regressed_status="NO"
  fi

  needs_human_status="YES - slow pasteback feel, real Zoom/WebRTC meeting route, AirPods/Bluetooth route, and local Gemma summary beta workflow still need manual proof"
  if [[ "${fail_count}" -gt 0 ]]; then
    release_status="HOLD - automated regression found"
  elif [[ "${hard_warn_count}" -gt 0 || "${skip_count}" -gt 0 ]]; then
    release_status="HOLD - proof is incomplete"
  elif [[ "${MODE}" != "full" && "${MODE}" != "live" ]]; then
    release_status="HOLD - run the full Transcripted QA gate before release"
  else
    release_status="HOLD - automated full gate is green, but manual proof is still required"
  fi

  ui_status="$(result_status "04-ui-smoke")"
  artifact_status="$(result_status "03-e2e-smoke")"
  packaged_status="$(result_status "70-packaged-app-smoke")"
  audio_status="$(result_status "30-audio-synthetic")"
  gemma_status="$(result_status "61-gemma-summary-plan")"
  release_health_status="$(result_status "60-release-health")"
  live_status="$(result_status "40-live-capture")"

  if ! {
    echo "# Transcripted QA Bench Report"
    echo
    echo "## Short Answer"
    echo
    echo "${short_summary}"
    echo
    echo "## Flags"
    echo
    if [[ "${flag_count}" -eq 0 ]]; then
      echo "No flags."
    else
      awk -F '\t' '$3 != "PASS" {
        gsub(/\|/, "\\|", $2)
        printf "- %s - %s\n", $3, $2
      }' "${RESULTS}"
    fi
    echo
    echo "## Run Details"
    echo
    echo "- Verdict: ${verdict}"
    echo "- Run id: \`${RUN_ID}\`"
    echo "- Mode: \`${MODE}\`"
    echo "- Repo: \`${REPO_ROOT}\`"
    echo "- Branch: \`${branch}\`"
    echo "- Commit: \`${commit}\`"
    echo "- App version: \`${app_version}\`"
    echo "- Generated: \`${finished}\`"
    echo "- Artifacts: \`${OUT}\`"
    echo
    echo "## Executive Result"
    echo
    echo "- Passed: ${pass_count}"
    echo "- Failed: ${fail_count}"
    echo "- Warnings: ${warn_count}"
    echo "- Non-blocking warnings: ${soft_warn_count}"
    echo "- Skipped: ${skip_count}"
    echo
    echo "## Operator Verdict"
    echo
    echo "- Working: ${working_status}"
    echo "- Regressed: ${regressed_status}"
    echo "- Needs human: ${needs_human_status}"
    echo "- Release: ${release_status}"
    echo
    echo "## Proof Map"
    echo
    echo "- UI automation smoke: ${ui_status} via \`transcripted-qa ui-smoke\`"
    echo "- Packaged app smoke: ${packaged_status} via \`transcripted-qa packaged-app-smoke\`"
    echo "- Meeting and dictation artifact contract: ${artifact_status} via \`bash run-e2e-smoke.sh\`"
    echo "- Meeting route and Bluetooth mock/proxy matrix: ${audio_status} via \`bash run-daily-audio-reliability.sh --synthetic\`"
    echo "- Local Gemma summary dry-run plan: ${gemma_status} via \`scripts/ops/local-gemma-summary-autoeval.py\`"
    echo "- Release-health fixture gate: ${release_health_status} via \`scripts/ops/nightly-security-check.py\`"
    echo "- Live mic/system-audio smoke: ${live_status} via \`bash run-live-capture-smoke.sh\`"
    echo
    echo "## Proof Boundary"
    echo
    echo "Mocked Bluetooth/AirPods route contracts are automated policy proof, not hardware proof."
    echo "Real connected AirPods/Bluetooth hardware remains manual proof."
    echo
    echo "Raw logs stay local. Do not upload user audio, transcript text, speaker names, tokens, absolute paths, or device names."
    echo
    echo "## Results"
    echo
    echo "| Status | Step | Exit | Time | Log |"
    echo "| --- | --- | ---: | ---: | --- |"
    awk -F '\t' '{
      log_path = $6 == "" ? "" : "`" $6 "`"
      gsub(/\|/, "\\|", $2)
      printf "| %s | %s | %s | %ss | %s |\n", $3, $2, $4, $5, log_path
    }' "${RESULTS}"
    echo
    echo "## Manual Scenarios"
    echo
    echo "Use \`${MANUAL}\` for the human proof lanes that require GUI, TCC, hardware, meeting apps, or feel checks."
    echo
    echo "## Codex UI Automation Permission Gate"
    echo
    echo "Live mode runs \`transcripted-qa permission-state --mode live-capture\` before live capture. A permission warning means the run is \`INCOMPLETE\`, not green product proof."
    echo
    echo "For click-only Computer Use runs, use \`transcripted-qa permission-state --mode computer-use\` and prove a visible state change after each click."
    echo
    echo "## Evidence Index"
    echo
    awk -F '\t' '$6 != "" { print "- `" $6 "`" }' "${RESULTS}"
  } > "${REPORT}"; then
    fail_io "Unable to write QA report at ${REPORT}."
  fi

  echo
  echo "[qa] Report: ${REPORT}"
  echo "[qa] Verdict: ${verdict}"
  echo "[qa] ${short_summary}"

  if [[ "${flag_count}" -gt 0 ]]; then
    echo "[qa] Flags:"
    awk -F '\t' '$3 != "PASS" {
      printf "[qa] - %s - %s\n", $3, $2
      count++
      if (count == 5) {
        exit
      }
    }' "${RESULTS}"
    if [[ "${flag_count}" -gt 5 ]]; then
      echo "[qa] - ...and $((flag_count - 5)) more flags in the report."
    fi
  fi

  if [[ "${fail_count}" -gt 0 ]]; then
    return 1
  fi
  if [[ "${hold_flag_count}" -gt 0 ]]; then
    return 3
  fi
  return 0
}

result_status() {
  local id="$1"
  awk -F '\t' -v wanted="${id}" '
    $1 == wanted {
      print $3
      found = 1
      exit
    }
    END {
      if (!found) {
        print "NOT RUN"
      }
    }
  ' "${RESULTS}"
}

run_quick() {
  run_step "00-preflight" "Agent preflight" "no" "bash scripts/dev/agent-preflight.sh"

  if [[ "${SKIP_BUILD}" -eq 1 ]]; then
    skip_step "01-build" "Build app"
  else
    run_step "01-build" "Build app" "yes" "bash build.sh --no-open"
  fi

  run_step "02-fast-tests" "Fast tests" "yes" "bash run-tests.sh"
  run_step "03-e2e-smoke" "Deterministic E2E smoke" "yes" "bash run-e2e-smoke.sh"
  run_pasteback_synthetic
  if [[ "${GEMMA_EXECUTE}" == "1" ]]; then
    run_step "05-local-summary-fixture" "Real Gemma summary fixture smoke" "yes" \
      "bash scripts/ops/run-local-summary-fixture.sh --real-gemma"
  else
    run_step "05-local-summary-fixture" "Local Gemma summary fixture smoke" "yes" \
      "bash scripts/ops/run-local-summary-fixture.sh"
  fi
}

run_pasteback_synthetic() {
  run_step "04-slow-pasteback-smoke" "Slow pasteback target smoke" "yes" \
    "bash run-slow-pasteback-smoke.sh --json-out $(shell_quote "${RAW_DIR}/slow-pasteback-smoke.json") --markdown-out $(shell_quote "${OUT}/slow-pasteback-smoke.md")"
}

run_artifact_validation() {
  local blocking="$1"
  if [[ "${blocking}" == "yes" ]]; then
    run_step "20-qa-health" "TranscriptedQA health check" "yes" \
      "TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift run --package-path Tools/TranscriptedQA transcripted-qa check-health --format json"
    run_step "21-qa-validate-all" "TranscriptedQA validate current artifacts" "yes" \
      "TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift run --package-path Tools/TranscriptedQA transcripted-qa validate-all --format json"
  else
    run_step "20-qa-health" "TranscriptedQA health check" "yes" \
      "TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift run --package-path Tools/TranscriptedQA transcripted-qa check-health --format json"
    run_warnings_only_step "21-qa-validate-all" "TranscriptedQA validate current artifacts (warnings-only local state)" \
      "TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift run --package-path Tools/TranscriptedQA transcripted-qa validate-all --format json"
  fi
}

run_permission_state() {
  run_step "39-permission-state" "Codex permission-state preflight" "yes" \
    "TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift run --package-path Tools/TranscriptedQA transcripted-qa permission-state --mode live-capture --format json"
}

run_deep_tail() {
  run_step "10-integration-smoke" "Integration smoke" "yes" "bash run-integration-smoke.sh"
  run_step "11-core-swift-test" "TranscriptedCore swift test" "yes" "swift test"
  run_step "12-qa-cli-tests" "TranscriptedQA package tests" "yes" "swift test --package-path Tools/TranscriptedQA"
  run_step "13-qa-round-trip" "TranscriptedQA validator round trip" "yes" \
    "swift run --package-path Tools/TranscriptedQA transcripted-qa round-trip"
  run_step "14-qa-stress-small" "TranscriptedQA small stress pass" "yes" \
    "swift run --package-path Tools/TranscriptedQA transcripted-qa stress-test --transcripts 12 --speakers-per-transcript 4 --utterances-per-transcript 80"
  run_step "15-imported-audio-smoke" "Imported audio artifact smoke" "yes" \
    "swift run --package-path Tools/TranscriptedQA transcripted-qa imported-audio-smoke --output $(shell_quote "${RAW_DIR}/imported-audio-smoke")"

  if [[ "${STRICT_ARTIFACTS}" -eq 1 ]]; then
    run_artifact_validation "yes"
  else
    run_artifact_validation "no"
  fi

  run_step "30-audio-synthetic" "Synthetic audio reliability matrix" "yes" \
    "bash run-daily-audio-reliability.sh --synthetic"
}

has_gemma_summary_candidates() {
  if [[ ! -e "${REPO_ROOT}/scripts/ops/local-gemma-summary-autoeval.py" ]]; then
    return 1
  fi

  python3 - "${REPO_ROOT}" <<'PY'
import importlib.util
import sys
from pathlib import Path

repo_root = Path(sys.argv[1])
script = repo_root / "scripts/ops/local-gemma-summary-autoeval.py"
spec = importlib.util.spec_from_file_location("local_gemma_summary_autoeval", script)
if spec is None or spec.loader is None:
    raise SystemExit(2)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
try:
    spec.loader.exec_module(module)
except Exception as error:
    print(f"Gemma candidate preflight failed: {error}", file=sys.stderr)
    raise SystemExit(2)

class Args:
    pass

args = Args()
args.input = []
args.min_words = 40
args.scan_limit = 2_000
args.include_longest = 1
args.sample_count = 0
args.limit = 1
args.seed = 17
profile = dict(module.PROFILES[module.DEFAULT_PROFILE])
args.chunk_character_limit = int(profile["chunk_character_limit"])
try:
    cases = module.select_cases(module.discover_cases(args, profile), args)
except Exception as error:
    print(f"Gemma candidate preflight failed: {error}", file=sys.stderr)
    raise SystemExit(2)
raise SystemExit(0 if cases else 1)
PY
}

run_gemma_summary_plan() {
  if [[ ! -e "${REPO_ROOT}/scripts/ops/local-gemma-summary-autoeval.py" ]]; then
    skip_step "61-gemma-summary-plan" "Local Gemma summary dry-run plan (missing scripts/ops/local-gemma-summary-autoeval.py)"
    return 0
  fi

  has_gemma_summary_candidates
  local candidate_status=$?
  if [[ "${candidate_status}" -eq 1 ]]; then
    append_result "61-gemma-summary-plan" "Local Gemma summary dry-run plan not applicable (no eligible local transcripts)" "PASS" "0" "0" ""
    echo "[qa] PASS Local Gemma summary dry-run plan not applicable (no eligible local transcripts)"
    return 0
  fi
  if [[ "${candidate_status}" -ne 0 ]]; then
    append_result "61-gemma-summary-plan" "Local Gemma summary dry-run candidate preflight" "FAIL" "${candidate_status}" "0" ""
    echo "[qa] FAIL Local Gemma summary dry-run candidate preflight"
    return "${candidate_status}"
  fi

  local execute_arg=""
  local title="Local Gemma summary dry-run plan"
  if [[ "${GEMMA_EXECUTE}" == "1" ]]; then
    execute_arg=" --execute"
    title="Local Gemma summary executable proof"
  fi

  run_step "61-gemma-summary-plan" "${title}" "no" \
    "python3 scripts/ops/local-gemma-summary-autoeval.py --out-root $(shell_quote "${OUT}/local-gemma-summary") --run-id plan --limit 1 --include-longest 1 --sample-count 0 --repeats 1${execute_arg}"
}

run_full_tail() {
  run_step_when_present "60-release-health" "Deterministic release health gate" "yes" \
    "scripts/ops/nightly-security-check.py" \
    "python3 scripts/ops/nightly-security-check.py --strict --automation-toml Tests/Fixtures/nightly-security-automation.toml --github-release-json Tests/Fixtures/release-health-github-release-1.1.48.json --write-report $(shell_quote "${RAW_DIR}/release-health.json")"

  run_step_when_present "62-posthog-product-tasks" "PostHog product task fixture gate" "yes" \
    "scripts/ops/posthog-product-dashboard-summary.py" \
    "python3 scripts/ops/posthog-product-dashboard-summary.py --self-test && python3 scripts/ops/posthog-product-dashboard-summary.py --fixture Tests/Fixtures/posthog-product-dashboard-summary.json --json-only > $(shell_quote "${RAW_DIR}/posthog-product-tasks.json")"

  run_gemma_summary_plan
}

run_live_tail() {
  run_step "40-live-capture" "Live mic and system-audio capture smoke" "yes" \
    "bash run-live-capture-smoke.sh --skip-build --duration $(shell_quote "${LIVE_DURATION}")"
}

run_ui_tail() {
  run_step "04-ui-smoke" "UI automation smoke" "yes" \
    "TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift run --package-path Tools/TranscriptedQA transcripted-qa ui-smoke --app build/Transcripted.app --report $(shell_quote "${RAW_DIR}/ui-automation-smoke.json")"
}

run_sparkle_update_tail() {
  run_step "05-sparkle-update-smoke" "No-publish Sparkle update UI smoke" "yes" \
    "TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift run --package-path Tools/TranscriptedQA transcripted-qa sparkle-update-smoke --app build/Transcripted.app --output $(shell_quote "${RAW_DIR}/sparkle-update-smoke")"
}

run_packaged_tail() {
  if [[ "${SKIP_BUILD}" -eq 1 ]]; then
    skip_step "69-build-beta-smoke" "No-publish build-beta package smoke"
  else
    run_step "69-build-beta-smoke" "No-publish build-beta package smoke" "yes" \
      "SKIP_NOTARIZATION=1 REQUIRE_BUNDLED_PARAKEET_MODELS=0 BUNDLE_PARAKEET_MODELS=0 REQUIRE_BUNDLED_DIARIZER_MODELS=0 BUNDLE_DIARIZER_MODELS=0 bash build-beta.sh '' $(shell_quote "${PACKAGED_USER_NAME}")"
  fi

  run_step "70-packaged-app-smoke" "Packaged app smoke" "yes" \
    "TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift run --package-path Tools/TranscriptedQA transcripted-qa packaged-app-smoke --app build/Transcripted.app --dsym build/Transcripted.app.dSYM --run-ui-smoke --report $(shell_quote "${RAW_DIR}/packaged-app-smoke.json") --ui-report $(shell_quote "${RAW_DIR}/packaged-app-ui-smoke.json")"
}

run_corpus_tail() {
  local selected_ids="${1:-${CORPUS_IDS}}"
  local ids_arg=""
  if [[ -n "${selected_ids}" ]]; then
    ids_arg=" --ids $(shell_quote "${selected_ids}")"
  fi

  run_step "50-meeting-corpus" "Private meeting corpus validation" "yes" \
    "python3 scripts/ops/validate-meeting-corpus.py --corpus-root $(shell_quote "${CORPUS_ROOT}")${ids_arg} --json-out $(shell_quote "${RAW_DIR}/meeting-corpus.json") --markdown-out $(shell_quote "${OUT}/meeting-corpus-report.md") --subset-out $(shell_quote "${OUT}/meeting-corpus-subset.json")"
}

run_corpus_compare_tail() {
  local selected_ids="${1:-${CORPUS_IDS:-${CORPUS_COMPARE_DEFAULT_IDS}}}"
  local ids_arg=""
  local map_arg=""
  if [[ -n "${selected_ids}" ]]; then
    ids_arg=" --ids $(shell_quote "${selected_ids}")"
  fi
  if [[ -n "${CORPUS_CANDIDATE_MAP}" ]]; then
    map_arg=" --candidate-map $(shell_quote "${CORPUS_CANDIDATE_MAP}")"
  fi

  run_step "51-meeting-corpus-compare" "Compare Transcripted output with Zoom corpus truth" "yes" \
    "python3 scripts/ops/compare-meeting-corpus.py --corpus-root $(shell_quote "${CORPUS_ROOT}") --transcripted-output-dir $(shell_quote "${CORPUS_OUTPUT_DIR}")${map_arg}${ids_arg} --min-recall $(shell_quote "${CORPUS_MIN_RECALL}") --min-content-recall $(shell_quote "${CORPUS_MIN_CONTENT_RECALL}") --json-out $(shell_quote "${RAW_DIR}/meeting-corpus-comparison.json") --markdown-out $(shell_quote "${OUT}/meeting-corpus-comparison-report.md")"
}

run_scorecard_tail() {
  local fixtures="scripts/ops/fixtures/board-scorecard"
  local acc="${RAW_DIR}"

  # Functional evidence: validate-all JSON (non-blocking — we still want to score).
  run_step "60-scorecard-validate" "Scorecard functional evidence (validate-all)" "no" \
    "TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift run --package-path Tools/TranscriptedQA transcripted-qa validate-all --format json > $(shell_quote "${RAW_DIR}/validate-all.json")"

  # UI evidence: only when a built app is present and we are not headless.
  if [[ -d "${REPO_ROOT}/build/Transcripted.app" ]]; then
    run_step "61-scorecard-ui" "Scorecard UI evidence (ui-smoke)" "no" \
      "TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift run --package-path Tools/TranscriptedQA transcripted-qa ui-smoke --app build/Transcripted.app --report $(shell_quote "${RAW_DIR}/scorecard-ui-smoke.json")"
  else
    skip_step "61-scorecard-ui" "Scorecard UI evidence (build/Transcripted.app missing)"
  fi

  # Accuracy evidence: opt-in via env. Each scorer writes score-<board>.json into RAW_DIR.
  # We never feed synthetic demo fixtures as if they were real product output.
  if [[ -n "${TRANSCRIPTED_QA_DIARIZATION_SEGMENTS:-}" ]]; then
    run_step "62-scorecard-diarization" "Scorecard diarization accuracy" "no" \
      "python3 scripts/ops/score-diarization.py --segments $(shell_quote "${TRANSCRIPTED_QA_DIARIZATION_SEGMENTS}") --out $(shell_quote "${acc}/score-diarization.json")"
  fi
  if [[ -n "${TRANSCRIPTED_QA_DICTATION_CANDIDATE:-}" ]]; then
    run_step "63-scorecard-dictation" "Scorecard dictation correction accuracy" "no" \
      "python3 scripts/ops/score-dictation.py --fixture ${fixtures}/dictation-corrections.json --candidate $(shell_quote "${TRANSCRIPTED_QA_DICTATION_CANDIDATE}") --out $(shell_quote "${acc}/score-dictation.json")"
  fi
  if [[ -n "${TRANSCRIPTED_QA_DETECTION_CANDIDATE:-}" ]]; then
    run_step "64-scorecard-detection" "Scorecard meeting-detection accuracy" "no" \
      "python3 scripts/ops/score-detection.py --fixture ${fixtures}/meeting-detection.json --candidate $(shell_quote "${TRANSCRIPTED_QA_DETECTION_CANDIDATE}") --out $(shell_quote "${acc}/score-detection.json")"
  fi
  if [[ -n "${TRANSCRIPTED_QA_SUMMARY_JUDGE:-}" ]]; then
    run_step "65-scorecard-summary" "Scorecard meeting-summary accuracy" "no" \
      "python3 scripts/ops/score-summary-judge.py --mode score --judge-result $(shell_quote "${TRANSCRIPTED_QA_SUMMARY_JUDGE}") --out $(shell_quote "${acc}/score-summary.json")"
  fi
  if [[ -n "${TRANSCRIPTED_QA_TRANSCRIPTION_SCORE:-}" ]]; then
    run_step "66-scorecard-transcription" "Scorecard transcription accuracy input" "no" \
      "cp $(shell_quote "${TRANSCRIPTED_QA_TRANSCRIPTION_SCORE}") $(shell_quote "${acc}/score-transcription.json")"
  fi

  local ui_arg=""
  if [[ -f "${RAW_DIR}/scorecard-ui-smoke.json" ]]; then
    ui_arg=" --ui-json $(shell_quote "${RAW_DIR}/scorecard-ui-smoke.json")"
  fi
  local functional_arg=""
  if [[ -s "${RAW_DIR}/validate-all.json" ]]; then
    functional_arg=" --functional-json $(shell_quote "${RAW_DIR}/validate-all.json")"
  fi
  run_step "67-scorecard" "Aggregate board scorecard" "yes" \
    "python3 scripts/ops/score-boards.py --registry .agents/board-scorecard.yml${ui_arg}${functional_arg} --accuracy-dir $(shell_quote "${acc}") --json-out $(shell_quote "${RAW_DIR}/board-scorecard.json") --markdown-out $(shell_quote "${OUT}/board-scorecard.md")"
}

cd "${REPO_ROOT}" || exit 1
write_manual_scenarios

echo "Transcripted QA bench"
echo "Mode: ${MODE}"
echo "Run id: ${RUN_ID}"
echo "Artifacts: ${OUT}"
echo

case "${MODE}" in
  quick)
    run_quick
    ;;
  deep)
    run_quick
    run_deep_tail
    ;;
  full)
    run_quick
    run_deep_tail
    run_full_tail
    ;;
  ui)
    run_step "00-preflight" "Agent preflight" "no" "bash scripts/dev/agent-preflight.sh"
    if [[ "${SKIP_BUILD}" -eq 1 ]]; then
      skip_step "01-build" "Build app"
    else
      run_step "01-build" "Build app" "yes" "bash build.sh --no-open"
    fi
    run_ui_tail
    ;;
  sparkle-update)
    run_step "00-preflight" "Agent preflight" "no" "bash scripts/dev/agent-preflight.sh"
    if [[ "${SKIP_BUILD}" -eq 1 ]]; then
      skip_step "01-build" "Build app"
    else
      run_step "01-build" "Build app" "yes" "bash build.sh --no-open"
    fi
    run_sparkle_update_tail
    ;;
  packaged)
    run_step "00-preflight" "Agent preflight" "no" "bash scripts/dev/agent-preflight.sh"
    run_packaged_tail
    ;;
  artifact)
    run_step "00-preflight" "Agent preflight" "no" "bash scripts/dev/agent-preflight.sh"
    run_artifact_validation "yes"
    ;;
  audio-synthetic)
    run_step "30-audio-synthetic" "Synthetic audio reliability matrix" "yes" \
      "bash run-daily-audio-reliability.sh --synthetic"
    ;;
  pasteback-synthetic)
    run_step "00-preflight" "Agent preflight" "no" "bash scripts/dev/agent-preflight.sh"
    run_pasteback_synthetic
    ;;
  corpus)
    run_step "00-preflight" "Agent preflight" "no" "bash scripts/dev/agent-preflight.sh"
    run_corpus_tail
    ;;
  corpus-compare)
    run_step "00-preflight" "Agent preflight" "no" "bash scripts/dev/agent-preflight.sh"
    corpus_compare_ids="${CORPUS_IDS:-${CORPUS_COMPARE_DEFAULT_IDS}}"
    run_corpus_tail "${corpus_compare_ids}"
    run_corpus_compare_tail "${corpus_compare_ids}"
    ;;
  scorecard)
    run_step "00-preflight" "Agent preflight" "no" "bash scripts/dev/agent-preflight.sh"
    run_scorecard_tail
    ;;
  live)
    run_quick
    run_deep_tail
    run_full_tail
    if run_permission_state; then
      run_live_tail
    else
      skip_step "40-live-capture" "Live mic and system-audio capture smoke skipped after permission-state preflight"
    fi
    ;;
esac

write_report
exit $?
