#!/bin/bash
# Scroll the real Settings › Dictations and Settings › Meetings lists (the
# shared day-grouped Home list, the view model and Load More) over a fresh
# temporary capture library, and fail if successive Load More clicks hang,
# jump the scroll back, or never grow the list. Compiles the app's own
# sources (the same list build.sh uses) with the smoke as the entry point,
# the way test-speakers-directory-scroll.sh does. Opens a borderless window,
# so it needs a GUI session (hosted macOS runners and the owner's Mac job
# VM have one). Requires an approved CI or separate OS account; a temporary
# HOME does not isolate CFPreferences. Fixture captures and logs stay under
# the owned container. Does not touch Speakers.
set -euo pipefail
cd "$(dirname "$0")/../.."
# Fail before compiling or launching anything on the owner's account.
python3 scripts/ops/native-smoke-isolation.py
python3 scripts/dev/test-capture-list-fixture-paths.py
if [ ! -f deps-libs/libDraftDeps.a ] || [ ! -d deps-modules/TranscriptedCore.swiftmodule ]; then
    echo "Dependencies not found — run build-deps.sh first."
    exit 1
fi
OUT_DIR=build/capture-list-load-more-scroll
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
    Tests/UI/CaptureListFixturePaths.swift \
    Tests/UI/CaptureListLoadMoreScrollSmoke.swift Tests/UI/CaptureListScrollDiagnostics.swift "${APP_SWIFTC_TAIL_ARGS[@]}" \
    -Xlinker -rpath -Xlinker "$PWD/deps-frameworks"
fixture_parent=$(cd "${TMPDIR:-/tmp}" && pwd -P)
fixture_home=$(mktemp -d "$fixture_parent/transcripted-capture-list-scroll.XXXXXX")
fixture_home=$(cd "$fixture_home" && pwd -P)
cleanup_fixture() {
    local resolved_fixture
    resolved_fixture=$(cd "$fixture_home" && pwd -P) || {
        echo "Fixture cleanup failed: owned directory is unavailable" >&2; exit 1;
    }
    if [[ "$resolved_fixture" != "$fixture_home" || "${resolved_fixture%/*}" != "$fixture_parent" ||
          "${resolved_fixture##*/}" != transcripted-capture-list-scroll.* ]]; then
        echo "Refusing fixture cleanup outside its canonical owned parent" >&2; exit 1
    fi
    rm -rf -- "$resolved_fixture" || {
        echo "Fixture cleanup failed" >&2; exit 1;
    }
}
trap cleanup_fixture EXIT
mkdir -m 700 "$fixture_home/container"
# Fixture paths after native-account preflight; HOME alone is not preference isolation.
harness_environment=(env HOME="$fixture_home" CFFIXED_USER_HOME="$fixture_home" TMPDIR="$fixture_home/"
    TRANSCRIPTED_CONTAINER_DIR="$fixture_home/container"
    TRANSCRIPTED_CAPTURE_LIST_FIXTURE_PARENT="$fixture_parent"
    TRANSCRIPTED_AUTOMATED_HARNESS=1 TRANSCRIPTED_DISABLE_FILE_LOGGER=1
    TRANSCRIPTED_DISABLE_RUNTIME_DIAGNOSTICS=1)
# The compiled scenario list owns selection; no second count/list can drift.
manifest="$OUT_DIR/scenarios.txt"
"${harness_environment[@]}" "$OUT_DIR/scroll-smoke" --list-scenarios > "$manifest"
read -r scenario_count selection_digest < <(python3 - "$manifest" <<'PY'
import hashlib
from pathlib import Path
import sys

with Path(sys.argv[1]).open("rb") as handle:
    data = handle.read(16385)
    if not data or len(data) > 16384:
        raise SystemExit("Invalid scroll scenario manifest")
    scenarios = data.decode("utf-8").splitlines()
    if any(not scenario.strip() for scenario in scenarios) or len(set(scenarios)) != len(scenarios):
        raise SystemExit("Invalid scroll scenario selection")
    print(len(scenarios), hashlib.sha256(data).hexdigest())
PY
)
"${harness_environment[@]}" python3 scripts/entrypoints/lib/fast-test-completion.py \
    --run-root "$fixture_home" --expected-functions "$scenario_count" \
    --selection-digest "$selection_digest" -- "$OUT_DIR/scroll-smoke"
