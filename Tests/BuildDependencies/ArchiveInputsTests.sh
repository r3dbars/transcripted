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
module_helpers="$(awk '
    /^# BEGIN dependency module helpers$/ { capturing = 1; started = 1; next }
    /^# END dependency module helpers$/ { ended = capturing; exit }
    capturing { print }
    END { if (!started || !ended) exit 1 }
' "$BUILD_DEPS")"
[[ "$module_helpers" == *'copy_swift_module_artifact() {'* ]]
[[ "$module_helpers" == *'argument_parser_module_source() {'* ]]
[[ "$module_helpers" == *'export_argument_parser_modules() {'* ]]
eval "$module_helpers"

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

# Native SwiftPM's host-tool library objects must get their matching flat
# Modules-tool interfaces, even if a different normal interface also exists.
SPM_OUTPUT_LAYOUT=legacy
BUILD_PRODUCTS="$test_root/native-products"
MODULES_SRC="$BUILD_PRODUCTS/Modules"
DEPS_MODULES="$test_root/native-export"
ALL_BUILD_DIRS=$'./ArgumentParser-tool.build\n./ArgumentParserToolInfo-tool.build'
mkdir -p "$MODULES_SRC" "$BUILD_PRODUCTS/Modules-tool"
for name in ArgumentParser ArgumentParserToolInfo; do
    for suffix in swiftmodule swiftdoc swiftinterface; do
        printf 'tool-%s-%s' "$name" "$suffix" > "$BUILD_PRODUCTS/Modules-tool/$name.$suffix"
        printf 'normal-%s-%s' "$name" "$suffix" > "$MODULES_SRC/$name.$suffix"
    done
done
export_argument_parser_modules
for name in ArgumentParser ArgumentParserToolInfo; do
    for suffix in swiftmodule swiftdoc swiftinterface; do
        cmp "$BUILD_PRODUCTS/Modules-tool/$name.$suffix" \
            "$DEPS_MODULES/$name.swiftmodule/arm64-apple-macos.$suffix"
    done
done

# Conversely, archived normal targets must use Modules, not Modules-tool.
DEPS_MODULES="$test_root/native-normal-export"
ALL_BUILD_DIRS=$'./ArgumentParser.build\n./ArgumentParserToolInfo.build'
export_argument_parser_modules
for name in ArgumentParser ArgumentParserToolInfo; do
    cmp "$MODULES_SRC/$name.swiftmodule" \
        "$DEPS_MODULES/$name.swiftmodule/arm64-apple-macos.swiftmodule"
done

# Do not guess which interface matches an archive containing both variants.
ALL_BUILD_DIRS=$'./ArgumentParser.build\n./ArgumentParser-tool.build\n./ArgumentParserToolInfo.build'
if export_argument_parser_modules >/dev/null 2>&1; then
    echo 'FAIL: ambiguous parser object variants must be rejected' >&2
    exit 1
fi
ALL_BUILD_DIRS='./FluidAudio.build'
if export_argument_parser_modules >/dev/null 2>&1; then
    echo 'FAIL: parser interfaces without archived parser objects must be rejected' >&2
    exit 1
fi
ALL_BUILD_DIRS=$'./ArgumentParser-tool.build\n./ArgumentParserToolInfo-tool.build'
BUILD_PRODUCTS="$test_root/missing-products"
if export_argument_parser_modules >/dev/null 2>&1; then
    echo 'FAIL: missing matching tool modules must not fall back to normal modules' >&2
    exit 1
fi

# Xcode-backed SwiftPM keeps architecture-qualified module directories in
# Products/Release. Optional doc/interface files are not required.
SPM_OUTPUT_LAYOUT=xcode
MODULES_SRC="$test_root/xcode-products"
DEPS_MODULES="$test_root/xcode-export"
ALL_BUILD_DIRS=$'./Parser.build/Release/ArgumentParser-t.build/Objects-normal/arm64\n./Parser.build/Release/ArgumentParserToolInfo-t.build/Objects-normal/arm64'
for name in ArgumentParser ArgumentParserToolInfo; do
    mkdir -p "$MODULES_SRC/$name.swiftmodule"
    printf 'xcode-%s' "$name" > "$MODULES_SRC/$name.swiftmodule/arm64-apple-macos.swiftmodule"
done
export_argument_parser_modules
for name in ArgumentParser ArgumentParserToolInfo; do
    cmp "$MODULES_SRC/$name.swiftmodule/arm64-apple-macos.swiftmodule" \
        "$DEPS_MODULES/$name.swiftmodule/arm64-apple-macos.swiftmodule"
done
mkdir -p "$test_root/incomplete.swiftmodule"
if copy_swift_module_artifact "$test_root/incomplete.swiftmodule" >/dev/null 2>&1; then
    echo 'FAIL: incomplete architecture-qualified module must be rejected' >&2
    exit 1
fi
cp() { return 23; }
if copy_swift_module_artifact "$MODULES_SRC/ArgumentParser.swiftmodule" >/dev/null 2>&1; then
    echo 'FAIL: module copy errors must propagate' >&2
    exit 1
fi
unset -f cp

echo 'PASS: library-only archives, fail-closed inspection, and matching native/Xcode module exports'
