#!/usr/bin/env bash
# verify-change.sh — run the checks Justin would otherwise do by hand after a change.
#
# check.sh proves the code compiles and the tests pass. This proves the app still
# does the thing: paste-back lands text, the built app imports a recording and
# saves a valid meeting, the main screens open, and launch didn't get slower. It
# picks the checks from what changed, runs them against isolated state (never the
# real capture library or prefs), and writes a short summary to
# .build/verify/summary.md. Changed source files no check covers are listed in the
# summary so they get a hand check instead of a silent pass.
#
# The `verify` skill (.claude/skills/verify/SKILL.md) tells agents when to run it
# and what to add on top (screenshots, live hardware hand-off).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

BASE="origin/main"
ONLY=""
LIST_ONLY=0
LAUNCH_SAMPLES=20
# Launch-to-interactive product target is 400 ms (PRD WS4.2). Local p99 sits near 280 ms.
LAUNCH_P95_BUDGET_MS=400
OUT_DIR="$REPO_ROOT/.build/verify"  # not build/: build.sh wipes that folder
APP="build/Transcripted.app"

usage() {
    cat <<'EOF'
Usage: bash scripts/dev/verify-change.sh [options]
  --base REF        Compare against this ref (default: origin/main)
  --only LIST       Run these checks no matter what changed: paste,meetings,ui,speed
  --all             Run every check
  --list            Print which checks would run and why, then stop
  --samples N       Launch samples for the speed check (default: 20)
  -h, --help        Show this help

Checks:
  paste      fake slow paste target; the text must land in the field
  meetings   drive the built app's audio import with a spoken fixture; the saved
             meeting Markdown must validate (needs local models and Accessibility)
  ui         launch the built app in an isolated home and walk onboarding,
             menu bar, Home and Settings through Accessibility
  speed      cold-launch N times; every launch must report and p95 must stay under 400 ms

ui and meetings skip (never quit anything) when a Transcripted copy is already running.

Exit: 0 when nothing failed (skips are listed), 1 when a check failed, 2 on bad usage.
EOF
}

need_value() {
    if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "$1 needs a value" >&2
        usage >&2
        exit 2
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --base) need_value "$@"; BASE="$2"; shift 2 ;;
        --only) need_value "$@"; ONLY="$2"; shift 2 ;;
        --all) ONLY="paste,meetings,ui,speed"; shift ;;
        --list) LIST_ONLY=1; shift ;;
        --samples) need_value "$@"; LAUNCH_SAMPLES="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if ! git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null; then
    echo "Base ref '$BASE' doesn't exist here. Run 'git fetch origin main' or pass --base." >&2
    exit 2
fi

export TRANSCRIPTED_DISABLE_FILE_LOGGER=1

# --- What changed ------------------------------------------------------------

CHANGED="$( {
    git diff --name-only "$BASE"...HEAD
    git diff --name-only HEAD
    git ls-files --others --exclude-standard
} 2>/dev/null | sort -u)"

matches() { printf '%s\n' "$CHANGED" | grep -Eq "$1"; }

# Path triggers. Each one names the code its check actually runs.
# The paste smoke compiles only these files (scripts/entrypoints/lib/shared-smoke-sources.sh).
PASTE_PATHS='^(Sources/Support/(Clipboard|FocusedTextPaste|TranscriptedConstants)|Sources/TranscriptedCore/Utilities/SupersessionEpoch|Tests/E2E/SlowPasteback|scripts/entrypoints/(run-slow-pasteback-smoke|lib/shared-smoke-sources))'
# The native import smoke runs the real app: picker, import, transcription, save.
MEETING_PATHS='^Sources/(Meeting|TranscriptedCore|Reliability)/'
UI_PATHS='^Sources/((UI|App|Writing|TranscriptedWriting|TranscriptedKeyboard|Accessibility)/|[^/]+\.swift$)'
SPEED_PATHS='^Sources/((App|UI|Support|Speech|Observability)/|[^/]+\.swift$)|^scripts/entrypoints/build\.sh$'
# Code that builds an audio engine or opens the mic needs a real-headset check
# no script can fake (AGENTS.md: AirPods).
LIVE_PATHS='^Sources/(Speech|Dictation|Capture|TranscriptedCore/Audio|Meeting)/'

