#!/usr/bin/env bash
# Convert Moondream's Parakeet Ultra to Core ML and install it for Transcripted.
#
#   bash scripts/models/parakeet-ultra/install.sh
#
# Needs: macOS on Apple Silicon, the full Xcode app (for xcrun coremlcompiler),
# uv, git, network access to github.com and huggingface.co, ~15 GB of free disk
# for the build workspace, and Transcripted opened once so Parakeet V3 is on
# this Mac. Afterwards "Parakeet Ultra (Experimental)" appears in Settings >
# General > Model. See README.md in this folder.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# FluidInference/mobius revision whose v3 exporter matches FluidAudio 0.15.4.
MOBIUS_REPO="https://github.com/FluidInference/mobius.git"
MOBIUS_COMMIT="b10771c3fc33ec6bd64615aece144986333806d0"

APP_SUPPORT="$HOME/Library/Application Support"
WORK_DIR="${PARAKEET_ULTRA_WORK_DIR:-$HOME/Library/Caches/Transcripted/parakeet-ultra-build}"
INSTALL_ROOT="${PARAKEET_ULTRA_INSTALL_ROOT:-$APP_SUPPORT/Transcripted/models}"
ENCODER="${PARAKEET_ULTRA_ENCODER:-palettize8}"

fail() { echo "error: $*" >&2; exit 1; }

# Upstream model pins (see pins.env). The env vars override the revisions for
# a one-off build; a checksum pin only applies to the revision it was taken at.
ULTRA_REVISION=""; ULTRA_SAFETENSORS_SHA256=""; BASE_REVISION=""; BASE_NEMO_SHA256=""
[[ -f "$HERE/pins.env" ]] || fail "Missing $HERE/pins.env."
# shellcheck source=pins.env
. "$HERE/pins.env"
if [[ -n "${PARAKEET_ULTRA_REVISION:-}" && "$PARAKEET_ULTRA_REVISION" != "$ULTRA_REVISION" ]]; then
    ULTRA_REVISION="$PARAKEET_ULTRA_REVISION"
    ULTRA_SAFETENSORS_SHA256=""
fi
if [[ -n "${PARAKEET_ULTRA_BASE_REVISION:-}" && "$PARAKEET_ULTRA_BASE_REVISION" != "$BASE_REVISION" ]]; then
    BASE_REVISION="$PARAKEET_ULTRA_BASE_REVISION"
    BASE_NEMO_SHA256=""
fi
PINS_COMPLETE=1
[[ -n "$ULTRA_REVISION" && -n "$ULTRA_SAFETENSORS_SHA256" && -n "$BASE_REVISION" && -n "$BASE_NEMO_SHA256" ]] || PINS_COMPLETE=0

[[ "$(uname -s)" == "Darwin" ]] || fail "Core ML compilation needs macOS."
[[ "$(uname -m)" == "arm64" ]] || fail "Transcripted runs on Apple Silicon only."
command -v uv >/dev/null || fail "uv is not installed (https://docs.astral.sh/uv/)."
command -v git >/dev/null || fail "git is not installed."
xcrun --find coremlcompiler >/dev/null 2>&1 || fail "xcrun coremlcompiler not found. It comes with the full Xcode app (not just the command line tools): install Xcode, then run: sudo xcode-select -s /Applications/Xcode.app"

mkdir -p "$WORK_DIR"
MOBIUS_DIR="$WORK_DIR/mobius"
if [[ ! -d "$MOBIUS_DIR/.git" ]]; then
    echo "==> Cloning FluidInference/mobius"
    git clone --filter=blob:none "$MOBIUS_REPO" "$MOBIUS_DIR"
fi
git -C "$MOBIUS_DIR" fetch --quiet origin "$MOBIUS_COMMIT" 2>/dev/null || git -C "$MOBIUS_DIR" fetch --quiet origin
# This clone is our own build workspace: throw away any leftover edits or files
# so the converter is exactly the pinned commit. (Only ever inside $MOBIUS_DIR.)
git -C "$MOBIUS_DIR" checkout --quiet --force --detach "$MOBIUS_COMMIT"
git -C "$MOBIUS_DIR" clean -fdq
[[ "$(git -C "$MOBIUS_DIR" rev-parse HEAD)" == "$MOBIUS_COMMIT" ]] || fail "mobius checkout isn't at $MOBIUS_COMMIT."

CONVERTER_DIR="$MOBIUS_DIR/models/stt/parakeet-tdt-v3-0.6b/coreml"
cd "$CONVERTER_DIR"

echo "==> Setting up the converter's Python environment (first run takes a while)"
# mobius pins Python 3.10 + scipy 1.15.3, and macOS 27 won't load that scipy
# (see converter_env.py). Move just those two pins to 3.11 + scipy 1.16.3,
# re-lock, and stop if anything else in mobius's lock changed.
py311() { uv run --no-project --python 3.11 python "$@"; }
cp uv.lock "$WORK_DIR/mobius-uv.lock"
py311 "$HERE/converter_env.py" patch pyproject.toml
uv lock --quiet
py311 "$HERE/converter_env.py" check-lock "$WORK_DIR/mobius-uv.lock" uv.lock
uv sync --frozen
uv run --frozen --no-sync python -c 'import scipy.signal, scipy.sparse.linalg' \
    || fail "The converter's scipy still won't load on this Mac. Send the lines above to Claude."

