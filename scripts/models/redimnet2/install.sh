#!/usr/bin/env bash
# Put the ReDimNet2 b4 voiceprint model where Transcripted and the build
# scripts look for it.
#
#   bash scripts/models/redimnet2/install.sh                 # this checkout's bake-off build
#   bash scripts/models/redimnet2/install.sh --from <path>   # a Model.mlmodelc or model.mlpackage
#   bash scripts/models/redimnet2/install.sh --convert       # convert the PyTorch weights first
#
# Installs ~/Library/Application Support/FluidAudio/Models/redimnet2-b4-slim/Model.mlmodelc
# (REDIMNET2_INSTALL_DIR names another folder). Needs macOS and, for a
# .mlpackage, the full Xcode app (xcrun coremlcompiler). See README.md here.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=../../entrypoints/lib/voiceprint-model.sh
source "$REPO_ROOT/scripts/entrypoints/lib/voiceprint-model.sh"

VP="${VP_ROOT:-$REPO_ROOT/data/eval/voiceprint}"
# The voiceprint bake-off's build (redimnet_slim.py build --tag slim).
BAKEOFF_BUILD="$VP/coreml/redimnet2-b4-vox2-lm-slim"
# --convert writes its own folder so it never overwrites the bake-off's build.
CONVERT_TAG="install"
CONVERT_BUILD="$VP/coreml/redimnet2-b4-vox2-lm-$CONVERT_TAG"
INSTALL_DIR="${REDIMNET2_INSTALL_DIR:-$VOICEPRINT_MODEL_CACHE_DIR}"

fail() { echo "error: $*" >&2; exit 1; }

usage() {
    sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

SOURCE=""
CONVERT=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --from)
            [ "$#" -ge 2 ] || fail "--from needs a path to a .mlmodelc or .mlpackage"
            SOURCE="$2"
            shift 2
            ;;
        --convert)
            CONVERT=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done
if [ -n "$SOURCE" ] && [ "$CONVERT" = "1" ]; then
    fail "use --from or --convert, not both"
fi

[ "$(uname -s)" = "Darwin" ] || fail "Core ML models only compile and run on macOS."

if [ "$CONVERT" = "1" ]; then
    PYTHON="$VP/venv/bin/python"
    [ -x "$PYTHON" ] || fail "no converter environment at $VP/venv. It's the voiceprint lab's Python environment; see README.md."
    [ -f "$VP/models/redimnet2-b4-vox2-lm/model.json" ] \
        || fail "no ReDimNet2 b4 weights at $VP/models/redimnet2-b4-vox2-lm; see README.md."
    echo "==> Converting ReDimNet2 b4 to Core ML (fp16, 1/2/4/8 s functions)"
    VP_ROOT="$VP" "$PYTHON" "$REPO_ROOT/scripts/voiceprint/convert/redimnet_slim.py" build \
        --tag "$CONVERT_TAG" --lengths 1,2,4,8 --precision fp16
    # The converter measures each function against PyTorch but doesn't judge
    # it. The app runs the model on CPU_AND_GPU, where the bake-off build's
    # worst clip scored 0.99999; under 0.999 the conversion is broken. (fp16
    # on CPU_ONLY scores about 0.97 and the app never uses it.)
    echo "==> Checking the conversion against PyTorch"
    /usr/bin/python3 - "$CONVERT_BUILD/report.json" <<'PY' || fail "the conversion doesn't match PyTorch. Nothing was installed."
import json
import sys

parity = json.load(open(sys.argv[1], encoding="utf-8")).get("parity_vs_torch") or {}
gpu = parity.get("CPU_AND_GPU") or {}
nonfinite = sum(row.get("nonfinite") or 0 for row in parity.values())
print(f"  worst cosine on CPU_AND_GPU: {gpu.get('min')}, non-finite outputs: {nonfinite}")
if gpu.get("min") is None or gpu["min"] < 0.999 or nonfinite:
    sys.exit(1)
PY
    SOURCE="$CONVERT_BUILD/model.mlpackage"
elif [ -z "$SOURCE" ]; then
    if [ -d "$BAKEOFF_BUILD/model.mlpackage" ]; then
        SOURCE="$BAKEOFF_BUILD/model.mlpackage"
    elif [ -d "$BAKEOFF_BUILD/model.mlmodelc" ]; then
        SOURCE="$BAKEOFF_BUILD/model.mlmodelc"
    else
        fail "no converted model at $BAKEOFF_BUILD. Pass --from <path> or --convert (see README.md)."
    fi
fi

SOURCE="${SOURCE%/}"
[ -d "$SOURCE" ] || fail "not found: $SOURCE"
case "$SOURCE" in
    *.mlpackage|*.mlmodelc) ;;
    *) fail "expected a .mlmodelc or .mlpackage folder: $SOURCE" ;;
esac
if [[ "$SOURCE" == *.mlpackage ]]; then
    xcrun --find coremlcompiler >/dev/null 2>&1 \
        || fail "xcrun coremlcompiler not found. It comes with the full Xcode app: install Xcode, then run: sudo xcode-select -s /Applications/Xcode.app"
fi

mkdir -p "$INSTALL_DIR"
# Stage next to the destination so the final move is a rename on one volume.
# The trap only ever removes this fresh mktemp folder.
STAGE="$(mktemp -d "$INSTALL_DIR/.install.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

if [[ "$SOURCE" == *.mlpackage ]]; then
    echo "==> Compiling $SOURCE"
    xcrun coremlcompiler compile "$SOURCE" "$STAGE" >/dev/null
    COMPILED="$STAGE/$(basename "${SOURCE%.mlpackage}").mlmodelc"
    [ -d "$COMPILED" ] || fail "coremlcompiler didn't produce $COMPILED"
    [ "$COMPILED" = "$STAGE/Model.mlmodelc" ] || mv "$COMPILED" "$STAGE/Model.mlmodelc"
else
    echo "==> Copying $SOURCE"
    ditto "$SOURCE" "$STAGE/Model.mlmodelc"
fi

echo "==> Checking its functions ($VOICEPRINT_MODEL_FUNCTIONS)"
if ! problems="$(voiceprint_model_problems "$STAGE/Model.mlmodelc")"; then
    printf '%s\n' "$problems" | sed 's/^/  /' >&2
    fail "that isn't the ReDimNet2 voiceprint model Transcripted expects. Nothing was installed."
fi

# Swap it in. Only ever removes the one Model.mlmodelc folder in INSTALL_DIR.
rm -rf "$INSTALL_DIR/Model.mlmodelc"
mv "$STAGE/Model.mlmodelc" "$INSTALL_DIR/Model.mlmodelc"

echo
echo "Done. The ReDimNet2 voiceprint model is installed at:"
echo "  $INSTALL_DIR/Model.mlmodelc"
echo "  weights sha256 $(shasum -a 256 "$INSTALL_DIR/Model.mlmodelc/weights/weight.bin" | awk '{print $1}')"
if [ "$INSTALL_DIR" = "$VOICEPRINT_MODEL_CACHE_DIR" ]; then
    echo "Quit and reopen Transcripted to use it. bash build.sh and build-beta.sh now bundle it."
fi
