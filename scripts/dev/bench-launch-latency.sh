#!/usr/bin/env bash
# bench-launch-latency.sh — repeated cold-launch sampling for the launch-to-interactive budget.
#
# build.sh's launch smoke takes exactly one sample, which cannot distinguish a
# real regression from scheduler noise. This runs N isolated launches and reports
# p50/p90/p95/p99 so tail behavior is visible.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

APP_BUNDLE="$REPO_ROOT/build/Transcripted.app"
SAMPLES=20
WARMUPS=2
LABEL="launch"
OUT_PATH=""
REUSE_HOME=0

usage() {
    cat <<'USAGE'
Usage: bash scripts/dev/bench-launch-latency.sh [options]

Options:
  --samples N     Scored launches (default: 20)
  --warmups N     Unscored warmup launches (default: 2)
  --app PATH      App bundle to measure (default: build/Transcripted.app)
  --label NAME    Label recorded in the JSON output (default: launch)
  --reuse-home    Reuse one HOME across samples (warm caches; default is a fresh HOME per sample)
  --out PATH      Write JSON results here (default: build/benchmarks/launch-latency-<label>.json)
  -h, --help      Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --samples) SAMPLES="$2"; shift 2 ;;
        --warmups) WARMUPS="$2"; shift 2 ;;
        --app) APP_BUNDLE="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        --reuse-home) REUSE_HOME=1; shift ;;
        --out) OUT_PATH="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ ! -d "$APP_BUNDLE" ]; then
    echo "App bundle not found: $APP_BUNDLE" >&2
    echo "Run: bash build.sh --no-open" >&2
    exit 1
fi

BENCH_DIR="$REPO_ROOT/build/benchmarks"
mkdir -p "$BENCH_DIR"
[ -n "$OUT_PATH" ] || OUT_PATH="$BENCH_DIR/launch-latency-$LABEL.json"

WORK_DIR="$(mktemp -d "/tmp/transcripted-launch-bench.XXXXXX")"
# The measured bundle is a copy so pgrep can match this run's binary path and
# never match a developer's real Transcripted.app running in the background.
BENCH_APP="$WORK_DIR/Transcripted.app"
BENCH_BINARY="$BENCH_APP/Contents/MacOS/Transcripted"
cp -R "$APP_BUNDLE" "$BENCH_APP"

SHARED_HOME="$WORK_DIR/shared-home"
mkdir -p "$SHARED_HOME"

