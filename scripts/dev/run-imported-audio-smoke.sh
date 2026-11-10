#!/bin/bash
# Build the Core-only synthetic producer, then let QA validate its real outputs.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$REPO_ROOT"
DEPS_BUILD_STAMP="$REPO_ROOT/deps-libs/.build-deps-stamp"
source scripts/entrypoints/lib/deps-staleness.sh
if [ ! -f deps-libs/libDraftDeps.a ] || [ ! -d deps-modules/TranscriptedCore.swiftmodule ] \
    || [ -z "$(deps_build_stamp_digest)" ] || [ "$(dependency_input_digest)" != "$(deps_build_stamp_digest)" ]; then
    echo 'BLOCKED: current Core dependencies are required; run bash build-deps.sh --force.' >&2
    exit 3
fi
out="$REPO_ROOT/build/imported-audio-artifact-smoke"
for directory in "$REPO_ROOT/build" "$out"; do
    if [ -L "$directory" ] || { [ -e "$directory" ] && [ ! -d "$directory" ]; }; then
        echo 'BLOCKED: producer build output must be real directories under this checkout.' >&2
        exit 3
    fi
done
if [ -L "$out/producer" ]; then
    echo 'BLOCKED: refusing a symlinked producer executable.' >&2
    exit 3
fi
mkdir -p "$out"
# Unlink a previous build artifact before the compiler opens the destination.
rm -f "$out/producer"
module_flags=(-I "$REPO_ROOT/deps-modules")
for directory in "$REPO_ROOT"/deps-modules/*/; do
    [ -d "$directory" ] || continue
    case "$(basename "$directory")" in *.swiftmodule) continue ;; esac
    module_flags+=(-I "$directory")
done
swiftc -parse-as-library -target arm64-apple-macos26.0 -O \
    "${module_flags[@]}" -F "$REPO_ROOT/deps-frameworks" \
    -L "$REPO_ROOT/deps-libs" -lDraftDeps -lsqlite3 -lc++ \
    -Xlinker -rpath -Xlinker "$REPO_ROOT/deps-frameworks" \
    -framework AppKit -framework AVFoundation -framework Combine \
    -framework CoreML -framework CoreAudio -framework Metal -framework MetalKit \
    -framework Accelerate -framework Network -framework UserNotifications \
    Tests/Integration/ImportedAudioArtifactSmoke.swift -o "$out/producer"
if [ "${1:-}" = --build-only ]; then exit 0; fi
TRANSCRIPTED_DISABLE_FILE_LOGGER=1 TRANSCRIPTED_DISABLE_RUNTIME_DIAGNOSTICS=1 \
    swift run --package-path Tools/TranscriptedQA transcripted-qa imported-audio-smoke --producer "$out/producer" "$@"
