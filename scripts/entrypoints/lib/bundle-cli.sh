#!/bin/bash
# Shared by the authoritative local and distribution app builds. Call before
# their existing nested-helper signing loop; never install a shell/PATH shim.

bundle_transcripted_cli() {
    local repo_root="$1"
    local app_bundle="$2"
    local package_path="$repo_root/Tools/TranscriptedCLI"
    local bin_directory
    local bundled_binary="$app_bundle/Contents/Helpers/transcripted-cli"
    local build_args=(-c release --package-path "$package_path" --product transcripted-cli
        -Xlinker -rpath -Xlinker '@executable_path/../Frameworks')

    echo "Building Transcripted CLI with the full meeting pipeline..."
    TRANSCRIPTEDCLI_ENABLE_MEETING_IMPORT=1 swift build "${build_args[@]}" || return 1
    bin_directory="$(TRANSCRIPTEDCLI_ENABLE_MEETING_IMPORT=1 swift build "${build_args[@]}" --show-bin-path)" || return 1
    if [ ! -x "$bin_directory/transcripted-cli" ]; then
        echo "CLI build finished without a runnable transcripted-cli" >&2
        return 1
    fi

    mkdir -p "$app_bundle/Contents/Helpers" || return 1
    cp "$bin_directory/transcripted-cli" "$bundled_binary" || return 1
    chmod 755 "$bundled_binary" || return 1
    # Help text exists even in retrieval mode. Inspect the compiled executable,
    # including its packaged runtime linkage, before allowing it to be signed.
    if ! "$bundled_binary" build-info | python3 -c '
import json, sys
info = json.load(sys.stdin)
expected = {"mode": "meeting", "transcription": True, "diarization": True, "meetingImport": True}
if info != expected:
    sys.exit("Packaged transcripted-cli lacks the full meeting pipeline")
'; then
        echo "Packaged transcripted-cli capability check failed" >&2
        return 1
    fi
}
