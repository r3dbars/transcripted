#!/usr/bin/env bash
# bench-all.sh — run every repeatable Transcripted latency benchmark and report p50/p95/p99.
#
# performance-budget.rb answers "did this build regress past a gate". This
# answers "where is the time actually going, including the tail". Nothing here
# fails the build; it prints numbers and writes JSON for comparison across runs.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

OUT_DIR="$REPO_ROOT/build/benchmarks"
LABEL="$(date +%Y%m%d-%H%M%S)"
LAUNCH_SAMPLES=20
EVENTS_PATH="$HOME/Library/Application Support/Transcripted/logs/events.jsonl"
EVENTS_SINCE=""
SKIP_LAUNCH=0
SKIP_HOME=0
SKIP_EVENTS=0
SKIP_COLD=0
DICTATION_STOP_ITERATIONS=0

usage() {
    cat <<'USAGE'
Usage: bash scripts/dev/bench-all.sh [options]

Runs the repeatable latency benchmarks and prints p50/p95/p99 for each.

Options:
  --label NAME        Run label used in output filenames (default: timestamp)
  --launch-samples N  Launch samples (default: 20)
  --events PATH       events.jsonl to mine for real-usage percentiles
  --events-since ISO  Only score events at or after this timestamp
  --skip-launch       Skip the launch benchmark (needs build/Transcripted.app)
  --skip-home         Skip the Home recent-captures benchmark (slow: compiles)
  --skip-events       Skip real-usage percentiles
  --skip-cold         Skip the cold (fresh HOME) launch pass
  --dictation-stop N  Also run the dictation stop-to-text bench, N iterations per
                      clip (uses macOS `say` to make clips; plays no sound)
  -h, --help          Show this help.

Benchmarks:
  launch    warm and cold launch-to-interactive, N isolated launches each
  home      Home recent-captures loader at 1k and 10k captures
  events    real-usage percentiles for every latency key in events.jsonl
  dictation stop-to-text on four spoken clips (opt-in, --dictation-stop N)

Every run ends with summary.json (one row per metric, in ms). Compare two runs:
  python3 scripts/dev/bench-compare.py build/benchmarks/<before> build/benchmarks/<after>
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --label) LABEL="$2"; shift 2 ;;
        --launch-samples) LAUNCH_SAMPLES="$2"; shift 2 ;;
        --events) EVENTS_PATH="$2"; shift 2 ;;
        --events-since) EVENTS_SINCE="$2"; shift 2 ;;
        --skip-launch) SKIP_LAUNCH=1; shift ;;
        --skip-home) SKIP_HOME=1; shift ;;
        --skip-events) SKIP_EVENTS=1; shift ;;
        --skip-cold) SKIP_COLD=1; shift ;;
        --dictation-stop) DICTATION_STOP_ITERATIONS="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

mkdir -p "$OUT_DIR"
RUN_DIR="$OUT_DIR/$LABEL"
mkdir -p "$RUN_DIR"

# Each section records its own status so one unavailable benchmark (no app
# bundle, no event log) reports as skipped instead of aborting the whole run.
declare -a SECTION_STATUS=()

hr() { printf '\n%s\n' "────────────────────────────────────────────────────────────"; }

echo "Transcripted benchmark sweep — $LABEL"
echo "output: $RUN_DIR"

if [ "$SKIP_LAUNCH" = "0" ]; then
    hr; echo "1/4  LAUNCH TO INTERACTIVE"; echo
    if [ ! -d "$REPO_ROOT/build/Transcripted.app" ]; then
        echo "  skipped — build/Transcripted.app missing (run: bash build.sh --no-open)"
        SECTION_STATUS+=("launch=skipped")
    elif bash "$SCRIPT_DIR/bench-launch-latency.sh" \
            --samples "$LAUNCH_SAMPLES" --warmups 2 \
            --label "$LABEL-warm" --reuse-home \
            --out "$RUN_DIR/launch-warm.json"; then
        SECTION_STATUS+=("launch=ok")
    else
        echo "  launch benchmark failed"
        SECTION_STATUS+=("launch=failed")
    fi
    if [ "$SKIP_COLD" = "0" ] && [ -d "$REPO_ROOT/build/Transcripted.app" ]; then
        echo; echo "  cold pass (fresh HOME per launch, like a first launch)"; echo
        if bash "$SCRIPT_DIR/bench-launch-latency.sh" \
                --samples "$LAUNCH_SAMPLES" --warmups 2 \
                --label "$LABEL-cold" \
                --out "$RUN_DIR/launch-cold.json"; then
            SECTION_STATUS+=("launch-cold=ok")
        else
            echo "  cold launch benchmark failed"
            SECTION_STATUS+=("launch-cold=failed")
        fi
    fi
