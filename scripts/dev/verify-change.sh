#!/usr/bin/env bash
# verify-change.sh — run the checks Justin would otherwise do by hand after a change.
#
# check.sh proves the code compiles and the tests pass. This proves the app still
# does the thing: dictation pastes, an imported meeting saves a valid transcript,
# the main screens open, and launch didn't get slower. It picks the checks from
# what changed, runs them against isolated state (never the real capture library
# or prefs), and writes a short summary to .build/verify/summary.md.
#
# The `verify` skill (.claude/skills/verify/SKILL.md) tells agents when to run it
# and what to add on top (screenshots, live hardware hand-off).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

BASE="origin/main"
ONLY=""
LIST_ONLY=0
LAUNCH_SAMPLES=10
# Launch-to-interactive product target is 400 ms (PRD WS4.2). Local p99 sits near 280 ms.
LAUNCH_P95_BUDGET_MS=400
OUT_DIR="$REPO_ROOT/.build/verify"  # not build/: build.sh wipes that folder
APP="build/Transcripted.app"

usage() {
    cat <<'EOF'
Usage: bash scripts/dev/verify-change.sh [options]
  --base REF        Compare against this ref (default: origin/main)
  --only LIST       Run these checks no matter what changed: dictation,meetings,ui,speed
  --all             Run every check
  --list            Print which checks would run and why, then stop
  --samples N       Launch samples for the speed check (default: 10)
  -h, --help        Show this help

Checks:
  dictation  fake slow paste target; the dictated text must land in the field
  meetings   imported-audio smoke; the saved meeting Markdown must validate
  ui         launch the built app in an isolated home and walk onboarding,
             menu bar, Home and Settings through Accessibility
  speed      cold-launch N times; p95 must stay under 400 ms

Exit: 0 when nothing failed (skips are listed), 1 when a check failed, 2 on bad usage.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --base) BASE="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        --all) ONLY="dictation,meetings,ui,speed"; shift ;;
        --list) LIST_ONLY=1; shift ;;
        --samples) LAUNCH_SAMPLES="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

export TRANSCRIPTED_DISABLE_FILE_LOGGER=1

# --- What changed ------------------------------------------------------------

changed_files() {
    {
        git diff --name-only "$BASE"...HEAD 2>/dev/null
        git diff --name-only HEAD 2>/dev/null
        git ls-files --others --exclude-standard 2>/dev/null
    } | sort -u
}

CHANGED="$(changed_files)"

matches() { printf '%s\n' "$CHANGED" | grep -Eq "$1"; }

want_dictation=0; want_meetings=0; want_ui=0; want_speed=0; want_live=0
why_dictation=""; why_meetings=""; why_ui=""; why_speed=""

if [ -n "$ONLY" ]; then
    for check in ${ONLY//,/ }; do
        case "$check" in
            dictation) want_dictation=1; why_dictation="asked for" ;;
            meetings) want_meetings=1; why_meetings="asked for" ;;
            ui) want_ui=1; why_ui="asked for" ;;
            speed) want_speed=1; why_speed="asked for" ;;
            *) echo "Unknown check: $check" >&2; exit 2 ;;
        esac
    done
else
    if matches '^(Sources/(Speech|Dictation|Capture|Accessibility)/|Tests/E2E/SlowPasteback)'; then
        want_dictation=1; why_dictation="dictation, capture or paste code changed"
    fi
    if matches '^(Sources/(Meeting|TranscriptedCore)/|Tools/TranscriptedQA/)'; then
        want_meetings=1; why_meetings="meeting pipeline or Core changed"
    fi
    if matches '^Sources/(UI|App|Writing)/'; then
        want_ui=1; why_ui="UI or app shell changed"
    fi
    if matches '^Sources/(App|UI|Support|Speech|Observability)/|^(build\.sh|scripts/entrypoints/build\.sh)$'; then
        want_speed=1; why_speed="code on the launch path changed"
    fi
fi

# Code that builds an audio engine or touches the mic needs a real-headset check
# no script can fake (AGENTS.md: AirPods).
if matches '^Sources/(Speech|TranscriptedCore/Audio|Meeting)/'; then
    want_live=1
fi

if [ "$LIST_ONLY" = "1" ]; then
    [ "$want_dictation" = 1 ] && echo "dictation: $why_dictation"
    [ "$want_meetings" = 1 ] && echo "meetings: $why_meetings"
    [ "$want_ui" = 1 ] && echo "ui: $why_ui"
    [ "$want_speed" = 1 ] && echo "speed: $why_speed"
    [ "$want_live" = 1 ] && echo "live hardware: audio code changed; needs Justin with a real mic and AirPods"
    if [ $((want_dictation + want_meetings + want_ui + want_speed)) = 0 ]; then
        echo "nothing to verify in the app for this change (bash check.sh still applies)"
    fi
    exit 0
fi

# --- Running checks ----------------------------------------------------------

mkdir -p "$OUT_DIR"
RESULTS=()
FAILED=0

