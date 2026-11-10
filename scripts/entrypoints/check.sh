#!/bin/bash
# check.sh — one command for "is my change good?". Pick a tier:
#
#   changed   (default) the checks your diff needs, picked from .agents/test-matrix.yml
#             by scripts/dev/agent-check.py, which also writes build/agent-proof.json
#   quick     a minute or two, no Swift build: every Linux-safe repo check,
#             including the test-shape guard (scripts/dev/linux-checks.sh)
#   full      the same validation steps as Swift CI on a PR
#   hardware  the real-world smokes: real mic, system audio and paste-back on
#             this Mac (needs Microphone and System Audio Recording permission)
#
# Each step prints PASS or FAIL with its time, and the summary gives the exact
# command to re-run a failed step on its own. Steps run one at a time because
# build.sh and run-tests.sh share build output.

set -uo pipefail

ENTRYPOINT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ENTRYPOINT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

usage() {
    cat <<'EOF'
Usage: bash check.sh [changed|quick|full|hardware] [--base <ref>] [--keep-going]

  changed    (default) run the checks your diff needs, from .agents/test-matrix.yml
  quick      Linux-safe repo checks plus the test-shape guard; no Swift build
  full       the same validation steps as Swift CI on a PR
  hardware   real mic, system audio and paste-back smokes on this Mac

  --base <ref>    diff base for "changed" (default origin/main); uncommitted and
                  untracked files count too
  --keep-going    in full/hardware, run every step even after a failure
EOF
}

tier="changed"
base="origin/main"
keep_going=false
while [ $# -gt 0 ]; do
    case "$1" in
        changed|quick|full|hardware) tier="$1" ;;
        --base) shift; base="${1:?--base needs a ref}" ;;
        --base=*) base="${1#*=}" ;;
        --keep-going) keep_going=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1"; usage; exit 2 ;;
    esac
    shift
done

export TZ="${TZ:-America/Chicago}"
export TRANSCRIPTED_DISABLE_FILE_LOGGER=1

names=()
statuses=()
seconds=()
commands=()
failed=false

step() {
    local name="$1" command="$2"
    if [ "$failed" = true ] && [ "$keep_going" = false ]; then
        names+=("$name"); statuses+=("SKIP"); seconds+=("-"); commands+=("$command")
        return
    fi
    echo ""
    echo "==> $name"
    echo "    $command"
    local started status
    started=$(date +%s)
    bash -c "$command"
    status=$?
    local took=$(( $(date +%s) - started ))
    names+=("$name"); seconds+=("${took}s"); commands+=("$command")
    if [ "$status" -eq 0 ]; then
        statuses+=("PASS")
    else
        statuses+=("FAIL")
        failed=true
    fi
}

summary() {
    echo ""
    echo "---- check.sh $tier ----"
    local i
    for i in "${!names[@]}"; do
        printf '%-4s %6s  %s\n' "${statuses[$i]}" "${seconds[$i]}" "${names[$i]}"
    done
    if [ "$failed" = true ]; then
        echo ""
        echo "Re-run a failed step on its own:"
        for i in "${!names[@]}"; do
            if [ "${statuses[$i]}" = "FAIL" ]; then
                echo "  ${commands[$i]}"
            fi
        done
        echo ""
        echo "RESULT: FAIL"
        return 1
    fi
    echo ""
    echo "RESULT: PASS"
    return 0
}

