#!/bin/bash
# Run the real SQLiteHandle resource contract in its own system-SQLite process.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$REPO_ROOT"
if [ "$(uname -s)" != Darwin ]; then
    echo "SQLiteHandle fixture requires the macOS Swift toolchain." >&2
    exit 1
fi
export TRANSCRIPTED_DISABLE_FILE_LOGGER=1

sqlite_fixture_parent="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
sqlite_fixture_uuid="$(/usr/bin/uuidgen)"
if [[ ! "$sqlite_fixture_uuid" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
    echo "SQLiteHandle fixture could not create an owned run identity." >&2
    exit 1
fi
sqlite_fixture_leaf="transcripted-sqlite-open-$sqlite_fixture_uuid"
sqlite_fixture_root="$sqlite_fixture_parent/$sqlite_fixture_leaf"
mkdir -m 700 "$sqlite_fixture_root"

cleanup_sqlite_fixture() {
    local result=$?
    trap - EXIT
    local canonical_root
    if [ -L "$sqlite_fixture_root" ] || [ ! -d "$sqlite_fixture_root" ]; then
        echo "SQLiteHandle fixture refused cleanup of an unowned run root." >&2
        exit 1
    fi
    if ! canonical_root="$(cd "$sqlite_fixture_root" && pwd -P)"; then
        echo "SQLiteHandle fixture could not validate its cleanup root." >&2
        exit 1
    fi
    if [ "$canonical_root" != "$sqlite_fixture_parent/$sqlite_fixture_leaf" ] || \
       [ "$(basename "$canonical_root")" != "$sqlite_fixture_leaf" ] || \
       [ "$(dirname "$canonical_root")" != "$sqlite_fixture_parent" ]; then
        echo "SQLiteHandle fixture refused cleanup outside its owned parent." >&2
        exit 1
    fi
    if ! rm -rf -- "$sqlite_fixture_root"; then
        echo "SQLiteHandle fixture cleanup failed." >&2
        exit 1
    fi
    exit "$result"
}
trap cleanup_sqlite_fixture EXIT

# Compiler caches and intermediate objects are owned by this invocation too.
mkdir "$sqlite_fixture_root/tmp" "$sqlite_fixture_root/module-cache"
export TMPDIR="$sqlite_fixture_root/tmp/"
sqlite_fixture_sdk="$(xcrun --sdk macosx --show-sdk-path)"
sqlite_fixture_sources="Tests/Integration/SQLiteHandleOpen"

xcrun clang -target arm64-apple-macos26.0 -isysroot "$sqlite_fixture_sdk" \
    -c "$sqlite_fixture_sources/SQLiteBootstrap.c" \
    -o "$sqlite_fixture_root/bootstrap.o"
xcrun swiftc -parse-as-library -target arm64-apple-macos26.0 \
    -sdk "$sqlite_fixture_sdk" \
    -module-cache-path "$sqlite_fixture_root/module-cache" \
    -import-objc-header "$sqlite_fixture_sources/SQLiteBootstrap.h" \
    Sources/TranscriptedCore/Storage/SQLiteHandle.swift \
    Sources/TranscriptedCore/Utilities/FilePermissions.swift \
    "$sqlite_fixture_sources/SQLiteHandleOpenTests.swift" \
    "$sqlite_fixture_root/bootstrap.o" -lsqlite3 \
    -o "$sqlite_fixture_root/sqlite-handle-open"

"$sqlite_fixture_root/sqlite-handle-open" "$sqlite_fixture_root"