want_paste=0; want_meetings=0; want_ui=0; want_speed=0; want_live=0
why_paste=""; why_meetings=""; why_ui=""; why_speed=""

if [ -n "$ONLY" ]; then
    for check in ${ONLY//,/ }; do
        case "$check" in
            paste) want_paste=1; why_paste="asked for" ;;
            meetings) want_meetings=1; why_meetings="asked for" ;;
            ui) want_ui=1; why_ui="asked for" ;;
            speed) want_speed=1; why_speed="asked for" ;;
            *) echo "Unknown check: $check" >&2; exit 2 ;;
        esac
    done
else
    matches "$PASTE_PATHS" && { want_paste=1; why_paste="paste-back code changed"; }
    matches "$MEETING_PATHS" && { want_meetings=1; why_meetings="meeting, Core or recovery code changed"; }
    matches "$UI_PATHS" && { want_ui=1; why_ui="UI, app shell or Writing changed"; }
    matches "$SPEED_PATHS" && { want_speed=1; why_speed="code on the launch path changed"; }
fi
matches "$LIVE_PATHS" && want_live=1

# Changed app or package sources no check that runs (or the live hand-off) exercises:
# these need a hand check. Built from the checks that will run, so --only is honest.
COVERED=""
[ "$want_paste" = 1 ] && COVERED="$COVERED|$PASTE_PATHS"
[ "$want_meetings" = 1 ] && COVERED="$COVERED|$MEETING_PATHS"
[ "$want_ui" = 1 ] && COVERED="$COVERED|$UI_PATHS"
[ "$want_speed" = 1 ] && COVERED="$COVERED|$SPEED_PATHS"
[ "$want_live" = 1 ] && COVERED="$COVERED|$LIVE_PATHS"
UNCOVERED="$(printf '%s\n' "$CHANGED" | grep -E '^(Sources|Tools/[^/]+/Sources)/.*\.swift$' || true)"
if [ -n "$COVERED" ] && [ -n "$UNCOVERED" ]; then
    UNCOVERED="$(printf '%s\n' "$UNCOVERED" | grep -Ev "${COVERED#|}" || true)"
fi

if [ "$LIST_ONLY" = "1" ]; then
    [ "$want_paste" = 1 ] && echo "paste: $why_paste"
    [ "$want_meetings" = 1 ] && echo "meetings: $why_meetings"
    [ "$want_ui" = 1 ] && echo "ui: $why_ui"
    [ "$want_speed" = 1 ] && echo "speed: $why_speed"
    [ "$want_live" = 1 ] && echo "live hardware: audio or dictation code changed; needs Justin with a real mic and AirPods"
    if [ -n "$UNCOVERED" ]; then
        echo "not covered by any check (verify by hand):"
        printf '%s\n' "$UNCOVERED" | sed 's/^/  /'
    fi
    if [ $((want_paste + want_meetings + want_ui + want_speed)) = 0 ] && [ -z "$UNCOVERED" ]; then
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

# Any Transcripted copy (Justin's, or another worktree's build) makes a second
# launched instance ambiguous for AX automation. We never quit it.
app_running() { pgrep -f "Transcripted.app/Contents/MacOS/Transcripted" >/dev/null 2>&1; }

# 0 built, 1 build failed, 2 build refused because this worktree's app is running.
BUILD_STATE=""
ensure_app_built() {
    if [ -z "$BUILD_STATE" ]; then
        BUILD_STATE=0
        if [ -z "$(ls -A deps-libs 2>/dev/null)" ] || [ -z "$(ls -A deps-modules 2>/dev/null)" ]; then
            echo "Building audio dependencies first (one-time per worktree)..."
            run_logged deps bash build-deps.sh || BUILD_STATE=1
        fi
        if [ "$BUILD_STATE" = 0 ]; then
            echo "Building the app..."
            if ! run_logged build bash build.sh --no-open; then
                if grep -q "Refusing to rebuild" "$OUT_DIR/build.log"; then BUILD_STATE=2; else BUILD_STATE=1; fi
            fi
        fi
    fi
    return "$BUILD_STATE"
}

# record_build_problem <check>: returns 0 (and records) when the app isn't usable.
record_build_problem() {
    ensure_app_built
    case $? in
        0) return 1 ;;
        2) record "$1" SKIP "this worktree's app is running, so it can't be rebuilt; quit it and rerun" ;;
        *) record "$1" FAIL "app build failed; see .build/verify/build.log or deps.log" ;;
    esac
    return 0
}

