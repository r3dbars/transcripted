#!/bin/bash
# check.sh — one command for "is my change good?". Pick a tier:
#
#   changed   (default) the checks your diff needs, picked from .agents/test-matrix.yml
#             by scripts/dev/agent-check.py, which also writes build/agent-proof.json
#   quick     a minute or two, no Swift build: every Linux-safe repo check,
#             including the test-shape guard (scripts/dev/linux-checks.sh)
#   full      what Swift CI runs on a PR, in the same order
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
  full       everything Swift CI runs on a PR
  hardware   real mic, system audio and paste-back smokes on this Mac

  --base <ref>    diff base for "changed" (default origin/main)
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
        step "Build-source list contracts" "python3 scripts/dev/check-build-source-lists.py"
        step "Test shape guard" "python3 scripts/dev/check-test-shape.py"
        step "Dependency archive input guards" "bash Tests/BuildDependencies/ArchiveInputsTests.sh"
        step "CLI manifest mode guards" "bash Tests/BuildDependencies/CLIManifestTests.sh"
        step "CLI packaging capability guards" "bash Tests/BuildDependencies/CLIPackagingTests.sh"
        step "Fast tests" "bash run-tests.sh"
        step "E2E smoke" "bash run-e2e-smoke.sh"
        step "Build dependencies" "bash build-deps.sh"
        step "Concurrency census (Swift 6 backlog can't grow)" "bash scripts/dev/concurrency-census.sh --check"
        step "Core package tests" "swift test"
        step "Integration smoke" "bash run-integration-smoke.sh"
        step "Tools: CaptureKit" "swift test --package-path Tools/TranscriptedCaptureKit"
        step "Tools: CLI" "swift test --package-path Tools/TranscriptedCLI"
        step "Tools: MCP" "swift test --package-path Tools/TranscriptedMCP"
        step "Tools: QA" "swift test --package-path Tools/TranscriptedQA"
        step "Build app" "bash build.sh --no-open"
        ;;
    hardware)
        step "Build app" "bash build.sh --no-open"
        step "Live capture smoke (real mic + system audio)" "bash run-live-capture-smoke.sh --skip-build"
        step "Slow paste-back smoke" "bash run-slow-pasteback-smoke.sh"
        ;;
esac

summary
