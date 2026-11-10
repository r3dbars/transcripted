#!/bin/bash
# Exercise the actual full gate with owned command fakes, never native tests.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PYTHON_BIN="$(command -v python3)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/transcripted-full-check.XXXXXX")"
case "$test_root" in
    */transcripted-full-check.*) trap 'rm -rf "$test_root"' EXIT ;;
    *) exit 1 ;;
esac
mkdir -p "$test_root/repo/scripts/entrypoints" "$test_root/repo/scripts/ops" "$test_root/bin"
cp "$ROOT_DIR/check.sh" "$test_root/repo/check.sh"
cp "$ROOT_DIR/scripts/entrypoints/check.sh" "$test_root/repo/scripts/entrypoints/check.sh"
printf '#!/usr/bin/env ruby\n' > "$test_root/repo/scripts/ops/performance-budget.rb"
chmod +x "$test_root/repo/scripts/ops/performance-budget.rb"
cat > "$test_root/bin/command-fake" <<'FAKE'
#!/bin/bash
set -eu
tool="${0##*/}"
if [ "$tool" = bash ]; then
    case "${1:-}" in
        -c|*/repo/scripts/entrypoints/check.sh) exec /bin/bash "$@" ;;
    esac
fi
printf '%s|%s|mode=%s|audio=%s|meeting=%s|diarization=%s|bundled=%s\n' \
    "$tool" "$*" "${TRANSCRIPTEDCLI_EXPECT_BUILD_MODE:-}" "${TRANSCRIPTEDCLI_ENABLE_TRANSCRIPTION:-}" \
    "${TRANSCRIPTEDCLI_ENABLE_MEETING_IMPORT:-}" "${TRANSCRIPTEDCLI_ENABLE_DIARIZATION:-}" \
    "${TRANSCRIPTEDCLI_BUNDLED_HELPER:-}" >> "$FULL_CHECK_LOG"
if [ "$tool" = bash ] && [ "$*" = 'build.sh --no-open' ] && [ "${FULL_CHECK_NEW_RECEIPT:-0}" = 1 ]; then
    [ ! -e build/launch-ui-smoke.json ] || exit 43
    mkdir -p build
    printf '%s\n' '{"launchToInteractiveMs":1}' > build/launch-ui-smoke.json
fi
if [ "$tool" = ruby ] && [ "${1:-}" = scripts/ops/performance-budget.rb ] && [ "${FULL_CHECK_REQUIRE_RECEIPT:-0}" = 1 ]; then
    [ -f build/launch-ui-smoke.json ] || exit 44
fi
if [ -n "${FULL_CHECK_FAIL:-}" ] && [ "$*" = "$FULL_CHECK_FAIL" ]; then exit 42; fi
FAKE
chmod +x "$test_root/bin/command-fake"
for tool in bash python3 swift ruby; do ln -s command-fake "$test_root/bin/$tool"; done

run_gate() {
    local label="$1" failure="$2"
    shift 2
    env PATH="$test_root/bin:$PATH" FULL_CHECK_LOG="$test_root/$label.log" FULL_CHECK_FAIL="$failure" \
        FULL_CHECK_REQUIRE_RECEIPT="${FULL_CHECK_REQUIRE_RECEIPT:-0}" FULL_CHECK_NEW_RECEIPT="${FULL_CHECK_NEW_RECEIPT:-0}" \
        TRANSCRIPTEDCLI_ENABLE_TRANSCRIPTION=1 TRANSCRIPTEDCLI_ENABLE_MEETING_IMPORT=1 \
        TRANSCRIPTEDCLI_ENABLE_DIARIZATION=1 TRANSCRIPTEDCLI_BUNDLED_HELPER=1 \
        TRANSCRIPTEDCLI_EXPECT_BUILD_MODE=unexpected TRANSCRIPTED_MAX_LAUNCH_INTERACTIVE_MS=3000 \
        /bin/bash "$test_root/repo/check.sh" full "$@" > "$test_root/$label.out" 2>&1
}
run_gate complete ''
grep -q '^bash|scripts/dev/test-speaker-settings-model.sh|' "$test_root/complete.log" || {
    echo 'FAIL: full gate omitted the required Speaker settings model smoke' >&2; exit 1
}
if run_gate stopped scripts/dev/test-speaker-settings-model.sh; then
    echo 'FAIL: full gate accepted a failing required smoke' >&2; exit 1
