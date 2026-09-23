#!/bin/bash
# Exercise the real packaging function with inert executables, not a model build.
set -euo pipefail
TEST_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$TEST_ROOT/scripts/entrypoints/lib/bundle-cli.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/transcripted-cli-packaging.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
export CLI_TEST_BIN_DIR="$fixture/compiled output"
mkdir -p "$CLI_TEST_BIN_DIR"

swift() {
    [ "${TRANSCRIPTEDCLI_ENABLE_MEETING_IMPORT:-}" = "1" ] || return 81
    [[ "$*" == *"-c release"* ]] || return 82
    [[ "$*" == *"--product transcripted-cli"* ]] || return 83
    [[ "$*" == *"@executable_path/../Frameworks"* ]] || return 84
    [ "${TRANSCRIPTEDCLI_BUNDLED_HELPER:-}" = "1" ] || return 86
    if [[ "$*" == *"--show-bin-path"* ]]; then
        printf '%s\n' "$CLI_TEST_BIN_DIR"
    fi
}

# The inert fixture is a script, not Mach-O. Report its rpaths in otool's
# `-l` shape so the packaging check parses the same layout it sees for real.
otool() {
    [ "$1" = "-l" ] || return 87
    printf 'Load command 12\n          cmd LC_BUILD_VERSION\n'
    local rpath
    while IFS= read -r rpath; do
        [ -n "$rpath" ] || continue
        printf 'Load command 13\n          cmd LC_RPATH\n      cmdsize 48\n         path %s (offset 12)\n' "$rpath"
    done <<< "$CLI_TEST_RPATHS"
}
export CLI_TEST_RPATHS='@executable_path/../Frameworks
/usr/lib/swift'

cat > "$CLI_TEST_BIN_DIR/transcripted-cli" <<'FAKE'
#!/bin/bash
[ "$1" = "build-info" ] || exit 85
printf '%s\n' "$CLI_TEST_CAPABILITIES"
exit "${CLI_TEST_EXIT_CODE:-0}"
FAKE
chmod 755 "$CLI_TEST_BIN_DIR/transcripted-cli"
export CLI_TEST_CAPABILITIES='{"mode":"meeting","transcription":true,"diarization":true,"meetingImport":true}'
bundle_transcripted_cli "$TEST_ROOT" "$fixture/Relocated Candidate.app"
test -x "$fixture/Relocated Candidate.app/Contents/Helpers/transcripted-cli"

for invalid in \
    '{"mode":"retrieval","transcription":false,"diarization":false,"meetingImport":false}' \
    '{"mode":"audio","transcription":true,"diarization":true,"meetingImport":false}' \
    '{"mode":"meeting","transcription":false,"diarization":true,"meetingImport":true}' \
    'not json'; do
    export CLI_TEST_CAPABILITIES="$invalid"
    if bundle_transcripted_cli "$TEST_ROOT" "$fixture/Rejected.app" >/dev/null 2>&1; then
        echo "FAIL: accepted incomplete or invalid CLI capability output" >&2
        exit 1
    fi
done

export CLI_TEST_CAPABILITIES='{"mode":"meeting","transcription":true,"diarization":true,"meetingImport":true}'
for checkout_rpath in "$TEST_ROOT/deps-frameworks" "/Users/builder/Other Checkout/deps-frameworks"; do
    export CLI_TEST_RPATHS="@executable_path/../Frameworks
$checkout_rpath"
    if bundle_transcripted_cli "$TEST_ROOT" "$fixture/Checkout Linked.app" >/dev/null 2>&1; then
        echo "FAIL: accepted a helper that searches a checkout for frameworks: $checkout_rpath" >&2
        exit 1
    fi
done
export CLI_TEST_RPATHS='@executable_path/../Frameworks'

export CLI_TEST_EXIT_CODE=1
if bundle_transcripted_cli "$TEST_ROOT" "$fixture/Failed.app" >/dev/null 2>&1; then
    echo "FAIL: accepted a failing capability command" >&2
    exit 1
fi

# Both public entrypoints must invoke the shared function before their signing
# calls. The function definition of sign_embedded_* necessarily appears earlier.
python3 - "$TEST_ROOT" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for entrypoint, signing_call in [("build.sh", '    sign_embedded_code "$SIGN_HASH"'),
                                 ("build-beta.sh", '    sign_embedded_payloads "$SIGNING_IDENTITY"')]:
    source = (root / "scripts/entrypoints" / entrypoint).read_text()
    invocation = 'bundle_transcripted_cli "$REPO_ROOT" "$APP_BUNDLE"'
    assert source.count(invocation) == 1, entrypoint
    assert source.index(invocation) < source.index(signing_call), entrypoint
    assert '"$APP_BUNDLE"/Contents/Helpers/*' in source, entrypoint
print("CLI packaging contracts passed")
PY
