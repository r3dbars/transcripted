#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DEPS="$ROOT_DIR/scripts/entrypoints/build-deps.sh"

# Exercise the exact production helpers without running dependency resolution
# or compilation. Fail closed if the source block or either helper disappears.
helper_source="$(awk '
    /^# BEGIN dependency archive helpers$/ { capturing = 1; started = 1; next }
    /^# END dependency archive helpers$/ { ended = capturing; exit }
    capturing { print }
    END { if (!started || !ended) exit 1 }
' "$BUILD_DEPS")"
[[ "$helper_source" == *'filter_library_build_dirs() {'* ]]
[[ "$helper_source" == *'assert_no_archive_entry_point() {'* ]]
eval "$helper_source"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/transcripted-archive-inputs.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

# Mock the symbol reader, not the filter. An invocation lacking any required
# nm flag fails, and fake input errors must propagate through both helpers.
fixture_nm() {
    [[ "${1:-}" == '-U' && "${2:-}" == '-g' && "${3:-}" == '-j' ]] || return 91
    shift 3
    local object
    for object in "$@"; do
        case "$object" in
            */unreadable/*) return 37 ;;
            */entry.o|*/contaminated/*) printf '_main\n' ;;
            */decoy.o) printf '__main\n_main_helper\n' ;;
            *) printf '_library_symbol\n' ;;
        esac
    done
}
NM_BIN=fixture_nm

native_library="$test_root/native/ArgumentParser.build"
native_tool="$test_root/native/encuda.build"
xcode_library="$test_root/xcode/Release/FluidAudio-t.build/Objects-normal/arm64"
xcode_tool="$test_root/xcode/Release/encuda-tool.build/Objects-normal/arm64"
empty_target="$test_root/empty.build"
unreadable_target="$test_root/unreadable/Library.build"
mkdir -p "$native_library" "$native_tool" "$xcode_library" "$xcode_tool" \
    "$empty_target" "$unreadable_target"
touch "$native_library/library.o" "$native_library/decoy.o" \
    "$native_tool/entry.o" "$native_tool/helper.o" \
    "$xcode_library/library.o" "$xcode_tool/entry.o" "$xcode_tool/helper.o" \
    "$unreadable_target/library.o"

directories="$(printf '%s\n' "$native_library" "$native_tool" "$xcode_library" "$xcode_tool" "$empty_target")"
expected="$(printf '%s\n' "$native_library" "$xcode_library")"
actual="$(filter_library_build_dirs "$directories")"
[[ "$actual" == "$expected" ]]
if filter_library_build_dirs "$test_root/missing.build" >/dev/null 2>&1; then
    echo 'FAIL: target enumeration errors must propagate' >&2
    exit 1
fi
if filter_library_build_dirs "$unreadable_target" >/dev/null 2>&1; then
    echo 'FAIL: target inspection errors must propagate' >&2
    exit 1
fi

for archive in libDraftDeps.a libExternalDeps.a; do
    assert_no_archive_entry_point "$test_root/clean/$archive"
    if assert_no_archive_entry_point "$test_root/contaminated/$archive" >/dev/null 2>&1; then
        echo "FAIL: $archive accepted an executable entry point" >&2
        exit 1
    fi
    if assert_no_archive_entry_point "$test_root/unreadable/$archive" >/dev/null 2>&1; then
        echo "FAIL: $archive ignored an inspection failure" >&2
        exit 1
    fi
done

echo 'PASS: library targets retained, executable targets excluded, both archive guards fail closed'
