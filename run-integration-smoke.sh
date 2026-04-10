#!/bin/bash
# run-integration-smoke.sh — Lane B Task #6 verification
#
# Compiles and runs SmokeTests/CoreIntegrationSmoke.swift against deps-libs/
# libDraftDeps.a to confirm TranscriptedCore is bundled and the Core types
# Meeting code depends on (CoreStoragePaths, Audio, DiarizationService,
# SpeakerDatabase, FailedTranscriptionManager, TranscriptionTaskManager)
# can be constructed from a fresh Swift binary.
#
# Intentionally kept separate from run-tests.sh: the pure-function test suite
# compiles only Foundation/AppKit sources in ~2s and must stay that fast for
# the tight edit loop. This script pays the full Core + FluidAudio link cost.

set -e

DRAFT_DIR="$(cd "$(dirname "$0")" && pwd)"
SMOKE_BIN="$DRAFT_DIR/build/core-integration-smoke"
WAKE_SMOKE_BIN="$DRAFT_DIR/build/wake-recovery-smoke"

if [ ! -f "$DRAFT_DIR/deps-libs/libDraftDeps.a" ] || [ ! -d "$DRAFT_DIR/deps-modules" ] || [ ! -d "$DRAFT_DIR/deps-frameworks/ESpeakNG.framework" ]; then
    echo "Dependencies not found — run build-deps.sh first."
    exit 1
fi

mkdir -p "$DRAFT_DIR/build"

# Build the -I flags for every module directory in deps-modules.
DEPS_MODULE_FLAGS="-Ideps-modules"
for dir in "$DRAFT_DIR"/deps-modules/*/; do
    [ -d "$dir" ] && DEPS_MODULE_FLAGS="$DEPS_MODULE_FLAGS -I$dir"
done
DEPS_FRAMEWORK_FLAGS="-Fdeps-frameworks"

echo "Compiling core integration smoke…"
swiftc \
    -O \
    -o "$SMOKE_BIN" \
    -framework AppKit \
    -framework AVFoundation \
    -framework Combine \
    -framework CoreML \
    -framework CoreAudio \
    -framework ESpeakNG \
    -framework Metal \
    -framework MetalKit \
    -framework Accelerate \
    -framework Network \
    -framework UserNotifications \
    -lc++ \
    $DEPS_MODULE_FLAGS \
    $DEPS_FRAMEWORK_FLAGS \
    -Ldeps-libs -lDraftDeps \
    -Xlinker -rpath -Xlinker "$DRAFT_DIR/deps-frameworks" \
    "$DRAFT_DIR/SmokeTests/CoreIntegrationSmoke.swift" \
    -parse-as-library \
    -target arm64-apple-macos14.0 \
    2>&1

echo "Compiling wake recovery smoke…"
swiftc \
    -O \
    -o "$WAKE_SMOKE_BIN" \
    "$DRAFT_DIR/Sources/Reliability/WakeRecoveryCoordinator.swift" \
    "$DRAFT_DIR/SmokeTests/WakeRecoverySmoke.swift" \
    -parse-as-library \
    -target arm64-apple-macos14.0 \
    2>&1

echo ""
echo "Running core smoke…"
"$SMOKE_BIN"

echo ""
echo "Running wake smoke…"
"$WAKE_SMOKE_BIN"

echo ""
echo "Running recovery merge package tests…"
swift test --filter MicRecordingFileMergerTests
