#!/bin/bash
# concurrency-census.sh — count Swift 6 concurrency warnings in the app, per folder.
#
# Swift 6's strict concurrency checking turns data races and wrong-thread calls
# into compile errors. The app still builds in Swift 5 mode, so this does a
# typecheck pass with -strict-concurrency=complete (no app binary; nothing
# shipped changes) and counts the concurrency warnings under each Sources/
# folder. The TranscriptedWritingCore module has to be compiled first so the
# app sources can import it; that compile also runs with
# -strict-concurrency=complete (and -Onone, to keep it quick), and its
# warnings land in the same log, so Sources/TranscriptedWriting/Core stays
# counted. The counts are the migration backlog: turn one folder to
# zero, then flip that folder to Swift 6 mode.
#
#   bash scripts/dev/concurrency-census.sh            # print counts, compare to the baseline
#   bash scripts/dev/concurrency-census.sh --check    # also fail if any folder went UP
#   bash scripts/dev/concurrency-census.sh --shrink   # lower the baseline after fixing some
#
# Needs the prebuilt deps (bash build-deps.sh). Baseline:
# .agents/concurrency-baseline.json. Raw log: build/concurrency-census.log.

set -euo pipefail

ENTRYPOINT_DIR="$(cd "$(dirname "$0")/../entrypoints" && pwd)"
REPO_ROOT="$(cd "$ENTRYPOINT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

mode="${1:-report}"
case "$mode" in
    report|--check|--shrink) ;;
    -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
    *) echo "Unknown argument: $mode" >&2; exit 2 ;;
esac

if [ ! -f deps-libs/libDraftDeps.a ] || [ ! -d deps-modules ]; then
    echo "Prebuilt deps missing. Run: bash build-deps.sh"
    exit 1
fi

source "$ENTRYPOINT_DIR/lib/swiftc-app-args.sh"

mkdir -p build
log="build/concurrency-census.log"
core_log="build/concurrency-census-core.log"

# WritingCore is its own module now, so it is not in APP_SOURCE_FILES. Build it
# under strict concurrency and keep its warnings for the count.
echo "Compiling TranscriptedWritingCore with -strict-concurrency=complete..."
# shellcheck disable=SC2034  # read by build_writing_core_module
WRITING_CORE_SWIFTC_FLAGS=(-Onone -strict-concurrency=complete)
if ! build_app_swiftc_args > "$core_log" 2>&1; then
    echo "TranscriptedWritingCore failed to compile; see $core_log"
    grep -m 20 'error:' "$core_log" || true
    exit 1
fi

echo "Typechecking ${#APP_SOURCE_FILES[@]} app sources with -strict-concurrency=complete (no app binary is built)..."
set +e
swiftc -typecheck \
    -strict-concurrency=complete \
    "${APP_SWIFTC_LINK_ARGS[@]}" \
    "${APP_SOURCE_FILES[@]}" \
    "${APP_SWIFTC_TAIL_ARGS[@]}" \
    > "$log" 2>&1
status=$?
set -e
cat "$core_log" >> "$log"
if [ "$status" -ne 0 ]; then
    echo "Typecheck failed (exit $status); see $log"
    grep -m 20 'error:' "$log" || true
    exit "$status"
fi

python3 "$REPO_ROOT/scripts/dev/concurrency-census.py" --log "$log" --mode "${mode#--}"
