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
LIVE_DURATION="${TRANSCRIPTED_QA_LIVE_DURATION:-2.0}"
CORPUS_ROOT="${TRANSCRIPTED_QA_CORPUS_ROOT:-${HOME}/Downloads/meeting-corpus}"
CORPUS_IDS="${TRANSCRIPTED_QA_CORPUS_IDS:-}"
CORPUS_OUTPUT_DIR="${TRANSCRIPTED_QA_CORPUS_OUTPUT_DIR:-${CORPUS_ROOT}/transcripted-output}"
CORPUS_CANDIDATE_MAP="${TRANSCRIPTED_QA_CORPUS_CANDIDATE_MAP:-}"
CORPUS_MIN_RECALL="${TRANSCRIPTED_QA_CORPUS_MIN_RECALL:-0.45}"
CORPUS_MIN_CONTENT_RECALL="${TRANSCRIPTED_QA_CORPUS_MIN_CONTENT_RECALL:-0.35}"

usage() {
  cat <<'USAGE'
Usage: bash scripts/ops/transcripted-qa-bench.sh [--mode quick|deep|artifact|audio-synthetic|corpus|corpus-compare|live] [options]

Runs a local Transcripted QA bench and writes:
  /tmp/transcripted-qa-bench/<run-id>/qa-report.md

Modes:
  quick            build, fast tests, deterministic E2E smoke
  deep             quick + integration, Core tests, QA CLI, synthetic audio
  artifact         validate current saved Transcripted artifacts strictly
  audio-synthetic  run only the deterministic audio failure-shape matrix
  corpus           validate a local private meeting corpus
  corpus-compare   validate corpus, then compare Transcripted Markdown to Zoom truth
  live             deep + live mic/system-audio smoke

Options:
  --skip-build          Do not run build.sh in quick/deep/live modes.
  --strict-artifacts    Make live artifact validation blocking in deep/live mode.
  --duration seconds    Live capture duration. Default: 2.0
  --corpus-root path    Meeting corpus root. Default: ~/Downloads/meeting-corpus
  --corpus-ids ids      Comma-separated meeting ids to validate.
  --corpus-output-dir path
                       Transcripted Markdown output dir for corpus-compare.
                       Default: ~/Downloads/meeting-corpus/transcripted-output
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
  quick|deep|artifact|audio-synthetic|corpus|corpus-compare|live) ;;
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
  local fail_count warn_count skip_count pass_count verdict branch commit app_version started finished

  fail_count="$(awk -F '\t' '$3 == "FAIL" { count++ } END { print count + 0 }' "${RESULTS}")"
  warn_count="$(awk -F '\t' '$3 == "WARN" { count++ } END { print count + 0 }' "${RESULTS}")"
  skip_count="$(awk -F '\t' '$3 == "SKIP" { count++ } END { print count + 0 }' "${RESULTS}")"
  pass_count="$(awk -F '\t' '$3 == "PASS" { count++ } END { print count + 0 }' "${RESULTS}")"

  if [[ "${fail_count}" -gt 0 ]]; then
    verdict="FAIL"
  elif [[ "${warn_count}" -gt 0 || "${skip_count}" -gt 0 ]]; then
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

  if ! {
    echo "# Transcripted QA Bench Report"
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
    echo "- Skipped: ${skip_count}"
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
    echo "## Evidence Index"
    echo
    find "${LOG_DIR}" -maxdepth 1 -type f -name '*.log' -print | sort | sed 's#^#- `#; s#$#`#'
  } > "${REPORT}"; then
    fail_io "Unable to write QA report at ${REPORT}."
  fi

  echo
  echo "[qa] Report: ${REPORT}"
  echo "[qa] Verdict: ${verdict}"

  if [[ "${fail_count}" -gt 0 ]]; then
    return 1
  fi
  if [[ "${warn_count}" -gt 0 || "${skip_count}" -gt 0 ]]; then
    return 3
  fi
  return 0
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
}

run_artifact_validation() {
  local blocking="$1"
  run_step "20-qa-health" "TranscriptedQA health check" "${blocking}" \
    "TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift run --package-path Tools/TranscriptedQA transcripted-qa check-health --format json"
  run_step "21-qa-validate-all" "TranscriptedQA validate current artifacts" "${blocking}" \
    "TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift run --package-path Tools/TranscriptedQA transcripted-qa validate-all --format json"
}

