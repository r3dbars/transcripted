#!/bin/bash
# run-e2e-smoke.sh - deterministic end-to-end capture artifact smoke.

set -euo pipefail

ENTRYPOINT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ENTRYPOINT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_DIR="$REPO_ROOT/build/e2e-smoke"
SMOKE_BIN="$BUILD_DIR/transcripted-e2e-smoke"
mkdir -p "$BUILD_DIR"

if [ -n "${TRANSCRIPTED_E2E_ROOT:-}" ]; then
    RUN_ROOT_PARENT="$TRANSCRIPTED_E2E_ROOT"
else
    RUN_ROOT_PARENT="$BUILD_DIR"
fi
mkdir -p "$RUN_ROOT_PARENT"
RUN_ROOT="$(mktemp -d "$RUN_ROOT_PARENT/run.XXXXXX")"

cleanup() {
    if [ "${TRANSCRIPTED_E2E_KEEP:-0}" != "1" ]; then
        rm -rf "$RUN_ROOT"
    fi
}
trap cleanup EXIT

FAKE_HOME="$RUN_ROOT/home"
WORK_ROOT="$RUN_ROOT/work"
mkdir -p "$FAKE_HOME" "$WORK_ROOT"

SWIFT_SOURCES=(
    "Tests/E2E/TranscriptedE2ESmoke.swift"
    "Sources/Support/TranscriptedStoragePaths.swift"
    "Sources/Dictation/DictationStoragePaths.swift"
    "Sources/Dictation/DictationTranscriptWriter.swift"
    "Sources/Dictation/DictationTranscriptStore.swift"
    "Sources/Meeting/MeetingStoragePaths.swift"
    "Sources/Meeting/MeetingTranscriptStyler.swift"
    "Sources/TranscriptedCore/Storage/TranscriptFrontmatter.swift"
    "Sources/TranscriptedCore/Models/TranscriptionTypes.swift"
    "Sources/TranscriptedCore/Models/FailedTranscription.swift"
    "Sources/TranscriptedCore/Speaker/SpeakerProfile.swift"
    "Sources/TranscriptedCore/Services/CoreStoragePaths.swift"
    "Sources/TranscriptedCore/Services/FailedTranscriptionManager.swift"
    "Sources/TranscriptedCore/Logging/AppLogger.swift"
    "Sources/TranscriptedCore/Logging/FileLogger.swift"
    "Sources/TranscriptedCore/Utilities/FilePermissions.swift"
    "Sources/UI/Shared/MeetingAudioArchiveResolver.swift"
    "Sources/UI/Shared/RecentCaptureScanners.swift"
    "Sources/UI/Settings/HomeMeetingPreviewFormatter.swift"
    "Sources/Observability/ObservabilityTextRedactor.swift"
    "Sources/Observability/AnalyticsPayloadSanitizer.swift"
    "Sources/UI/Shared/SupportDiagnosticsBundle.swift"
    "Tools/TranscriptedMCP/Sources/TranscriptedMCP/DataDirectories.swift"
    "Tools/TranscriptedMCP/Sources/TranscriptedMCP/Models.swift"
    "Tools/TranscriptedMCP/Sources/TranscriptedMCP/NameVariants.swift"
    "Tools/TranscriptedMCP/Sources/TranscriptedMCP/PathSecurity.swift"
    "Tools/TranscriptedMCP/Sources/TranscriptedMCP/TranscriptLoader.swift"
    "Tools/TranscriptedMCP/Sources/TranscriptedMCP/TranscriptIndex.swift"
)

echo "Compiling deterministic E2E smoke..."
swiftc \
    "${SWIFT_SOURCES[@]}" \
    -framework AppKit \
    -lsqlite3 \
    -parse-as-library \
    -o "$SMOKE_BIN"

echo "Running deterministic E2E smoke..."
CFFIXED_USER_HOME="$FAKE_HOME" \
HOME="$FAKE_HOME" \
TRANSCRIPTED_DATA_DIR="$FAKE_HOME/Library/Application Support/Transcripted/captures" \
TRANSCRIPTED_DISABLE_FILE_LOGGER=1 \
TRANSCRIPTED_E2E_ROOT="$WORK_ROOT" \
"$SMOKE_BIN"