run_py() { uv run --frozen --no-sync python "$@"; }

echo "==> Rebuilding Parakeet Ultra as a NeMo checkpoint"
pin_args=()
if [[ -n "$ULTRA_REVISION" ]]; then pin_args+=(--revision "$ULTRA_REVISION"); fi
if [[ -n "$BASE_REVISION" ]]; then pin_args+=(--base-revision "$BASE_REVISION"); fi
if [[ -n "$ULTRA_SAFETENSORS_SHA256" ]]; then pin_args+=(--expect-ultra-sha256 "$ULTRA_SAFETENSORS_SHA256"); fi
if [[ -n "$BASE_NEMO_SHA256" ]]; then pin_args+=(--expect-base-sha256 "$BASE_NEMO_SHA256"); fi
rm -f "$WORK_DIR/nemo/build-info.json" "$WORK_DIR/resolved-pins.env"
run_py "$HERE/build_ultra_nemo.py" \
    --output-dir "$WORK_DIR/nemo" \
    --sanity-audio "$CONVERTER_DIR/audio/yc_first_minute_16k_15s.wav" \
    ${pin_args[@]+"${pin_args[@]}"}

echo "==> Exporting Core ML models"
rm -rf "$WORK_DIR/coreml"
# convert-parakeet.py is a single-command typer app, so no "convert" subcommand.
run_py convert-parakeet.py \
    --nemo-path "$WORK_DIR/nemo/parakeet-ultra.nemo" \
    --output-dir "$WORK_DIR/coreml" \
    --compute-precision FLOAT16

echo "==> Packaging and installing"
run_py "$HERE/package_coreml.py" \
    --coreml-dir "$WORK_DIR/coreml" \
    --stock-dir "/Applications/Transcripted.app/Contents/Resources/parakeet-models/parakeet-tdt-0.6b-v3" \
    --stock-dir "$HOME/Applications/Transcripted.app/Contents/Resources/parakeet-models/parakeet-tdt-0.6b-v3" \
    --stock-dir "$APP_SUPPORT/FluidAudio/Models/parakeet-tdt-0.6b-v3" \
    --build-info "$WORK_DIR/nemo/build-info.json" \
    --install-root "$INSTALL_ROOT" \
    --mobius-commit "$MOBIUS_COMMIT" \
    --encoder "$ENCODER"

ULTRA_DIR="$INSTALL_ROOT/parakeet-ultra/parakeet-tdt-0.6b-v3"
CLI=""
for candidate in "/Applications/Transcripted.app/Contents/Helpers/transcripted-cli" \
                 "$HOME/Applications/Transcripted.app/Contents/Helpers/transcripted-cli"; do
    [[ -x "$candidate" ]] && CLI="$candidate" && break
done
if [[ -n "$CLI" ]]; then
    echo "==> Checking that Transcripted's engine can run it"
    engine_ok=1
    TRANSCRIPTED_DISABLE_FILE_LOGGER=1 "$CLI" transcribe --no-download --models-dir "$ULTRA_DIR" \
        "$CONVERTER_DIR/audio/yc_first_minute_16k_15s.wav" || engine_ok=0
    # Older CLIs let FluidAudio replace a folder it can't load with stock v3,
    # which deletes the marker. Catch that instead of calling it a success.
    if [[ "$engine_ok" == 0 || ! -f "$ULTRA_DIR/transcripted-model.json" ]]; then
        rm -rf "$INSTALL_ROOT/parakeet-ultra"
        fail "Transcripted couldn't run the converted model, so it was removed. Nothing is installed."
    fi
else
    echo "(Transcripted.app not found in Applications; skipped the engine check.)"
fi

echo
echo "Done. Parakeet Ultra is installed at:"
echo "  $ULTRA_DIR"
echo "Pick \"Parakeet Ultra (Experimental)\" in Transcripted > Settings > General > Model."
echo "The build workspace ($WORK_DIR) can be deleted to free space."

if [[ "$PINS_COMPLETE" == 0 ]]; then
    RESOLVED="$WORK_DIR/resolved-pins.env"
    # Read back what the build actually used (build_ultra_nemo.py records it).
    if run_py - "$WORK_DIR/nemo/build-info.json" > "$RESOLVED" <<'PY'
import json, sys
info = json.load(open(sys.argv[1]))
for key, field in (("ULTRA_REVISION", "revision"), ("ULTRA_SAFETENSORS_SHA256", "safetensors_sha256"),
                   ("BASE_REVISION", "base_revision"), ("BASE_NEMO_SHA256", "base_nemo_sha256")):
    if not info.get(field):
        sys.exit(f"build-info.json has no {field}")
    print(f'{key}="{info[field]}"')
PY
    then
        echo
        echo "pins.env didn't pin every model version for this build (empty pins or an env"
        echo "override), so part of it used whatever Hugging Face had today. These are the exact"
        echo "versions it used (also saved to $RESOLVED):"
        echo
        sed 's/^/    /' "$RESOLVED"
        echo
        echo "Paste them into $HERE/pins.env and commit it so later builds are reproducible."
    else
        rm -f "$RESOLVED"
        echo
        echo "warning: couldn't read the versions this build used from $WORK_DIR/nemo/build-info.json," >&2
        echo "so there is nothing to pin yet. The installed model is fine." >&2
    fi
fi
