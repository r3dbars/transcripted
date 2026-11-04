#!/bin/bash
# Scroll the real Settings › Speakers page (the "Who spoke?" card, the
# directory's person rows, the model and the store) over a fresh temporary
# speaker database of fictional people, and fail if the scroll hangs, jumps
# back, or never reaches the bottom. Compiles the app's own sources (the same
# list build.sh uses) with the smoke as the entry point, the way
# run-post-call-discard-harness.sh does. Opens a borderless window, so it
# needs a GUI session (hosted macOS runners and the owner's Mac job VM have
# one). The child gets a temporary HOME: no real library, prefs or logs.
set -euo pipefail
cd "$(dirname "$0")/../.."
if [ ! -f deps-libs/libDraftDeps.a ] || [ ! -d deps-modules/TranscriptedCore.swiftmodule ]; then
    echo "Dependencies not found — run build-deps.sh first."
    exit 1
fi
OUT_DIR=build/speakers-directory-scroll
mkdir -p "$OUT_DIR"
source scripts/entrypoints/lib/swiftc-app-args.sh
WRITING_CORE_BUILD_DIR="$OUT_DIR/modules"
build_app_swiftc_args
# The app's @main would be a second entry point; drop it from a copy.
python3 - "$OUT_DIR" <<'PY'
import sys
from pathlib import Path
source = Path('Sources/App/TranscriptedApp.swift').read_text()
assert source.count('@main\n') == 1, 'expected one @main in TranscriptedApp.swift'
Path(sys.argv[1], 'TranscriptedApp.swift').write_text(source.replace('@main\n', '', 1))
PY
smoke_sources=()
for source in "${APP_SOURCE_FILES[@]}"; do
    if [ "$source" = Sources/App/TranscriptedApp.swift ]; then
        smoke_sources+=("$OUT_DIR/TranscriptedApp.swift")
    else
        smoke_sources+=("$source")
    fi
done
swiftc -Onone -j "$(sysctl -n hw.ncpu 2>/dev/null || printf 8)" -o "$OUT_DIR/scroll-smoke" \
    "${APP_SWIFTC_LINK_ARGS[@]}" "${smoke_sources[@]}" \
    Tests/UI/SpeakersDirectoryScrollSmoke.swift "${APP_SWIFTC_TAIL_ARGS[@]}" \
    -Xlinker -rpath -Xlinker "$PWD/deps-frameworks"
fixture_home=$(mktemp -d "${TMPDIR:-/tmp}/transcripted-speakers-scroll.XXXXXX")
case "$fixture_home" in
    */transcripted-speakers-scroll.*) trap 'rm -rf "$fixture_home"' EXIT ;;
    *) echo "Unexpected temporary HOME: $fixture_home"; exit 1 ;;
esac
# Child-only HOME override: no application delegate, captures, permission prompts, or telemetry.
env HOME="$fixture_home" CFFIXED_USER_HOME="$fixture_home" TMPDIR="$fixture_home/" \
    TRANSCRIPTED_AUTOMATED_HARNESS=1 TRANSCRIPTED_DISABLE_FILE_LOGGER=1 \
    TRANSCRIPTED_DISABLE_RUNTIME_DIAGNOSTICS=1 \
    "$OUT_DIR/scroll-smoke"
