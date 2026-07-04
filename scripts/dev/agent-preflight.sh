#!/bin/bash
# Print the repo facts an agent should check before editing or handing off.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

base_ref="${1:-origin/main}"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Not inside a git worktree."
    exit 1
fi

if ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    base_ref="HEAD"
fi

if merge_base="$(git merge-base HEAD "$base_ref" 2>/dev/null)"; then
    diff_base="$merge_base"
else
    diff_base="$base_ref"
fi

branch="$(git branch --show-current || true)"
head_sha="$(git rev-parse --short HEAD)"

echo "Transcripted agent preflight"
echo ""
echo "Branch: ${branch:-detached HEAD}"
echo "HEAD: $head_sha"
echo "Base: $base_ref"
echo ""

echo "Worktree:"
git status --short
echo ""

changed_paths="$(
    {
        git diff --name-only "$diff_base"...HEAD 2>/dev/null || true
        git diff --cached --name-only 2>/dev/null || true
        git diff --name-only 2>/dev/null || true
        git ls-files --others --exclude-standard 2>/dev/null || true
    } | sed '/^[[:space:]]*$/d' | sort -u
)"

echo "Changed paths:"
if [ -n "$changed_paths" ]; then
    printf '%s\n' "$changed_paths" | sed 's/^/- /'
else
    echo "- none"
fi
echo ""

commands=()
add_command() {
    local command="$1"
    local existing
    for existing in "${commands[@]:-}"; do
        [ "$existing" = "$command" ] && return 0
    done
    commands+=("$command")
}

matches_any() {
    local path="$1"
    shift
    local pattern
    for pattern in "$@"; do
        case "$path" in
            $pattern) return 0 ;;
        esac
    done
    return 1
}

