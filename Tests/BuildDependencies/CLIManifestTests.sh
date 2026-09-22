#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/transcripted-cli-manifest.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
package_dir="$test_root/Tools/TranscriptedCLI"
mkdir -p "$package_dir" "$test_root/deps-modules" "$test_root/deps-libs"
cp "$ROOT_DIR/Tools/TranscriptedCLI/Package.swift" "$package_dir/Package.swift"

# Evaluate the actual manifest with inert fixture files. No compilation,
# dependency fetching, or changes to the real dependency bundle are involved.
dump_manifest() {
    env -u TRANSCRIPTEDCLI_ENABLE_TRANSCRIPTION -u TRANSCRIPTEDCLI_ENABLE_DIARIZATION \
        -u TRANSCRIPTEDCLI_ENABLE_MEETING_IMPORT "$@" \
        swift package --package-path "$package_dir" --manifest-cache none dump-package \
        > "$test_root/manifest.json" 2> "$test_root/manifest.stderr"
}
expect_missing() {
    local expected="$1"
    shift
    if dump_manifest "$@"; then
        echo "FAIL: requested audio mode accepted missing $expected" >&2
        exit 1
    fi
    grep -q 'Requested CLI audio mode is missing prebuilt dependencies:' "$test_root/manifest.stderr"
    grep -q "$expected" "$test_root/manifest.stderr"
}

dump_manifest
if grep -q 'TRANSCRIPTEDCLI_WITH_' "$test_root/manifest.json"; then
    echo 'FAIL: default mode unexpectedly enables audio' >&2
    exit 1
fi
expect_missing FluidAudio TRANSCRIPTEDCLI_ENABLE_TRANSCRIPTION=1
touch "$test_root/deps-modules/FluidAudio.swiftmodule" \
    "$test_root/deps-modules/ArgumentParser.swiftmodule" "$test_root/deps-libs/libDraftDeps.a"
mkdir -p "$test_root/deps-modules/ArgumentParserToolInfo.swiftmodule"
expect_missing ArgumentParserToolInfo TRANSCRIPTEDCLI_ENABLE_TRANSCRIPTION=1
touch "$test_root/deps-modules/ArgumentParserToolInfo.swiftmodule/arm64-apple-macos.swiftmodule"
dump_manifest TRANSCRIPTEDCLI_ENABLE_TRANSCRIPTION=1
grep -q 'TRANSCRIPTEDCLI_WITH_TRANSCRIPTION' "$test_root/manifest.json"
if grep -q 'TRANSCRIPTEDCLI_WITH_MEETING_IMPORT' "$test_root/manifest.json"; then
    echo 'FAIL: basic audio unexpectedly enables meeting Core' >&2
    exit 1
fi
dump_manifest TRANSCRIPTEDCLI_ENABLE_DIARIZATION=1
grep -q 'TRANSCRIPTEDCLI_WITH_DIARIZATION' "$test_root/manifest.json"
expect_missing TranscriptedCore TRANSCRIPTEDCLI_ENABLE_MEETING_IMPORT=1
mkdir -p "$test_root/deps-modules/TranscriptedCore.swiftmodule"
expect_missing TranscriptedCore TRANSCRIPTEDCLI_ENABLE_MEETING_IMPORT=1
touch "$test_root/deps-modules/TranscriptedCore.swiftmodule/arm64-apple-macos.swiftmodule"
dump_manifest TRANSCRIPTEDCLI_ENABLE_MEETING_IMPORT=1
grep -q 'TRANSCRIPTEDCLI_WITH_MEETING_IMPORT' "$test_root/manifest.json"
rm "$test_root/deps-libs/libDraftDeps.a"
mkdir "$test_root/deps-libs/libDraftDeps.a"
expect_missing libDraftDeps.a TRANSCRIPTEDCLI_ENABLE_MEETING_IMPORT=1

echo 'PASS: requested audio modes fail closed, retrieval remains independent, real module files required'
