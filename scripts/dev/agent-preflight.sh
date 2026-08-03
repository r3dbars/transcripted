#!/bin/bash
# Print the repo facts an agent should check before editing or handing off.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

base_ref="origin/main"
run_checks="false"
report_path="build/agent-proof.json"
base_was_set="false"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --run)
            run_checks="true"
            shift
            ;;
        --report)
            if [ "$#" -lt 2 ]; then
                echo "--report requires a repo-relative path."
                exit 2
            fi
            report_path="$2"
            shift 2
            ;;
        --base)
            if [ "$#" -lt 2 ]; then
                echo "--base requires a git ref."
                exit 2
            fi
            base_ref="$2"
            base_was_set="true"
            shift 2
            ;;
        -h|--help)
            echo "Usage: scripts/dev/agent-preflight.sh [--run] [--report PATH] [--base REF] [REF]"
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            exit 2
            ;;
        *)
            if [ "$base_was_set" = "true" ]; then
                echo "Only one base ref may be provided."
                exit 2
            fi
            base_ref="$1"
            base_was_set="true"
            shift
            ;;
    esac
done

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Not inside a git worktree."
    exit 1
fi

if ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    echo "Base ref does not exist."
    exit 1
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

# Catch wasted "repair PR" work: if this looks like a repair/redo branch, the
# fix may already be merged under another PR number. Nudge before any editing.
case "$branch" in
    *repair*|*redo*|*reland*|*reapply*|*re-apply*|*conflict*|*rebase-*|*supersed*)
        echo "Repair-branch guard:"
        echo "- This branch name looks like a repair/redo of an existing PR."
        echo "- Before editing, confirm the change did not ALREADY merge elsewhere:"
        echo "    python3 scripts/dev/check-superseded.py --branch \"$branch\""
        echo "    python3 scripts/dev/check-superseded.py --pr <dirty-pr-number>"
        echo "  A 'STOP: #NNNN already merged this' means do not open the repair branch."
        echo ""
        ;;
esac

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
if [ -n "$changed_paths" ]; then
    matrix_commands="$(
        printf '%s\n' "$changed_paths" | \
            python3 scripts/dev/test-matrix-checks.py --matrix .agents/test-matrix.yml
    )"
    if [ -n "$matrix_commands" ]; then
        while IFS= read -r command; do
            [ -n "$command" ] && commands+=("$command")
        done <<< "$matrix_commands"
    fi
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

if [ "$run_checks" = "true" ]; then
    echo ""
    echo "Running mapped checks sequentially..."
    python3 scripts/dev/agent-check.py --base "$base_ref" --report "$report_path"
fi
