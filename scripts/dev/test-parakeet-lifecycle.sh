#!/bin/bash
# Compile the actual app-owned lifecycle executor against suspended fake models.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
TEST_DIR="$REPO_ROOT/Tests/Integration/ParakeetLifecycle"
OUT_DIR="$REPO_ROOT/build/parakeet-lifecycle-tests"
mkdir -p "$OUT_DIR"
swiftc -parse-as-library -emit-library -emit-module -module-name FluidAudio \
    "$TEST_DIR/FakeFluidAudio.swift" -o "$OUT_DIR/libFluidAudio.dylib" \
    -emit-module-path "$OUT_DIR/FluidAudio.swiftmodule"
swiftc -parse-as-library -emit-module -module-name TranscriptedCore -D FAKE_CORE \
    "$TEST_DIR/FakeFluidAudio.swift" -emit-module-path "$OUT_DIR/TranscriptedCore.swiftmodule"
compile_log="$OUT_DIR/executor-compile.log"
set +e
swiftc -parse-as-library -I "$OUT_DIR" -L "$OUT_DIR" -lFluidAudio \
    -Xlinker -rpath -Xlinker "$OUT_DIR" \
    Sources/Support/TranscriptionModelPreferences.swift \
    Sources/Support/TranscriptedConstants.swift \
    Sources/Speech/ParakeetRecoveryState.swift \
    Sources/TranscriptedCore/Utilities/SupersessionEpoch.swift \
    Sources/Speech/DictationInputDeviceSelectionPolicy.swift \
    Sources/Speech/ParakeetShortAudioGate.swift \
    Sources/Speech/PinnedDictationSpeedPath.swift \
    Sources/Speech/ParakeetModelState.swift \
    Sources/Speech/ParakeetModelInitDiagnostics.swift \
    Sources/Speech/ParakeetStartRecordingFailurePolicy.swift \
    Sources/Speech/ParakeetModelLifecycle.swift \
    "$TEST_DIR/EngineScaffold.swift" "$TEST_DIR/ExecutorSmoke.swift" \
    -o "$OUT_DIR/executor-smoke" 2>&1 | tee "$compile_log"
compile_status=${PIPESTATUS[0]}
set -e
if [ "$compile_status" -ne 0 ]; then
    python3 "$REPO_ROOT/scripts/dev/explain-missing-sources.py" \
        --log "$compile_log" \
        --list "the swiftc source list in scripts/dev/test-parakeet-lifecycle.sh" || true
    exit "$compile_status"
fi
TRANSCRIPTED_DISABLE_FILE_LOGGER=1 "$OUT_DIR/executor-smoke"