run_deep_tail() {
  run_step "10-integration-smoke" "Integration smoke" "yes" "bash run-integration-smoke.sh"
  run_step "11-core-swift-test" "TranscriptedCore swift test" "yes" "swift test"
  run_step "12-qa-cli-tests" "TranscriptedQA package tests" "yes" "swift test --package-path Tools/TranscriptedQA"
  run_step "13-qa-round-trip" "TranscriptedQA validator round trip" "yes" \
    "swift run --package-path Tools/TranscriptedQA transcripted-qa round-trip"
  run_step "14-qa-stress-small" "TranscriptedQA small stress pass" "yes" \
    "swift run --package-path Tools/TranscriptedQA transcripted-qa stress-test --transcripts 12 --speakers-per-transcript 4 --utterances-per-transcript 80"

  if [[ "${STRICT_ARTIFACTS}" -eq 1 ]]; then
    run_artifact_validation "yes"
  else
    run_artifact_validation "no"
  fi

  run_step "30-audio-synthetic" "Synthetic audio reliability matrix" "yes" \
    "bash run-daily-audio-reliability.sh --synthetic"
}

run_live_tail() {
  run_step "40-live-capture" "Live mic and system-audio capture smoke" "yes" \
    "bash run-live-capture-smoke.sh --skip-build --duration $(shell_quote "${LIVE_DURATION}")"
}

run_corpus_tail() {
  local ids_arg=""
  if [[ -n "${CORPUS_IDS}" ]]; then
    ids_arg=" --ids $(shell_quote "${CORPUS_IDS}")"
  fi

  run_step "50-meeting-corpus" "Private meeting corpus validation" "yes" \
    "python3 scripts/ops/validate-meeting-corpus.py --corpus-root $(shell_quote "${CORPUS_ROOT}")${ids_arg} --json-out $(shell_quote "${RAW_DIR}/meeting-corpus.json") --markdown-out $(shell_quote "${OUT}/meeting-corpus-report.md") --subset-out $(shell_quote "${OUT}/meeting-corpus-subset.json")"
}

run_corpus_compare_tail() {
  local ids_arg=""
  local map_arg=""
  if [[ -n "${CORPUS_IDS}" ]]; then
    ids_arg=" --ids $(shell_quote "${CORPUS_IDS}")"
  fi
  if [[ -n "${CORPUS_CANDIDATE_MAP}" ]]; then
    map_arg=" --candidate-map $(shell_quote "${CORPUS_CANDIDATE_MAP}")"
  fi

  run_step "51-meeting-corpus-compare" "Compare Transcripted output with Zoom corpus truth" "yes" \
    "python3 scripts/ops/compare-meeting-corpus.py --corpus-root $(shell_quote "${CORPUS_ROOT}") --transcripted-output-dir $(shell_quote "${CORPUS_OUTPUT_DIR}")${map_arg}${ids_arg} --min-recall $(shell_quote "${CORPUS_MIN_RECALL}") --min-content-recall $(shell_quote "${CORPUS_MIN_CONTENT_RECALL}") --json-out $(shell_quote "${RAW_DIR}/meeting-corpus-comparison.json") --markdown-out $(shell_quote "${OUT}/meeting-corpus-comparison-report.md")"
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
  artifact)
    run_step "00-preflight" "Agent preflight" "no" "bash scripts/dev/agent-preflight.sh"
    run_artifact_validation "yes"
    ;;
  audio-synthetic)
    run_step "30-audio-synthetic" "Synthetic audio reliability matrix" "yes" \
      "bash run-daily-audio-reliability.sh --synthetic"
    ;;
  corpus)
    run_step "00-preflight" "Agent preflight" "no" "bash scripts/dev/agent-preflight.sh"
    run_corpus_tail
    ;;
  corpus-compare)
    run_step "00-preflight" "Agent preflight" "no" "bash scripts/dev/agent-preflight.sh"
    run_corpus_tail
    run_corpus_compare_tail
    ;;
  live)
    run_quick
    run_deep_tail
    run_live_tail
    ;;
esac

write_report
exit $?
