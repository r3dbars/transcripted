#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p .agent-review/visuals build/call-app-hint-harness
source scripts/entrypoints/lib/swiftc-app-args.sh
WRITING_CORE_BUILD_DIR=build/call-app-hint-harness/modules
build_app_swiftc_args
python3 - <<'PY'
from pathlib import Path
source = Path('Sources/App/TranscriptedApp.swift').read_text()
assert source.count('@main\n') == 1
Path('build/call-app-hint-harness/TranscriptedApp.swift').write_text(source.replace('@main\n', '', 1))
PY
harness_sources=()
for source in "${APP_SOURCE_FILES[@]}"; do
    if [ "$source" = Sources/App/TranscriptedApp.swift ]; then
        harness_sources+=(build/call-app-hint-harness/TranscriptedApp.swift)
    else
        harness_sources+=("$source")
    fi
done
swiftc -Onone -o build/call-app-hint-harness/review-harness \
    "${APP_SWIFTC_LINK_ARGS[@]}" "${harness_sources[@]}" \
    Tests/UI/CallAppHintHarness.swift "${APP_SWIFTC_TAIL_ARGS[@]}" \
    -Xlinker -rpath -Xlinker "$PWD/deps-frameworks"
fixture_root=$(mktemp -d /tmp/transcripted-call-app-hint.XXXXXX)
trap 'rm -rf "$fixture_root"' EXIT
mkdir -p "$fixture_root/home"
# Child-only HOME override: no application delegate, captures, permission prompts, or telemetry.
env HOME="$fixture_root/home" CFFIXED_USER_HOME="$fixture_root/home" \
    CALL_APP_HINT_FIXTURE_ROOT="$fixture_root" TRANSCRIPTED_AUTOMATED_HARNESS=1 \
    TRANSCRIPTED_DISABLE_FILE_LOGGER=1 TRANSCRIPTED_DISABLE_RUNTIME_DIAGNOSTICS=1 \
    build/call-app-hint-harness/review-harness
