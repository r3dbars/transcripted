#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# Only this dedicated build subtree is writable; never build/Transcripted.app.
python3 - <<'PYROOT'
from pathlib import Path
root = Path.cwd().resolve()
for path in [root / "build", root / "build/call-app-hint-harness"]:
    if path.is_symlink() or path.resolve() != path:
        raise SystemExit("Refusing a redirected harness build directory")
    path.mkdir(exist_ok=True)
PYROOT
harness_build="$PWD/build/call-app-hint-harness"
run_root=$(mktemp -d "$harness_build/run.XXXXXX")
run_id=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
printf '%s' "$run_id" > "$run_root/owned-run"
fixture_root="$run_root/fixture"
mkdir -p "$fixture_root/container" "$run_root/output"
cleanup() {
    python3 - "$run_root" "$run_id" <<'PYCLEAN'
from pathlib import Path
import shutil, sys
root = Path(sys.argv[1])
fixture = root / "fixture"
if (root.is_symlink() or root.resolve() != root or not root.name.startswith("run.")
        or (root / "owned-run").read_text() != sys.argv[2]
        or fixture.is_symlink() or fixture.resolve().parent != root):
    raise SystemExit("Refusing unowned harness cleanup")
if fixture.exists():
    shutil.rmtree(fixture)
PYCLEAN
}
completed=false
finish() {
    local status=$?
    trap - EXIT
    # Some shell setup failures can otherwise exit zero before the validator.
    if [ "$completed" != true ] && [ "$status" -eq 0 ]; then status=1; fi
    cleanup || status=1
    exit "$status"
}
trap finish EXIT
source scripts/entrypoints/lib/swiftc-app-args.sh
WRITING_CORE_BUILD_DIR="$harness_build/modules"
build_app_swiftc_args
python3 - <<'PYSOURCE'
from pathlib import Path
source = Path('Sources/App/TranscriptedApp.swift').read_text()
assert source.count('@main\n') == 1
Path('build/call-app-hint-harness/TranscriptedApp.swift').write_text(source.replace('@main\n', '', 1))
PYSOURCE
harness_sources=()
for source in "${APP_SOURCE_FILES[@]}"; do
    if [ "$source" = Sources/App/TranscriptedApp.swift ]; then
        harness_sources+=(build/call-app-hint-harness/TranscriptedApp.swift)
    else
        harness_sources+=("$source")
    fi
done
swiftc -Onone -o "$harness_build/review-harness" \
    ${APP_SWIFTC_LINK_ARGS[@]+"${APP_SWIFTC_LINK_ARGS[@]}"} "${harness_sources[@]}" \
    Tests/UI/CallAppHintHarness.swift Tests/UI/CallAppHintHarnessIsolation.swift ${APP_SWIFTC_TAIL_ARGS[@]+"${APP_SWIFTC_TAIL_ARGS[@]}"} \
    -Xlinker -rpath -Xlinker "$PWD/deps-frameworks"
selection_digest=$(printf '%s\n' 'call-app-hint-page-v1' | shasum -a 256 | awk '{print $1}')
# Explicit container + process-only volatile defaults in the Swift host.
# The page component does not instantiate analytics or submit Core answers.
env CALL_APP_HINT_RUN_ROOT="$run_root" CALL_APP_HINT_RUN_ID="$run_id" \
    CALL_APP_HINT_SELECTION_DIGEST="$selection_digest" TRANSCRIPTED_CONTAINER_DIR="$fixture_root/container" \
    TRANSCRIPTED_AUTOMATED_HARNESS=1 TRANSCRIPTED_DISABLE_FILE_LOGGER=1 TRANSCRIPTED_DISABLE_RUNTIME_DIAGNOSTICS=1 \
    python3 scripts/entrypoints/lib/fast-test-completion.py \
    --run-root "$run_root" --expected-functions 4 --selection-digest "$selection_digest" \
    -- "$harness_build/review-harness"
printf 'Owned page-component output: %s\n' "$run_root/output"
completed=true