record() {
    # record <check> <PASS|FAIL|SKIP> <detail>
    RESULTS+=("| $1 | $2 | $3 |")
    [ "$2" = "FAIL" ] && FAILED=1
    echo "[$2] $1 — $3"
}

run_logged() {
    # run_logged <check> <command...>; output goes to .build/verify/<check>.log
    local check="$1"; shift
    "$@" >"$OUT_DIR/$check.log" 2>&1
}

app_running() { pgrep -f "Transcripted.app/Contents/MacOS/Transcripted" >/dev/null 2>&1; }

built_app=0
ensure_app_built() {
    [ "$built_app" = 1 ] && return 0
    if [ ! -d deps-libs ] || [ -z "$(ls -A deps-libs 2>/dev/null)" ]; then
        echo "Building audio dependencies first (one-time per worktree)..."
        run_logged deps bash build-deps.sh || return 1
    fi
    echo "Building the app..."
    run_logged build bash build.sh --no-open || return 1
    built_app=1
}

if [ "$want_dictation" = 1 ]; then
    echo "Running dictation check ($why_dictation)..."
    if run_logged dictation bash run-slow-pasteback-smoke.sh; then
        record dictation PASS "text pasted into the slow fake target"
    else
        record dictation FAIL "paste-back smoke failed; see .build/verify/dictation.log"
    fi
fi

if [ "$want_meetings" = 1 ]; then
    echo "Running meetings check ($why_meetings)..."
    if run_logged meetings swift run --package-path Tools/TranscriptedQA transcripted-qa \
        imported-audio-smoke --output "$OUT_DIR/meetings-evidence" --preserve; then
        record meetings PASS "imported meeting saved; Markdown and audio validated"
    else
        record meetings FAIL "imported-audio smoke failed; see .build/verify/meetings.log"
    fi
fi

if [ "$want_ui" = 1 ] || [ "$want_speed" = 1 ]; then
    if ! ensure_app_built; then
        [ "$want_ui" = 1 ] && record ui FAIL "app build failed; see .build/verify/build.log"
        [ "$want_speed" = 1 ] && record speed FAIL "app build failed; see .build/verify/build.log"
        want_ui=0; want_speed=0
    fi
fi

if [ "$want_ui" = 1 ]; then
    echo "Running UI check ($why_ui)..."
    if app_running; then
        # Two Transcripted status items make the AX walk ambiguous, and we never
        # quit the copy Justin is using.
        record ui SKIP "Transcripted is already running; quit it and rerun with --only ui"
    else
        run_logged ui swift run --package-path Tools/TranscriptedQA transcripted-qa \
            ui-smoke --app "$APP" --report "$OUT_DIR/ui-smoke.json"
        case $? in
            0) record ui PASS "onboarding, menu bar, Home and Settings all opened" ;;
            3) record ui SKIP "incomplete, usually missing Accessibility permission; see .build/verify/ui.log" ;;
            *) record ui FAIL "UI smoke failed; see .build/verify/ui.log and ui-smoke.json" ;;
        esac
    fi
fi

if [ "$want_speed" = 1 ]; then
    echo "Running speed check ($why_speed, $LAUNCH_SAMPLES launches)..."
    speed_json="$OUT_DIR/launch-latency.json"
    if run_logged speed bash scripts/dev/bench-launch-latency.sh \
        --samples "$LAUNCH_SAMPLES" --app "$APP" --label verify --out "$speed_json"; then
        p95="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["launchToInteractiveMs"]["p95"])' "$speed_json")"
        p50="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["launchToInteractiveMs"]["p50"])' "$speed_json")"
        if python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= float(sys.argv[2]) else 1)' "$p95" "$LAUNCH_P95_BUDGET_MS"; then
            record speed PASS "launch p50 ${p50} ms, p95 ${p95} ms (budget ${LAUNCH_P95_BUDGET_MS})"
        else
            record speed FAIL "launch p95 ${p95} ms is over the ${LAUNCH_P95_BUDGET_MS} ms budget (p50 ${p50}); rerun once to rule out a busy machine"
        fi
    else
        record speed FAIL "launch benchmark failed; see .build/verify/speed.log"
    fi
fi

# --- Summary -----------------------------------------------------------------

{
    echo "## App verification"
    echo
    echo "Base: \`$BASE\` · head: \`$(git rev-parse --short HEAD)\`"
    echo
    if [ ${#RESULTS[@]} -eq 0 ]; then
        echo "Nothing in this change needed an app check."
    else
        echo "| Check | Result | Detail |"
        echo "|---|---|---|"
        printf '%s\n' "${RESULTS[@]}"
    fi
    if [ "$want_live" = 1 ]; then
        echo
        echo "**Needs a live check by Justin:** audio code changed. Run \`bash check.sh hardware\`,"
        echo "then dictate once with the built-in mic and once with AirPods as the default input."
    fi
} >"$OUT_DIR/summary.md"

echo
cat "$OUT_DIR/summary.md"
exit "$FAILED"
