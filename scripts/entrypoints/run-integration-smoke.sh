#!/bin/bash
# run-integration-smoke.sh — App/Core smoke verification
#
# Compiles and runs Tests/Integration/AppCoreIntegrationSmoke.swift against deps-libs/
# libDraftDeps.a to confirm TranscriptedCore is bundled and the Core types
# Meeting code depends on (CoreStoragePaths, Audio, DiarizationService,
# SpeakerDatabase, FailedTranscriptionManager, TranscriptionTaskManager)
# can be constructed from a fresh Swift binary.
#
# Intentionally kept separate from run-tests.sh: the pure-function test suite
# compiles only Foundation/AppKit sources in ~2s and must stay that fast for
# the tight edit loop. This script pays the full Core + FluidAudio link cost.

set -e

ENTRYPOINT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ENTRYPOINT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

SMOKE_BIN="$REPO_ROOT/build/app-core-integration-smoke"
WAKE_SMOKE_BIN="$REPO_ROOT/build/wake-recovery-integration-smoke"
DEPS_FRAMEWORK_ROOT="$REPO_ROOT/deps-frameworks"
ESPEAK_FRAMEWORK="$DEPS_FRAMEWORK_ROOT/ESpeakNG.framework"

if [ ! -f "$REPO_ROOT/deps-libs/libDraftDeps.a" ] || [ ! -d "$REPO_ROOT/deps-modules" ] || [ ! -d "$ESPEAK_FRAMEWORK" ]; then
    echo "Dependencies not found — run build-deps.sh first."
    exit 1
fi

mkdir -p "$REPO_ROOT/build"

# Build the -I flags for every module directory in deps-modules.
DEPS_MODULE_FLAGS="-Ideps-modules"
for dir in "$REPO_ROOT"/deps-modules/*/; do
    [ -d "$dir" ] || continue
    case "$(basename "$dir")" in
        *.swiftmodule) continue ;;
    esac
    DEPS_MODULE_FLAGS="$DEPS_MODULE_FLAGS -I$dir"
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
    -framework ESpeakNG \
    -lc++ \
    $DEPS_MODULE_FLAGS \
    $DEPS_FRAMEWORK_FLAGS \
    -Ldeps-libs -lDraftDeps \
    -Xlinker -rpath -Xlinker "$REPO_ROOT/deps-frameworks" \
    "$REPO_ROOT/Tests/Integration/AppCoreIntegrationSmoke.swift" \
    -parse-as-library \
    -target arm64-apple-macos26.0 \
    -Xlinker -rpath -Xlinker "$DEPS_FRAMEWORK_ROOT" \
    2>&1

echo "Compiling wake recovery smoke…"
swiftc \
    -O \
    -o "$WAKE_SMOKE_BIN" \
    "$REPO_ROOT/Sources/Reliability/WakeRecoveryCoordinator.swift" \
    "$REPO_ROOT/Tests/Integration/WakeRecoveryIntegrationSmoke.swift" \
    -parse-as-library \
    -target arm64-apple-macos26.0 \
    2>&1

echo ""
echo "Running core smoke…"
TRANSCRIPTED_DISABLE_FILE_LOGGER=1 "$SMOKE_BIN"

echo ""
echo "Running wake smoke…"
TRANSCRIPTED_DISABLE_FILE_LOGGER=1 "$WAKE_SMOKE_BIN"

echo ""
echo "Running recovery merge package tests…"
TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift test --filter MicRecordingFileMergerTests