case "$tier" in
    changed)
        # agent-check.py prints each command and its result, and writes the proof report.
        python3 scripts/dev/agent-check.py --base "$base"
        exit $?
        ;;
    quick)
        step "Linux-safe repo checks (incl. test shape)" "bash scripts/dev/linux-checks.sh"
        ;;
    full)
        # Match CI's clean CLI environment even when this shell was used for
        # an opt-in audio, meeting or bundled-helper build earlier.
        unset TRANSCRIPTEDCLI_ENABLE_TRANSCRIPTION TRANSCRIPTEDCLI_ENABLE_DIARIZATION
        unset TRANSCRIPTEDCLI_ENABLE_MEETING_IMPORT TRANSCRIPTEDCLI_BUNDLED_HELPER
        unset TRANSCRIPTEDCLI_EXPECT_BUILD_MODE
        step "Build-source list contracts" "python3 scripts/dev/check-build-source-lists.py"
        step "Test shape guard" "python3 scripts/dev/check-test-shape.py"
        step "Synced copies (self-test)" "python3 scripts/dev/check-synced-copies.py --self-test"
        step "Synced copies" "python3 scripts/dev/check-synced-copies.py"
        step "Dependency archive input guards" "bash Tests/BuildDependencies/ArchiveInputsTests.sh"
        step "CLI manifest mode guards" "bash Tests/BuildDependencies/CLIManifestTests.sh"
        step "CLI packaging capability guards" "bash Tests/BuildDependencies/CLIPackagingTests.sh"
        step "Fast tests" "bash run-tests.sh"
        step "E2E smoke" "bash run-e2e-smoke.sh"
        step "Build dependencies" "bash build-deps.sh"
        step "Concurrency census (Swift 6 backlog can't grow)" "bash scripts/dev/concurrency-census.sh --check"
        step "Core package tests" "swift test"
        step "Integration smoke" "bash run-integration-smoke.sh"
        step "Speaker settings model smoke" "bash scripts/dev/test-speaker-settings-model.sh"
        step "Speakers directory scroll smoke" "bash scripts/dev/test-speakers-directory-scroll.sh"
        step "Tools: CaptureKit" "swift test --package-path Tools/TranscriptedCaptureKit"
        step "Tools: CLI" "swift test --package-path Tools/TranscriptedCLI"
        step "Tools: MCP" "swift test --package-path Tools/TranscriptedMCP"
        step "Tools: QA" "swift test --package-path Tools/TranscriptedQA"
        step "Tools: Live" "swift test --package-path Tools/TranscriptedLive"
        step "CLI mode: audio" "TRANSCRIPTEDCLI_EXPECT_BUILD_MODE=audio TRANSCRIPTEDCLI_ENABLE_TRANSCRIPTION=1 swift test --package-path Tools/TranscriptedCLI"
        step "CLI mode: meeting" "TRANSCRIPTEDCLI_EXPECT_BUILD_MODE=meeting TRANSCRIPTEDCLI_ENABLE_MEETING_IMPORT=1 swift test --package-path Tools/TranscriptedCLI"
        step "CLI mode: retrieval" "TRANSCRIPTEDCLI_EXPECT_BUILD_MODE=retrieval swift test --package-path Tools/TranscriptedCLI"
        # A skipped launch must not reuse a report from a previous build.
        receipt_step=${#statuses[@]}
        step "Invalidate previous launch receipt" 'if [ -L build ] || { [ -e build ] && [ ! -d build ]; }; then
            echo "Refusing to clear a launch receipt through an unowned build directory" >&2
            exit 1
        fi
        rm -f build/launch-ui-smoke.json'
        # A failed ownership/reset prerequisite also blocks this dependent
        # build when --keep-going was requested for independent checks.
        if [ "${statuses[$receipt_step]:-SKIP}" = PASS ]; then
            step "Build app" "bash build.sh --no-open"
            step "Premium performance budget" 'scripts/ops/performance-budget.rb --check-home-recent-captures --allow-missing-parakeet-model --max-app-mb 220 --max-resources-mb 80 --launch-ui-smoke build/launch-ui-smoke.json --max-launch-interactive-ms "${TRANSCRIPTED_MAX_LAUNCH_INTERACTIVE_MS:-3000}"'
        fi
        ;;
    hardware)
        step "Build app" "bash build.sh --no-open"
        step "Live capture smoke (real mic + system audio)" "bash run-live-capture-smoke.sh --skip-build"
        step "Slow paste-back smoke" "bash run-slow-pasteback-smoke.sh"
        ;;
esac

summary
