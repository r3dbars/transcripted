#!/bin/bash
# Test-only app/Core deletion boundary. Reuses an already-built debug package;
# never builds dependencies, launches the app, or touches the user's Trash.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
CORE_BUILD_DIR="${TRANSCRIPTED_CORE_BUILD_DIR:-$REPO_ROOT/.build/debug}"
CORE_LIBRARY="$CORE_BUILD_DIR/libTranscriptedCore.a"
CORE_MODULE="$CORE_BUILD_DIR/TranscriptedCore.swiftmodule/arm64-apple-macos.swiftmodule"
OUT_DIR="$REPO_ROOT/build/home-deletion-reservation-tests"

if [ ! -f "$CORE_LIBRARY" ] || [ ! -f "$CORE_MODULE" ] || [ ! -f "$REPO_ROOT/deps-libs/libExternalDeps.a" ]; then
    echo "Missing debug Core package artifacts or external dependencies. Run build-deps.sh and swift test first." >&2
    echo "Expected debug package directory: $CORE_BUILD_DIR" >&2
    exit 1
fi

# Do not silently exercise an old Core implementation after production edits.
while IFS= read -r source; do
    if [ "$source" -nt "$CORE_LIBRARY" ]; then
        echo "Debug Core library is older than $source; run swift test first." >&2
        exit 1
    fi
done < <(find Sources/TranscriptedCore -name '*.swift' -type f -print)

MODULE_FLAGS=(-I "$CORE_BUILD_DIR" -I "$REPO_ROOT/deps-modules")
for directory in "$REPO_ROOT"/deps-modules/*/; do
    [ -d "$directory" ] || continue
    case "$(basename "$directory")" in
        *.swiftmodule) continue ;;
    esac
    MODULE_FLAGS+=(-I "$directory")
done

mkdir -p "$OUT_DIR"
swiftc -parse-as-library -Onone -target arm64-apple-macos26.0 \
    "${MODULE_FLAGS[@]}" -F "$REPO_ROOT/deps-frameworks" \
    Sources/Support/CaptureLibraryPathSafety.swift \
    Sources/Support/TranscriptedStoragePaths.swift \
    Sources/Meeting/MeetingStoragePaths.swift \
    Sources/Meeting/MeetingArtifactRenamer.swift \
    Sources/Meeting/MeetingArtifactRenameTransaction.swift \
    Sources/Meeting/MeetingArtifactRecoveryStore.swift \
    Sources/UI/Shared/MeetingAudioArchiveResolver.swift \
    Sources/UI/Shared/HomeMeetingDeletion.swift \
    Sources/UI/Shared/CaptureUndo.swift \
    Sources/UI/Shared/LibraryTokens.swift \
    Tests/Integration/HomeMeetingDeletion/ReservationSmoke.swift \
    "$CORE_LIBRARY" -L "$REPO_ROOT/deps-libs" -lExternalDeps -lc++ -lsqlite3 \
    -framework AppKit -framework SwiftUI -framework Combine \
    -framework AVFoundation -framework CoreML -framework CoreAudio \
    -framework Metal -framework MetalKit -framework Accelerate \
    -framework Network -framework UserNotifications -framework ScreenCaptureKit \
    -Xlinker -rpath -Xlinker "$REPO_ROOT/deps-frameworks" \
    -o "$OUT_DIR/reservation-smoke"

TRANSCRIPTED_DISABLE_FILE_LOGGER=1 "$OUT_DIR/reservation-smoke"
