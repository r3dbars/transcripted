#!/bin/bash
# Put the Nemotron 3 diarizer and the ReDimNet2 b4 voiceprint model into a
# FluidAudio model cache, byte for byte what build-beta.sh expects to bundle.
#
#   bash scripts/release/provision-release-models.sh <models-dir> [options]
#
#   <models-dir>                  e.g. "$HOME/Library/Application Support/FluidAudio/Models"
#   --previous-resources <dir>    a previous app's Contents/Resources (or a copy
#                                 of its nemotron-diarizer-models/ and
#                                 redimnet2-voiceprint/ folders). Used first when
#                                 its files match the pins, so releases keep the
#                                 same model bytes and Sparkle deltas stay small.
#   --redimnet2-archive <zip>     a local copy of the ReDimNet2 archive instead
#                                 of downloading it.
#
# Everything is checked against the sha256 pins below, file by file, with an
# exact file list for each .mlmodelc. Any mismatch exits non-zero and nothing
# half-written is left at the destination. There's no skip switch on purpose:
# a release build must ship exactly these models.
#
# Sources, in order:
#   Nemotron: previous release's nemotron-diarizer-models/, then Hugging Face
#     FluidInference/nemotron-3-diarization-coreml at a pinned commit (the repo
#     FluidAudio 0.17.0's Nemotron3Models.loadFromHuggingFace downloads from).
#   ReDimNet2: previous release's redimnet2-voiceprint/Model.mlmodelc, then the
#     archive on this repo's `models-redimnet2-b4-slim-v1` GitHub release.
#     Nobody else publishes a Core ML build of it (scripts/models/redimnet2).
#
# When a pin changes (FluidAudio bumps Nemotron weights, or a new ReDimNet2
# conversion), update the hashes here in the same PR as the code that needs it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../entrypoints/lib/voiceprint-model.sh
source "$REPO_ROOT/scripts/entrypoints/lib/voiceprint-model.sh"

# --- Nemotron 3 diarizer (FluidAudio 0.17.0, preset fast128) ---------------
NEMOTRON_HF_REPO="FluidInference/nemotron-3-diarization-coreml"
NEMOTRON_HF_REVISION="25a90f97f254428d4b30374b76af9c74fdee8327"
NEMOTRON_CACHE_DIR_NAME="nemotron-3-diarization"
NEMOTRON_BUNDLE_SUBDIR="monolithic/v2"
NEMOTRON_BUNDLE="Nemotron3Diarizer_fast128.mlmodelc"
NEMOTRON_BUNDLE_DIR_IN_APP="nemotron-diarizer-models"
# FluidAudio's ModelNames.Nemotron3.weightsVersion. Its marker file holds this
# plus a newline; a cache without the matching marker gets deleted and
# re-downloaded by FluidAudio, and build-beta.sh refuses to bundle without it.
NEMOTRON_WEIGHTS_VERSION="ga-2026-09-23"
NEMOTRON_MARKER=".fluidaudio-nemotron3-weights"
NEMOTRON_MARKER_SHA256="88a9f21b9c55c00d812de0f079565303fc93cbc3a961c1e96bf223928af4aa72"
NEMOTRON_SIL="learnable_sil_emb.bin"
NEMOTRON_SIL_SHA256="d4417b3c0eabdf7c47032fac2b5b5a7ee83d819a6ddda8fd8eaf74e2b5cc4ac7"
# Every file in the .mlmodelc, "<sha256>  <path inside the bundle>".
NEMOTRON_BUNDLE_MANIFEST="\
a71e06616a3ae7bddef06ce5dfc7fe523a286e489f63a8da2fc4f1e940d560a4  analytics/coremldata.bin
ebcca7245d8d774305752b9f2b79433ad1858f8a06df3b326e0ae6305d981d25  coremldata.bin
e7c029a46d9f327bec4c47fc34e5d32ee2cec9ce596950af0c403d05146b4ead  model.mil
e8c90d2d0e16787a420de6805fd5b7a95c116fac0163208b5bc4d8a9ae459ca4  weights/weight.bin"

# --- ReDimNet2 b4 voiceprint (fp16, len_16000/32000/64000/128000) ----------
REDIMNET2_RELEASE_TAG="models-redimnet2-b4-slim-v1"
REDIMNET2_ARCHIVE_NAME="redimnet2-b4-slim-Model.mlmodelc.zip"
REDIMNET2_URL="${REDIMNET2_MODEL_URL:-https://github.com/r3dbars/transcripted/releases/download/$REDIMNET2_RELEASE_TAG/$REDIMNET2_ARCHIVE_NAME}"
REDIMNET2_CACHE_DIR_NAME="$(basename "$VOICEPRINT_MODEL_CACHE_DIR")"
REDIMNET2_MANIFEST="\
bb19de43dfd54d189df4ab97dd1292e5f22ee4ebd9d1e28d020c0813ddd896ea  analytics/coremldata.bin
69d8b2362bde4dcca69bbe30c57d07205ed18381b7b2d032d4578ee0ca484400  coremldata.bin
f1a5dca78d04a3d0a05e5e8a34f0ae3588c5edb553a9f07e8696e315d2dbebc5  metadata.json
6b3a2bfd090b498d1647637df5ae6856d12a96814e64ed62fb206131cc9e767b  model.mil
15bdfc99009826a4089c3165946cfdfbc44d214e2ea718ab095a9af3332acc1a  weights/weight.bin"

