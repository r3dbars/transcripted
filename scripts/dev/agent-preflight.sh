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
        if matches_any "$path" "Sources/*.swift" "Sources/*/*.swift" "Tests/*.swift"; then
            add_command "bash build.sh"
            add_command "bash run-tests.sh"
        fi

        if matches_any "$path" "Info.plist"; then
            add_command "bash build.sh"
            add_command "bash run-tests.sh"
        fi

        if matches_any "$path" "Sources/Meeting/*" "Sources/TranscriptedCore/*" "Tests/Integration/*"; then
            add_command "bash build.sh"
            add_command "bash run-tests.sh"
            add_command "bash run-integration-smoke.sh"
        fi

        if matches_any "$path" "Package.swift" "Sources/TranscriptedCore/*" "Tests/TranscriptedCoreTests/*"; then
            add_command "bash build.sh"
            add_command "bash run-tests.sh"
            add_command "bash run-integration-smoke.sh"
            add_command "swift test"
        fi

        if matches_any "$path" "Tools/TranscriptedCLI/*"; then
            add_command "swift test --package-path Tools/TranscriptedCLI"
        fi

        if matches_any "$path" "Tools/TranscriptedMCP/*"; then
            add_command "swift test --package-path Tools/TranscriptedMCP"
        fi

        if matches_any "$path" "Tools/TranscriptedQA/*"; then
            add_command "swift test --package-path Tools/TranscriptedQA"
        fi

        if matches_any "$path" "build-beta.sh" "scripts/entrypoints/build-beta.sh" "scripts/release/*" "docs/release-packaging.md" "docs/sparkle-updates.md" "Casks/*" "docs/appcast.xml"; then
            add_command "bash build.sh"
            add_command "bash run-tests.sh"
            add_command "SKIP_NOTARIZATION=1 bash build-beta.sh <token> <user-name>"
        fi

        if matches_any "$path" "README.md" "AGENT_START.md" "AGENTS.md" "CLAUDE.md" "CONTRIBUTING.md" "docs/*" ".agents/*" "scripts/dev/agent-preflight.sh"; then
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