else
    SECTION_STATUS+=("launch=skipped")
fi

if [ "$SKIP_HOME" = "0" ]; then
    hr; echo "2/4  HOME RECENT-CAPTURES LOADER"; echo
    if REPETITIONS=5 bash "$SCRIPT_DIR/benchmark-home-recent-captures.sh" \
            > "$RUN_DIR/home-recent-captures.txt" 2>&1; then
        cat "$RUN_DIR/home-recent-captures.txt"
        SECTION_STATUS+=("home=ok")
    else
        echo "  home benchmark failed — see $RUN_DIR/home-recent-captures.txt"
        tail -5 "$RUN_DIR/home-recent-captures.txt"
        SECTION_STATUS+=("home=failed")
    fi
else
    SECTION_STATUS+=("home=skipped")
fi

if [ "$SKIP_EVENTS" = "0" ]; then
    hr; echo "3/4  REAL-USAGE PERCENTILES"; echo
    if [ ! -s "$EVENTS_PATH" ]; then
        echo "  skipped — no event log at $EVENTS_PATH"
        echo "  (use the app for a while, or pass --events PATH)"
        SECTION_STATUS+=("events=skipped")
    else
        since_args=()
        [ -n "$EVENTS_SINCE" ] && since_args=(--since "$EVENTS_SINCE")
        # bash 3.2 (macOS) treats an empty array expansion as unbound under
        # `set -u`, so guard the expansion rather than dropping the option.
        if python3 "$SCRIPT_DIR/latency-percentiles.py" "$EVENTS_PATH" \
                ${since_args[@]+"${since_args[@]}"} \
                --event dictation_stop_latency_measured \
                --event dictation_recording_fast_start \
                --event dictation_started_after_wait \
                --event audio_samples_detected \
                --event dictation_audio_start_timing \
                --event transcription_complete \
                --json "$RUN_DIR/real-usage-percentiles.json"; then
            SECTION_STATUS+=("events=ok")
        else
            SECTION_STATUS+=("events=failed")
        fi
    fi
else
    SECTION_STATUS+=("events=skipped")
fi

if [ "$DICTATION_STOP_ITERATIONS" != "0" ]; then
    hr; echo "4/4  DICTATION STOP TO TEXT"; echo
    if [ ! -d "$REPO_ROOT/build/Transcripted.app" ]; then
        echo "  skipped — build/Transcripted.app missing (run: bash build.sh --no-open)"
        SECTION_STATUS+=("dictation-stop=skipped")
    elif TRANSCRIPTED_DICTATION_STOP_BENCH_WORK_DIR="$RUN_DIR/dictation-stop-work" \
            bash "$REPO_ROOT/scripts/ops/dictation-stop-autoeval.sh" \
            --skip-build --label "$LABEL" --iterations "$DICTATION_STOP_ITERATIONS" \
            > "$RUN_DIR/dictation-stop.txt" 2>&1; then
        cat "$RUN_DIR/dictation-stop.txt"
        cp "$RUN_DIR"/dictation-stop-work/results/*.jsonl "$RUN_DIR/dictation-stop.jsonl"
        # The work dir holds saved dictation text; keep only the numbers.
        rm -rf "$RUN_DIR/dictation-stop-work"
        SECTION_STATUS+=("dictation-stop=ok")
    else
        echo "  dictation stop bench failed — see $RUN_DIR/dictation-stop.txt"
        tail -5 "$RUN_DIR/dictation-stop.txt"
        rm -rf "$RUN_DIR/dictation-stop-work"
        SECTION_STATUS+=("dictation-stop=failed")
    fi
fi

python3 "$SCRIPT_DIR/bench-compare.py" --summarize "$RUN_DIR" || true

hr
echo "summary: ${SECTION_STATUS[*]}"
echo "artifacts in $RUN_DIR"
echo
echo "Compare with an earlier run:"
echo "  python3 scripts/dev/bench-compare.py $OUT_DIR/<before> $RUN_DIR"