fail() { echo "::error::provision-release-models: $*" >&2; exit 1; }
log() { echo "[provision-models] $*"; }

usage() { sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

DEST=""
PREVIOUS_RESOURCES=""
REDIMNET2_ARCHIVE=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --previous-resources)
            [ "$#" -ge 2 ] || fail "--previous-resources needs a folder"
            PREVIOUS_RESOURCES="$2"; shift 2 ;;
        --redimnet2-archive)
            [ "$#" -ge 2 ] || fail "--redimnet2-archive needs a zip"
            REDIMNET2_ARCHIVE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) usage >&2; exit 2 ;;
        *)
            [ -z "$DEST" ] || { usage >&2; exit 2; }
            DEST="$1"; shift ;;
    esac
done
[ -n "$DEST" ] || { usage >&2; exit 2; }
[ "$(uname -s)" = "Darwin" ] || fail "needs macOS (ditto, Core ML bundles)."

mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd -P)"
# All staging lives in one fresh folder under DEST, so the final moves are
# renames on one volume. The trap only ever removes that folder.
STAGE="$(mktemp -d "$DEST/.provision.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# Prints problems with <dir> against <manifest> (one line each) and returns 1,
# or prints nothing and returns 0. The file list must match exactly.
manifest_problems() {
    local dir="$1" manifest="$2" problems=0 want path got
    if [ ! -d "$dir" ]; then
        echo "not found: $dir"
        return 1
    fi
    local expected actual
    expected="$(printf '%s\n' "$manifest" | awk '{print $2}' | LC_ALL=C sort)"
    actual="$(cd "$dir" && find . -type f ! -name '.DS_Store' | sed 's|^\./||' | LC_ALL=C sort)"
    if [ "$expected" != "$actual" ]; then
        echo "file list differs in $dir:"
        diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed 's/^/  /' || true
        problems=1
    fi
    while read -r want path; do
        [ -n "$path" ] || continue
        [ -f "$dir/$path" ] || continue
        got="$(sha256_of "$dir/$path")"
        if [ "$got" != "$want" ]; then
            echo "sha256 mismatch: $path (got $got, want $want)"
            problems=1
        fi
    done <<< "$manifest"
    return "$problems"
}

file_problems() {
    local file="$1" want="$2" got
    [ -f "$file" ] || { echo "not found: $file"; return 1; }
    got="$(sha256_of "$file")"
    [ "$got" = "$want" ] || { echo "sha256 mismatch: $file (got $got, want $want)"; return 1; }
}

# Nemotron cache layout checked by build-beta.sh and FluidAudio:
#   nemotron-3-diarization/monolithic/v2/<bundle>, learnable_sil_emb.bin, marker.
nemotron_problems() {
    local root="$1" rc=0
    manifest_problems "$root/$NEMOTRON_BUNDLE_SUBDIR/$NEMOTRON_BUNDLE" "$NEMOTRON_BUNDLE_MANIFEST" || rc=1
    file_problems "$root/$NEMOTRON_SIL" "$NEMOTRON_SIL_SHA256" || rc=1
    file_problems "$root/$NEMOTRON_MARKER" "$NEMOTRON_MARKER_SHA256" || rc=1
    return "$rc"
}

hf_fetch() {
    local path="$1" out="$2"
    mkdir -p "$(dirname "$out")"
    curl -fsSL --retry 5 --retry-delay 5 \
        -o "$out" "https://huggingface.co/$NEMOTRON_HF_REPO/resolve/$NEMOTRON_HF_REVISION/$path" \
        || fail "download failed: $NEMOTRON_HF_REPO@$NEMOTRON_HF_REVISION/$path"
}