cleanup() {
    pkill -f "$BENCH_BINARY" 2>/dev/null || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

SAMPLES_FILE="$WORK_DIR/samples.txt"
: > "$SAMPLES_FILE"

# One launch. Echoes launchToInteractiveMs on success, nothing on failure.
run_one() {
    local index="$1"
    local run_dir="$WORK_DIR/run-$index"
    local report="$run_dir/launch-ui-smoke.json"
    local log="$run_dir/launch.log"
    local run_home
    mkdir -p "$run_dir"

    if [ "$REUSE_HOME" = "1" ]; then
        run_home="$SHARED_HOME"
    else
        run_home="$run_dir/home"
        mkdir -p "$run_home"
    fi

    /usr/bin/open -n -g -F -W \
        --stdout "$log" \
        --stderr "$log" \
        --env "CFFIXED_USER_HOME=$run_home" \
        --env "HOME=$run_home" \
        --env "TRANSCRIPTED_DISABLE_FILE_LOGGER=1" \
        --env "TRANSCRIPTED_DISABLE_RUNTIME_DIAGNOSTICS=1" \
        --env "TRANSCRIPTED_DISABLE_SINGLE_INSTANCE_GUARD=1" \
        --env "TRANSCRIPTED_LAUNCH_UI_SMOKE_REPORT=$report" \
        --env "TRANSCRIPTED_LAUNCH_UI_SMOKE_TERMINATE_AFTER_REPORT=1" \
        "$BENCH_APP" >>"$log" 2>&1 &
    local open_pid=$!

    local waited=0
    while [ "$waited" -lt 100 ]; do
        [ -s "$report" ] && break
        kill -0 "$open_pid" 2>/dev/null || break
        sleep 0.1
        waited=$((waited + 1))
    done

    kill -TERM "$open_pid" 2>/dev/null || true
    wait "$open_pid" 2>/dev/null || true
    pkill -f "$BENCH_BINARY" 2>/dev/null || true
    # Let the terminated process fully exit so the next sample starts from a
    # clean slate instead of contending with a still-dying instance.
    sleep 0.3

    [ -s "$report" ] || return 0
    /usr/bin/python3 -c 'import json,sys
try:
    v = json.load(open(sys.argv[1])).get("launchToInteractiveMs")
    if v is not None:
        print(v)
except Exception:
    pass' "$report"
}

echo "Launch latency benchmark"
echo "  app:       $BENCH_APP"
echo "  samples:   $SAMPLES (plus $WARMUPS warmup)"
echo "  home mode: $([ "$REUSE_HOME" = "1" ] && echo "shared (warm)" || echo "fresh per sample (cold)")"
echo

for i in $(seq 1 "$WARMUPS"); do
    printf '  warmup %d/%d\r' "$i" "$WARMUPS"
    run_one "warmup-$i" >/dev/null
done

for i in $(seq 1 "$SAMPLES"); do
    printf '  sample %d/%d\r' "$i" "$SAMPLES"
    value="$(run_one "$i")"
    [ -n "$value" ] && echo "$value" >> "$SAMPLES_FILE"
done
printf '\033[2K\r'

/usr/bin/python3 - "$SAMPLES_FILE" "$OUT_PATH" "$LABEL" "$SAMPLES" "$REUSE_HOME" <<'PY'
import json, math, statistics, sys

samples_path, out_path, label, requested, reuse_home = sys.argv[1:6]
values = []
with open(samples_path) as handle:
    for line in handle:
        line = line.strip()
        if line:
            values.append(float(line))

if not values:
    print("No launch samples collected — the app never wrote a smoke report.", file=sys.stderr)
    sys.exit(1)

def pct(sorted_values, q):
    # Nearest-rank percentile: with ~20 samples, interpolating invents a value
    # between two observations, while nearest-rank always reports a launch that
    # actually happened. p99 of 20 samples is the max — reported honestly below.
    rank = max(1, min(len(sorted_values), math.ceil(q * len(sorted_values))))
    return sorted_values[rank - 1]

ordered = sorted(values)
result = {
    "label": label,
    "requestedSamples": int(requested),
    "collectedSamples": len(values),
    "homeMode": "shared" if reuse_home == "1" else "fresh",
    "launchToInteractiveMs": {
        "min": round(ordered[0], 1),
        "p50": round(pct(ordered, 0.50), 1),
        "p90": round(pct(ordered, 0.90), 1),
        "p95": round(pct(ordered, 0.95), 1),
        "p99": round(pct(ordered, 0.99), 1),
        "max": round(ordered[-1], 1),
        "mean": round(statistics.fmean(ordered), 1),
        "stdev": round(statistics.stdev(ordered), 1) if len(ordered) > 1 else 0.0,
    },
    "samples": [round(v, 1) for v in values],
}

with open(out_path, "w") as handle:
    json.dump(result, handle, indent=2, sort_keys=True)

s = result["launchToInteractiveMs"]
print(f"launch-to-interactive ({len(values)} samples, {result['homeMode']} home)")
print(f"  min   {s['min']:>8.1f} ms")
print(f"  p50   {s['p50']:>8.1f} ms")
print(f"  p90   {s['p90']:>8.1f} ms")
print(f"  p95   {s['p95']:>8.1f} ms")
print(f"  p99   {s['p99']:>8.1f} ms")
print(f"  max   {s['max']:>8.1f} ms")
print(f"  mean  {s['mean']:>8.1f} ms  (stdev {s['stdev']:.1f})")
if len(values) < 100:
    print(f"  note: p99 of {len(values)} samples is rank-{len(values)} — it is the observed max, not a true p99.")
print(f"\nwrote {out_path}")
PY