# run_app_smoke <check> <pass detail> <qa subcommand and args...>
run_app_smoke() {
    local check="$1" pass_detail="$2"; shift 2
    record_build_problem "$check" && return
    if app_running; then
        record "$check" SKIP "Transcripted is already running; quit it and rerun with --only $check"
        return
    fi
    run_logged "$check" swift run --package-path Tools/TranscriptedQA transcripted-qa "$@"
    case $? in
        0) record "$check" PASS "$pass_detail" ;;
        3) record "$check" SKIP "incomplete (often missing Accessibility or local models); see .build/verify/$check.log" ;;
        *) record "$check" FAIL "see .build/verify/$check.log and $check.json" ;;
    esac
}

if [ "$want_paste" = 1 ]; then
    echo "Running paste check ($why_paste)..."
    if run_logged paste bash run-slow-pasteback-smoke.sh; then
        record paste PASS "text pasted into the slow fake target"
    else
        record paste FAIL "paste-back smoke failed; see .build/verify/paste.log"
    fi
fi

if [ "$want_meetings" = 1 ]; then
    echo "Running meetings check ($why_meetings)..."
    run_app_smoke meetings "built app imported a spoken recording and saved a valid meeting" \
        imported-audio-native-smoke --app "$APP" --report "$OUT_DIR/meetings.json" --preserve-evidence
fi

if [ "$want_ui" = 1 ]; then
    echo "Running UI check ($why_ui)..."
    run_app_smoke ui "onboarding, menu bar, Home and Settings all opened" \
        ui-smoke --app "$APP" --report "$OUT_DIR/ui.json"
fi

if [ "$want_speed" = 1 ] && ! record_build_problem speed; then
    echo "Running speed check ($why_speed, $LAUNCH_SAMPLES launches)..."
    speed_json="$OUT_DIR/launch-latency.json"
    if run_logged speed bash scripts/dev/bench-launch-latency.sh \
        --samples "$LAUNCH_SAMPLES" --app "$APP" --label verify --out "$speed_json"; then
        read -r collected p50 p95 < <(python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))
s = r["launchToInteractiveMs"]
print(r["collectedSamples"], s["p50"], s["p95"])' "$speed_json")
        if [ "$collected" != "$LAUNCH_SAMPLES" ]; then
            record speed FAIL "only $collected of $LAUNCH_SAMPLES launches reported; see .build/verify/speed.log"
        elif python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= float(sys.argv[2]) else 1)' "$p95" "$LAUNCH_P95_BUDGET_MS"; then
            record speed PASS "launch p50 ${p50} ms, p95 ${p95} ms over $collected launches (budget ${LAUNCH_P95_BUDGET_MS})"
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
        echo "No app check applied to this change."
    else
        echo "| Check | Result | Detail |"
        echo "|---|---|---|"
        printf '%s\n' "${RESULTS[@]}"
    fi
    if [ -n "$UNCOVERED" ]; then
        echo
        echo "**Not covered by any check, verify by hand:**"
        printf '%s\n' "$UNCOVERED" | sed 's/^\(.*\)$/- `\1`/'
    fi
    if [ "$want_live" = 1 ]; then
        echo
        echo "**Needs a live check by Justin:** audio or dictation code changed. Run"
        echo "\`bash check.sh hardware\`, then dictate once with the built-in mic and once with"
        echo "AirPods as the default input."
    fi
} >"$OUT_DIR/summary.md"

echo
cat "$OUT_DIR/summary.md"
exit "$FAILED"