fi
if run_gate continuing scripts/dev/test-speaker-settings-model.sh --keep-going; then
    echo 'FAIL: keep-going hid a failing required smoke' >&2; exit 1
fi
# A skipped native launch must not inherit a previous build's passing receipt.
mkdir -p "$test_root/repo/build"
printf '%s\n' '{"launchToInteractiveMs":1}' > "$test_root/repo/build/launch-ui-smoke.json"
if FULL_CHECK_REQUIRE_RECEIPT=1 run_gate stale ''; then
    echo 'FAIL: full gate accepted a stale receipt after a build produced none' >&2; exit 1
fi
printf '%s\n' '{"launchToInteractiveMs":1}' > "$test_root/repo/build/launch-ui-smoke.json"
FULL_CHECK_REQUIRE_RECEIPT=1 FULL_CHECK_NEW_RECEIPT=1 run_gate fresh ''

# Clearing a receipt must never follow a symlinked build directory.
mv "$test_root/repo/build" "$test_root/saved-build"
mkdir "$test_root/external-build"
printf '%s\n' '{"launchToInteractiveMs":1}' > "$test_root/external-build/launch-ui-smoke.json"
cp "$test_root/external-build/launch-ui-smoke.json" "$test_root/external-before.json"
ln -s "$test_root/external-build" "$test_root/repo/build"
if FULL_CHECK_REQUIRE_RECEIPT=1 run_gate linked ''; then
    echo 'FAIL: full gate accepted a symlinked build directory' >&2; exit 1
fi
if FULL_CHECK_REQUIRE_RECEIPT=1 run_gate linked-continuing '' --keep-going; then
    echo 'FAIL: keep-going accepted a symlinked build directory' >&2; exit 1
fi
cmp "$test_root/external-before.json" "$test_root/external-build/launch-ui-smoke.json"
rm "$test_root/repo/build"
mv "$test_root/saved-build" "$test_root/repo/build"

"$PYTHON_BIN" - "$test_root" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
lines = (root / 'complete.log').read_text().splitlines()
commands = [line.split('|')[1] for line in lines]
required = [
    'scripts/dev/test-speaker-settings-model.sh',
    'scripts/dev/test-speakers-directory-scroll.sh',
    'test --package-path Tools/TranscriptedLive',
]
for command in required:
    assert command in commands, f'full gate omitted required CI validation: {command}'
cli = [line for line in lines if line.startswith('swift|test --package-path Tools/TranscriptedCLI|')]
assert len(cli) == 4, f'expected default CLI suite and three build-mode transitions, got {cli}'
for line, expected in zip(cli, ['', 'audio', 'meeting', 'retrieval']):
    fields = dict(item.split('=', 1) for item in line.split('|')[2:])
    assert fields == {'mode': expected, 'audio': '1' if expected == 'audio' else '',
                      'meeting': '1' if expected == 'meeting' else '', 'diarization': '', 'bundled': ''}, fields
assert commands.index(required[0]) < commands.index(required[1]) < commands.index(required[2])
budget = [command for command in commands if command.startswith('scripts/ops/performance-budget.rb ')]
assert len(budget) == 1, 'full gate omitted required CI performance budget'
assert '--launch-ui-smoke build/launch-ui-smoke.json' in budget[0]
assert '--max-launch-interactive-ms 3000' in budget[0]
assert commands.index('build.sh --no-open') < commands.index(budget[0])
assert not any('run-live-capture-smoke' in command for command in commands), 'full gate requested hardware'
stopped = (root / 'stopped.log').read_text().splitlines()
assert stopped[-1].split('|')[1] == required[0], 'full gate ran more checks after a failure'
continuing = (root / 'continuing.log').read_text().splitlines()
assert continuing == lines, 'keep-going did not run the remaining checks'
for label in ['linked', 'linked-continuing']:
    guarded = (root / f'{label}.log').read_text().splitlines()
    assert not any(line.split('|')[1] == 'build.sh --no-open' for line in guarded), 'unsafe build ran after ownership guard failed'
    assert not any('performance-budget.rb' in line for line in guarded), 'budget ran after ownership guard failed'
print('Full gate CI coverage, mode isolation, fail-stop and keep-going tests passed')
PY