if [ -n "$changed_paths" ]; then
    while IFS= read -r path; do
        if matches_any "$path" "Sources/*.swift" "Sources/*/*.swift" "Sources/*/*/*.swift" "Sources/*/*/*/*.swift" "Tests/*.swift" "Tests/*/*.swift" "Tests/*/*/*.swift" "Tests/FastTests.manifest"; then
            add_command "bash build.sh --no-open"
            add_command "bash run-tests.sh"
        fi

        if matches_any "$path" "Info.plist"; then
            add_command "bash build.sh --no-open"
            add_command "bash run-tests.sh"
        fi

        if matches_any "$path" "Sources/Meeting/*" "Sources/TranscriptedCore/*" "Tests/Integration/*"; then
            add_command "bash build-deps.sh --force"
            add_command "bash build.sh --no-open"
            add_command "bash run-tests.sh"
            add_command "bash run-integration-smoke.sh"
        fi

        if matches_any "$path" "Tests/E2E/*" "run-e2e-smoke.sh" "scripts/entrypoints/run-e2e-smoke.sh"; then
            add_command "python3 scripts/dev/check-build-source-lists.py"
            add_command "bash run-e2e-smoke.sh"
        fi

        if matches_any "$path" "Tests/E2E/SlowPastebackSmoke.swift" "Sources/Support/ClipboardRestoringTextPaster.swift" "Sources/Support/TranscriptedConstants.swift" "run-slow-pasteback-smoke.sh" "scripts/entrypoints/run-slow-pasteback-smoke.sh"; then
            add_command "python3 scripts/dev/check-build-source-lists.py"
            add_command "bash run-slow-pasteback-smoke.sh"
        fi

        if matches_any "$path" "build-deps.sh" "scripts/entrypoints/build-deps.sh"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "bash -n build-deps.sh"
            add_command "bash -n scripts/entrypoints/build-deps.sh"
            add_command "bash build-deps.sh --force"
        fi

        if matches_any "$path" "build.sh" "scripts/entrypoints/build.sh" "scripts/entrypoints/lib/swiftc-app-args.sh"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "python3 scripts/dev/check-build-source-lists.py"
            add_command "bash -n build.sh"
            add_command "bash -n scripts/entrypoints/build.sh"
            add_command "bash build.sh --no-open"
        fi

        if matches_any "$path" "run-tests.sh" "scripts/entrypoints/run-tests.sh" "Tests/FastTests.manifest"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "python3 scripts/dev/check-build-source-lists.py"
            add_command "bash -n run-tests.sh"
            add_command "bash -n scripts/entrypoints/run-tests.sh"
            add_command "bash run-tests.sh"
        fi

        if matches_any "$path" "run-integration-smoke.sh" "scripts/entrypoints/run-integration-smoke.sh" "Tests/Integration/*"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "bash -n run-integration-smoke.sh"
            add_command "bash -n scripts/entrypoints/run-integration-smoke.sh"
            add_command "bash build-deps.sh --force"
            add_command "bash run-integration-smoke.sh"
        fi

        if matches_any "$path" "run-daily-audio-reliability.sh" "scripts/ops/daily-audio-reliability-check.sh"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "bash -n run-daily-audio-reliability.sh"
            add_command "bash -n scripts/ops/daily-audio-reliability-check.sh"
        fi

        if matches_any "$path" "scripts/ops/health-probe.sh"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "bash -n scripts/ops/health-probe.sh"
        fi

        if matches_any "$path" "scripts/ops/release-health-card.py"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "python3 -m py_compile scripts/ops/release-health-card.py"
            add_command "python3 scripts/ops/release-health-card.py --self-test"
        fi

        if matches_any "$path" "scripts/ops/posthog-product-dashboard-summary.py" "Tests/Fixtures/posthog-product-dashboard-summary.json"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "python3 -m py_compile scripts/ops/posthog-product-dashboard-summary.py"
            add_command "python3 scripts/ops/posthog-product-dashboard-summary.py --self-test"
            add_command "python3 scripts/ops/posthog-product-dashboard-summary.py --fixture Tests/Fixtures/posthog-product-dashboard-summary.json --json-only"
        fi

        if matches_any "$path" "scripts/dev/onboarding.sh"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "bash -n scripts/dev/onboarding.sh"
        fi

        if matches_any "$path" "scripts/dev/check-build-source-lists.py"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "python3 -m py_compile scripts/dev/check-build-source-lists.py"
            add_command "python3 scripts/dev/check-build-source-lists.py"
        fi

        if matches_any "$path" "scripts/dev/benchmark-home-recent-captures.sh" "Tests/Benchmarks/HomeRecentCaptureBenchmark.swift"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "bash -n scripts/dev/benchmark-home-recent-captures.sh"
            add_command "scripts/dev/benchmark-home-recent-captures.sh --max-average-load-ms 750 --max-cancellation-ms 100"
        fi

        if matches_any "$path" "scripts/ops/generate-nightly-digest.py"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "python3 -m py_compile scripts/ops/generate-nightly-digest.py"
            add_command "python3 scripts/ops/generate-nightly-digest.py --self-test"
        fi

        if matches_any "$path" "scripts/ops/posthog-product-context-pack.py" "Tests/Fixtures/posthog-product-context-pack-fixture.json"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "python3 -m py_compile scripts/ops/posthog-product-context-pack.py"
            add_command "python3 scripts/ops/posthog-product-context-pack.py --self-test"
            add_command "python3 scripts/ops/posthog-product-context-pack.py --fixture Tests/Fixtures/posthog-product-context-pack-fixture.json --write-dir build/posthog-product-context-sample"
        fi

        if matches_any "$path" "scripts/ops/posthog-dashboard-queries.py" "Tests/Fixtures/posthog-dashboard-query-results.json" "docs/posthog-dashboard-query-helpers.md"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "python3 -m py_compile scripts/ops/posthog-dashboard-queries.py"
            add_command "python3 scripts/ops/posthog-dashboard-queries.py --self-test"
        fi

        if matches_any "$path" "scripts/ops/nightly-security-check.py"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "python3 -m py_compile scripts/ops/nightly-security-check.py"
            add_command "python3 scripts/ops/nightly-security-check.py --strict --automation-toml Tests/Fixtures/nightly-security-automation.toml --github-release-json Tests/Fixtures/release-health-github-release-1.1.48.json --write-report build/nightly-security-report.json"
        fi

        if matches_any "$path" "scripts/ops/release-gate-report.py"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "python3 -m py_compile scripts/ops/release-gate-report.py"
            add_command "python3 scripts/ops/release-gate-report.py --self-test"
        fi

        if matches_any "$path" "scripts/release/post-dmg-release-audit.py"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "python3 -m py_compile scripts/release/post-dmg-release-audit.py"
            add_command "python3 scripts/release/post-dmg-release-audit.py --self-test"
        fi

        if matches_any "$path" "scripts/release/bump-release-version.py"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "python3 -m py_compile scripts/release/bump-release-version.py"
            add_command "python3 scripts/release/bump-release-version.py --self-test"
            add_command "python3 scripts/release/bump-release-version.py --version 1.1.49 --dry-run"
        fi

        if matches_any "$path" "scripts/ops/packaged-app-smoke.py"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "python3 -m py_compile scripts/ops/packaged-app-smoke.py"
            add_command "python3 scripts/ops/packaged-app-smoke.py --self-test"
        fi

        if matches_any "$path" "scripts/ops/privacy-leak-sweep.py"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "python3 -m py_compile scripts/ops/privacy-leak-sweep.py"
            add_command "python3 scripts/ops/privacy-leak-sweep.py --write-report build/privacy-leak-sweep-report.json"
        fi

        if matches_any "$path" "scripts/ops/build-codex-memory-index.py"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "python3 -m py_compile scripts/ops/build-codex-memory-index.py"
        fi

        if matches_any "$path" "scripts/ops/nightly-transcripted-archive-miner.sh"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "bash -n scripts/ops/nightly-transcripted-archive-miner.sh"
        fi

        if matches_any "$path" "scripts/ops/performance-budget.rb"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "ruby -c scripts/ops/performance-budget.rb"
        fi

        if matches_any "$path" "scripts/ops/transcripted-qa-bench.sh" "scripts/ops/run-local-summary-fixture.sh" "scripts/ops/validate-meeting-corpus.py" "scripts/ops/compare-meeting-corpus.py" "docs/qa-test-bench.md"; then
            add_command "bash -n scripts/ops/transcripted-qa-bench.sh"
            add_command "bash -n scripts/ops/run-local-summary-fixture.sh"
            add_command "bash scripts/ops/run-local-summary-fixture.sh"
            add_command "bash scripts/ops/transcripted-qa-bench.sh --mode quick"
            add_command "swift test --package-path Tools/TranscriptedQA"
            add_command "python3 -m py_compile scripts/ops/validate-meeting-corpus.py"
            add_command "python3 -m py_compile scripts/ops/compare-meeting-corpus.py"
        fi

        if matches_any "$path" "scripts/ops/speaker-naming-simulator.py"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "python3 -m py_compile scripts/ops/speaker-naming-simulator.py"
            add_command "scripts/ops/speaker-naming-simulator.py"
            add_command "scripts/ops/speaker-naming-simulator.py --sweep"
        fi

        if matches_any "$path" "scripts/ops/dictation-stop-autoeval.sh" "scripts/ops/dictation-recovery-autoeval.rb" "docs/autoeval-dictation-stop-speed-*.md" "docs/autoeval-dictation-recovery-time-*.md"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "bash -n scripts/ops/dictation-stop-autoeval.sh"
            add_command "ruby -c scripts/ops/dictation-recovery-autoeval.rb"
        fi

        if matches_any "$path" "scripts/ops/dictation-recovery-autoeval.rb" "docs/autoeval-dictation-recovery-time-*.md" "docs/autoeval-dictation-start-time-*.md"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "ruby -c scripts/ops/dictation-recovery-autoeval.rb"
            add_command "ruby scripts/ops/dictation-recovery-autoeval.rb --details"
        fi

        if matches_any "$path" "scripts/ops/agent-todo-runner.rb" "scripts/ops/agent-todo-launchagent.sh" "scripts/ops/qa-gate-check.sh" "scripts/ops/qa-gate-closeout.sh"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "ruby -c scripts/ops/agent-todo-runner.rb"
            add_command "bash -n scripts/ops/agent-todo-launchagent.sh"
            add_command "bash -n scripts/ops/qa-gate-check.sh"
            add_command "bash -n scripts/ops/qa-gate-closeout.sh"
        fi

        if matches_any "$path" "Tests/TranscriptedCoreTests/LiveCaptureSmokeTests.swift" "run-live-capture-smoke.sh" "scripts/entrypoints/run-live-capture-smoke.sh"; then
            add_command "bash run-live-capture-smoke.sh --skip-build"
        fi

        if matches_any "$path" "Package.swift" "Sources/TranscriptedCore/*" "Tests/TranscriptedCoreTests/*"; then
            add_command "bash build-deps.sh --force"
            add_command "bash build.sh --no-open"
            add_command "bash run-tests.sh"
            add_command "bash run-integration-smoke.sh"
            add_command "swift test"
        fi

        if matches_any "$path" "Tools/TranscriptedCaptureKit/*"; then
            add_command "swift test --package-path Tools/TranscriptedCaptureKit"
            add_command "swift test --package-path Tools/TranscriptedCLI"
            add_command "swift test --package-path Tools/TranscriptedMCP"
            add_command "bash run-e2e-smoke.sh"
        fi

        if matches_any "$path" "Tools/TranscriptedCLI/*"; then
            add_command "swift test --package-path Tools/TranscriptedCLI"
        fi

        if matches_any "$path" "Tools/TranscriptedMCP/*"; then
            add_command "swift test --package-path Tools/TranscriptedMCP"
            add_command "bash run-e2e-smoke.sh"
        fi

        if matches_any "$path" "Tools/TranscriptedQA/*"; then
            add_command "swift test --package-path Tools/TranscriptedQA"
        fi

        if matches_any "$path" "Tools/SpeakerEvalHarness/*" "Tools/SpeakerEvalHarness/*/*" "Tools/SpeakerEvalHarness/*/*/*" "scripts/download_ami.sh" "scripts/run_speaker_eval.sh" "scripts/score_speaker_eval.py" "scripts/aggregate_sweep.py"; then
            add_command "scripts/dev/agent-preflight.sh"
            add_command "bash -n scripts/download_ami.sh"
            add_command "bash -n scripts/run_speaker_eval.sh"
            add_command "python3 -m py_compile scripts/score_speaker_eval.py"
            add_command "python3 -m py_compile scripts/aggregate_sweep.py"
            add_command "bash build-deps.sh --force"
            add_command "swift build --package-path Tools/SpeakerEvalHarness"
        fi

        if matches_any "$path" "build-beta.sh" "scripts/entrypoints/build-beta.sh" "scripts/release/*" "docs/release-packaging.md" "docs/sparkle-updates.md" "Casks/*" "docs/appcast.xml"; then
            add_command "bash build-deps.sh --force"
            add_command "bash build.sh --no-open"
            add_command "bash run-tests.sh"
            add_command "SKIP_NOTARIZATION=1 bash build-beta.sh '' <user-name>"
        fi

        if matches_any "$path" "README.md" "AGENT_START.md" "AGENTS.md" "CLAUDE.md" "CONTRIBUTING.md" "WORKFLOW.md" "docs/*" "Tests/README.md" "scripts/README.md" "Sources/CLAUDE.md" "Sources/*/CLAUDE.md" "Sources/*/*/CLAUDE.md" "Tools/README.md" "Tools/*/CLAUDE.md" "Tools/*/*/CLAUDE.md" ".agents/*" ".github/*" "scripts/dev/agent-preflight.sh" "scripts/dev/check-build-source-lists.py"; then
            add_command "scripts/dev/agent-preflight.sh"
        fi
    done <<< "$changed_paths"
fi

echo "Suggested checks:"
if [ "${#commands[@]}" -eq 0 ]; then
    echo "- scripts/dev/agent-preflight.sh"
else
    for command in "${commands[@]}"; do
        echo "- $command"
    done
fi
echo ""

echo "Docs to trust first:"
echo "- AGENT_START.md"
echo "- AGENTS.md"
echo "- docs/repo-layout.md"
echo "- docs/agent-onboarding.md"
echo "- nearest live CLAUDE.md for touched code"
echo ""

echo "Matrix: .agents/test-matrix.yml"
echo ""

echo "Coordinator closeout:"
echo "COORD_DONE: GREEN/BRIEF/RED | PR URL if any | changes made | GitHub cleanup recommendations | decisions needed | tests/checks run | smallest next action"
echo "See docs/agent-closeout.md for status meanings and cleanup boundaries."
