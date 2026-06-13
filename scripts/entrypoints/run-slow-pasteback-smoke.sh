#!/bin/bash
# run-slow-pasteback-smoke.sh - deterministic fake slow paste target smoke.

set -euo pipefail

ENTRYPOINT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ENTRYPOINT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_DIR="$REPO_ROOT/build/slow-pasteback-smoke"
SMOKE_BIN="$BUILD_DIR/slow-pasteback-smoke"
mkdir -p "$BUILD_DIR"

SWIFT_SOURCES=(
    "Tests/E2E/SlowPastebackSmoke.swift"
    "Sources/Support/ClipboardRestoringTextPaster.swift"
    "Sources/Support/TranscriptedConstants.swift"
)

for source in "${SWIFT_SOURCES[@]}"; do
    if [ ! -f "$source" ]; then
        echo "E2E smoke source missing: $source" >&2
        exit 1
    fi
done

echo "Compiling slow pasteback smoke..."
COMPILE_STDERR="$BUILD_DIR/compile-stderr.log"
if ! swiftc \
    "${SWIFT_SOURCES[@]}" \
    -framework AppKit \
    -framework ApplicationServices \
    -parse-as-library \
    -o "$SMOKE_BIN" 2> >(tee "$COMPILE_STDERR" >&2); then
    missing_symbols="$(
        grep -oE "cannot find (type )?'[^']+' in scope" "$COMPILE_STDERR" 2>/dev/null \
            | grep -oE "'[^']+'" | tr -d "'" | sort -u || true
    )"
    if [ -n "$missing_symbols" ]; then
        echo "" >&2
        echo "Slow pasteback smoke compile failed with unresolved symbols. It likely needs a new source file added to SWIFT_SOURCES." >&2
        while IFS= read -r symbol; do
            [ -z "$symbol" ] && continue
            echo "  - missing symbol: $symbol" >&2
            echo "    locate it with: grep -rln \"struct/enum/class/func $symbol\" Sources Tools" >&2
        done <<< "$missing_symbols"
        echo "  Add the file that defines the symbol to the SWIFT_SOURCES array in $0." >&2
    fi
    exit 1
fi

echo "Running slow pasteback smoke..."
TRANSCRIPTED_DISABLE_FILE_LOGGER=1 \
"$SMOKE_BIN" "$@"
