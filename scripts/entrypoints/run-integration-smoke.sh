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

set -euo pipefail

ENTRYPOINT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ENTRYPOINT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

SMOKE_BIN="$REPO_ROOT/build/app-core-integration-smoke"
WAKE_SMOKE_BIN="$REPO_ROOT/build/wake-recovery-integration-smoke"
DEPS_FRAMEWORK_ROOT="$REPO_ROOT/deps-frameworks"
DEPS_ARCHIVE="$REPO_ROOT/deps-libs/libDraftDeps.a"
DEPS_BUILD_STAMP="$REPO_ROOT/deps-libs/.build-deps-stamp"
DEPS_MODULE_ROOT="$REPO_ROOT/deps-modules"
TRANSCRIPTED_CORE_MODULE="$DEPS_MODULE_ROOT/TranscriptedCore.swiftmodule/arm64-apple-macos.swiftmodule"
ARGMAX_CORE_MODULE="$DEPS_MODULE_ROOT/ArgmaxCore.swiftmodule/arm64-apple-macos.swiftmodule"
WHISPERKIT_MODULE="$DEPS_MODULE_ROOT/WhisperKit.swiftmodule/arm64-apple-macos.swiftmodule"
ESPEAK_FRAMEWORK="$DEPS_FRAMEWORK_ROOT/ESpeakNG.framework"

dependency_input_paths() {
    {
        printf '%s\n' "Package.swift"
        printf '%s\n' "scripts/entrypoints/build-deps.sh"
        find "Sources/TranscriptedCore" -type f ! -name "CLAUDE.md"
    } | sort
}

dependency_input_listing() {
    dependency_input_paths | while IFS= read -r path; do
        [ -e "$path" ] || continue
        printf '%s\t%s\n' "$(stat -f '%m' "$path")" "$path"
    done
}

dependency_input_digest() {
    dependency_input_paths | while IFS= read -r path; do
        [ -f "$path" ] || continue
        shasum -a 256 "$path"
    done | shasum -a 256 | awk '{print $1}'
}

newest_dependency_input() {
    dependency_input_listing | awk 'NR == 1 || $1 > max { max = $1; line = $0 } END { if (line != "") print line }'
}

deps_build_stamp_info() {
    if [ -f "$DEPS_BUILD_STAMP" ]; then
        printf '%s\t%s\n' "$(stat -f '%m' "$DEPS_BUILD_STAMP")" "$DEPS_BUILD_STAMP"
    fi
}

deps_build_stamp_digest() {
    if [ -f "$DEPS_BUILD_STAMP" ]; then
        awk -F= '$1 == "dependency_inputs_sha256" { print $2; exit }' "$DEPS_BUILD_STAMP"
    fi
}

if [ ! -f "$DEPS_ARCHIVE" ] || [ ! -f "$DEPS_BUILD_STAMP" ] || [ ! -d "$DEPS_MODULE_ROOT" ] || [ ! -f "$TRANSCRIPTED_CORE_MODULE" ] || [ ! -f "$ARGMAX_CORE_MODULE" ] || [ ! -f "$WHISPERKIT_MODULE" ] || [ ! -d "$ESPEAK_FRAMEWORK" ]; then
    echo "Dependencies not found — run build-deps.sh first."
    exit 1
fi

newest_input="$(newest_dependency_input)"
build_stamp="$(deps_build_stamp_info)"
IFS=$'\t' read -r newest_input_mtime newest_input_path <<< "$newest_input"
IFS=$'\t' read -r build_stamp_mtime build_stamp_path <<< "$build_stamp"
if [ -n "$newest_input_mtime" ] && [ -n "$build_stamp_mtime" ] && [ "$newest_input_mtime" -gt "$build_stamp_mtime" ]; then
    echo "Dependencies are stale for TranscriptedCore."
    echo "Newest input:"
    echo "  $newest_input_path"
    echo "Built deps stamp:"
    echo "  $build_stamp_path"
    echo ""
    echo "Run: bash build-deps.sh --force"
    exit 1
fi

current_digest="$(dependency_input_digest)"
stamp_digest="$(deps_build_stamp_digest)"
if [ -z "$stamp_digest" ] || [ "$current_digest" != "$stamp_digest" ]; then
    echo "Dependencies are stale for TranscriptedCore."
    echo "Dependency input digest changed."
    echo "  current: ${current_digest:-missing}"
    echo "  stamp:   ${stamp_digest:-missing}"
    echo ""
    echo "Run: bash build-deps.sh --force"
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
