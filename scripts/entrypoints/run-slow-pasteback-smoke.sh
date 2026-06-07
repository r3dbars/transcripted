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

echo "Compiling slow pasteback smoke..."
swiftc \
    "${SWIFT_SOURCES[@]}" \
    -framework AppKit \
    -framework ApplicationServices \
    -parse-as-library \
    -o "$SMOKE_BIN"

echo "Running slow pasteback smoke..."
TRANSCRIPTED_DISABLE_FILE_LOGGER=1 \
"$SMOKE_BIN" "$@"