provision_nemotron() {
    local target="$DEST/$NEMOTRON_CACHE_DIR_NAME"
    if problems="$(nemotron_problems "$target")"; then
        log "Nemotron already in place and matches the pins: $target"
        return 0
    fi

    local staged="$STAGE/nemotron" source=""
    local staged_bundle="$staged/$NEMOTRON_BUNDLE_SUBDIR/$NEMOTRON_BUNDLE"
    mkdir -p "$staged/$NEMOTRON_BUNDLE_SUBDIR"

    local prev="$PREVIOUS_RESOURCES/$NEMOTRON_BUNDLE_DIR_IN_APP"
    if [ -n "$PREVIOUS_RESOURCES" ] && [ -d "$prev/$NEMOTRON_BUNDLE" ]; then
        if manifest_problems "$prev/$NEMOTRON_BUNDLE" "$NEMOTRON_BUNDLE_MANIFEST" >/dev/null \
            && file_problems "$prev/$NEMOTRON_SIL" "$NEMOTRON_SIL_SHA256" >/dev/null; then
            ditto "$prev/$NEMOTRON_BUNDLE" "$staged_bundle"
            cp "$prev/$NEMOTRON_SIL" "$staged/$NEMOTRON_SIL"
            source="previous release"
        else
            echo "::warning::Previous release's Nemotron doesn't match the pins; downloading the pinned copy instead."
        fi
    fi

    if [ -z "$source" ]; then
        log "Downloading Nemotron $NEMOTRON_BUNDLE from $NEMOTRON_HF_REPO@$NEMOTRON_HF_REVISION"
        local want path
        while read -r want path; do
            [ -n "$path" ] || continue
            hf_fetch "$NEMOTRON_BUNDLE_SUBDIR/$NEMOTRON_BUNDLE/$path" "$staged_bundle/$path"
        done <<< "$NEMOTRON_BUNDLE_MANIFEST"
        hf_fetch "$NEMOTRON_SIL" "$staged/$NEMOTRON_SIL"
        source="$NEMOTRON_HF_REPO@$NEMOTRON_HF_REVISION"
    fi
    printf '%s\n' "$NEMOTRON_WEIGHTS_VERSION" > "$staged/$NEMOTRON_MARKER"

    if ! problems="$(nemotron_problems "$staged")"; then
        printf '%s\n' "$problems" >&2
        fail "Nemotron from $source doesn't match the pinned hashes. Nothing was installed."
    fi
    rm -rf "$target"
    mv "$staged" "$target"
    log "Nemotron installed from $source: $target"
}

provision_redimnet2() {
    local target_dir="$DEST/$REDIMNET2_CACHE_DIR_NAME"
    local target="$target_dir/Model.mlmodelc"
    if manifest_problems "$target" "$REDIMNET2_MANIFEST" >/dev/null; then
        log "ReDimNet2 already in place and matches the pins: $target"
        return 0
    fi

    local staged="$STAGE/redimnet2/Model.mlmodelc" source=""
    mkdir -p "$STAGE/redimnet2"

    local prev="$PREVIOUS_RESOURCES/$VOICEPRINT_MODEL_BUNDLE_DIR/Model.mlmodelc"
    if [ -n "$PREVIOUS_RESOURCES" ] && [ -d "$prev" ]; then
        if manifest_problems "$prev" "$REDIMNET2_MANIFEST" >/dev/null; then
            ditto "$prev" "$staged"
            source="previous release"
        else
            echo "::warning::Previous release's ReDimNet2 doesn't match the pins; using the pinned archive instead."
        fi
    fi

    if [ -z "$source" ]; then
        local archive="$REDIMNET2_ARCHIVE"
        if [ -z "$archive" ]; then
            archive="$STAGE/$REDIMNET2_ARCHIVE_NAME"
            log "Downloading ReDimNet2 from $REDIMNET2_URL"
            curl -fsSL --retry 5 --retry-delay 5 -o "$archive" "$REDIMNET2_URL" \
                || fail "download failed: $REDIMNET2_URL (is the $REDIMNET2_RELEASE_TAG release published?)"
            source="$REDIMNET2_URL"
        else
            [ -f "$archive" ] || fail "not found: $archive"
            source="$archive"
        fi
        local unpacked="$STAGE/redimnet2-unpacked"
        mkdir -p "$unpacked"
        ditto -x -k "$archive" "$unpacked" || fail "can't unpack $archive"
        [ -d "$unpacked/Model.mlmodelc" ] || fail "$archive has no top-level Model.mlmodelc"
        mv "$unpacked/Model.mlmodelc" "$staged"
    fi

    if ! problems="$(manifest_problems "$staged" "$REDIMNET2_MANIFEST")"; then
        printf '%s\n' "$problems" >&2
        fail "ReDimNet2 from $source doesn't match the pinned hashes. Nothing was installed."
    fi
    if ! problems="$(voiceprint_model_problems "$staged")"; then
        printf '%s\n' "$problems" >&2
        fail "ReDimNet2 from $source isn't the voiceprint model build-beta.sh expects."
    fi
    mkdir -p "$target_dir"
    rm -rf "$target"
    mv "$staged" "$target"
    log "ReDimNet2 installed from $source: $target"
}

provision_nemotron
provision_redimnet2
log "Done. build-beta.sh will bundle Nemotron ($NEMOTRON_WEIGHTS_VERSION) and ReDimNet2 from $DEST"
