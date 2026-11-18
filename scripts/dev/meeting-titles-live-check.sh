#!/usr/bin/env bash
# Opt-in live check for on-device meeting titles. Not part of CI: it needs the
# 3.1 GB model and a llama-server helper. Starts the helper on a spare port
# against a fictional meeting copied into a temp folder, then prints the model's
# JSON, the guarded label and the frontmatter the app would write. Never reads
# or writes the real capture library or app state.
#
#   bash scripts/dev/meeting-titles-live-check.sh <model.gguf> [llama-server]
#   bash scripts/dev/meeting-titles-live-check.sh --build-only
#
# The helper defaults to the one this worktree's build bundles. --build-only
# just compiles the lab binary (no model needed).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_ONLY=false
if [ "${1:-}" = "--build-only" ]; then
    BUILD_ONLY=true
fi
MODEL="${1:-}"
HELPER="${2:-$ROOT_DIR/build/Transcripted.app/Contents/Helpers/llama-server}"
if [ "$BUILD_ONLY" = false ] && { [ -z "$MODEL" ] || [ ! -f "$MODEL" ]; }; then
    echo "usage: bash scripts/dev/meeting-titles-live-check.sh <model.gguf> [llama-server]" >&2
    exit 2
fi
if [ "$BUILD_ONLY" = false ] && [ ! -x "$HELPER" ]; then
    echo "llama-server not found at $HELPER (run bash build.sh --no-open, or pass a path)" >&2
    exit 2
fi

BUILD_DIR="$ROOT_DIR/build/labs"
BINARY="$BUILD_DIR/meeting-titles-live-check"
mkdir -p "$BUILD_DIR"

source "$ROOT_DIR/scripts/entrypoints/lib/shared-smoke-sources.sh"
SOURCES=()
for source in "${SHARED_TEST_STORAGE_SOURCES[@]}"; do
    SOURCES+=("$ROOT_DIR/$source")
done
SOURCES+=(
    "$ROOT_DIR/Tests/Labs/MeetingTitlesLiveCheck.swift"
    "$ROOT_DIR/Sources/Meeting/MeetingTitlesPrompt.swift"
    "$ROOT_DIR/Sources/Meeting/MeetingTitlesGuards.swift"
    "$ROOT_DIR/Sources/Meeting/MeetingTitlesFrontmatterWriter.swift"
    "$ROOT_DIR/Sources/Meeting/MeetingTitlesLabeler.swift"
    "$ROOT_DIR/Sources/Meeting/MeetingTitlesQueue.swift"
    "$ROOT_DIR/Sources/Meeting/MeetingTitlesServer.swift"
    "$ROOT_DIR/Sources/Meeting/MeetingQuickSummaryWriter.swift"
    "$ROOT_DIR/Sources/Meeting/MeetingQuickSummaryExtractor.swift"
    "$ROOT_DIR/Sources/TranscriptedCore/Utilities/FilePermissions.swift"
    "$ROOT_DIR/Sources/TranscriptedCore/Models/TranscriptionLanguage.swift"
    "$ROOT_DIR/Sources/TranscriptedCore/Services/CoreStoragePaths.swift"
    "$ROOT_DIR/Sources/TranscriptedCore/Logging/AppLogger.swift"
    "$ROOT_DIR/Sources/TranscriptedCore/Logging/FileLogger.swift"
    "$ROOT_DIR/Sources/TranscriptedCore/Logging/LogTailTrimmer.swift"
    "$ROOT_DIR/Sources/TranscriptedCore/Logging/LogPrivacySanitizer.swift"
)

swiftc "${SOURCES[@]}" \
    -parse-as-library \
    -target arm64-apple-macos26.0 \
    -framework AppKit \
    -lsqlite3 \
    -o "$BINARY"

if [ "$BUILD_ONLY" = true ]; then
    echo "Built $BINARY"
    exit 0
fi

TRANSCRIPTED_DISABLE_FILE_LOGGER=1 \
TRANSCRIPTED_CONTAINER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/meeting-titles-live-check.XXXXXX")" \
    "$BINARY" --model "$MODEL" --helper "$HELPER" \
    --fixture "$ROOT_DIR/Tests/Fixtures/meeting-titles/live-check-meeting.md"
