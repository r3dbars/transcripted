#!/bin/bash
# The ReDimNet2 b4 voiceprint model: where the build scripts find it and how
# they check it. Sourced by build.sh, build-beta.sh and
# scripts/models/redimnet2/install.sh so all three agree.
#
# The build copies the compiled model from the local model cache into
# Contents/Resources/$VOICEPRINT_MODEL_BUNDLE_DIR/Model.mlmodelc. The app looks
# there first and falls back to its previous voiceprint model when it can't
# find or load it. The repo never commits the model; see
# scripts/models/redimnet2/README.md for how to put it in the cache.

VOICEPRINT_MODEL_CACHE_DIR="$HOME/Library/Application Support/FluidAudio/Models/redimnet2-b4-slim"
VOICEPRINT_MODEL_CACHE="$VOICEPRINT_MODEL_CACHE_DIR/Model.mlmodelc"
VOICEPRINT_MODEL_BUNDLE_DIR="redimnet2-voiceprint"
# One fixed-length function per input length: 1, 2, 4 and 8 s of 16 kHz audio.
VOICEPRINT_MODEL_FUNCTIONS="len_16000 len_32000 len_64000 len_128000"
VOICEPRINT_MODEL_DIMENSION=192

# Prints what's wrong with a compiled voiceprint model (one line per problem)
# and returns 1, or prints nothing and returns 0 when it's usable: a compiled
# Core ML model with every len_<samples> function, each taking [1, samples]
# audio and returning a [1, 192] embedding.
voiceprint_model_problems() {
    local model="$1"

    if [ ! -d "$model" ]; then
        echo "not found: $model"
        return 1
    fi
    if [ ! -f "$model/coremldata.bin" ] || [ ! -f "$model/model.mil" ] || [ ! -f "$model/metadata.json" ] \
        || [ ! -f "$model/weights/weight.bin" ]; then
        echo "not a compiled Core ML model (coremldata.bin, model.mil, metadata.json or weights/weight.bin missing): $model"
        return 1
    fi

    # shellcheck disable=SC2086 # the function list is space-separated on purpose
    /usr/bin/python3 - "$model/metadata.json" "$VOICEPRINT_MODEL_DIMENSION" $VOICEPRINT_MODEL_FUNCTIONS <<'PY'
import json
import sys

path, dimension, expected = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
try:
    with open(path, encoding="utf-8") as handle:
        metadata = json.load(handle)
    entry = metadata[0] if isinstance(metadata, list) else metadata
    functions = {f.get("name"): f for f in entry.get("functions") or []}
except (OSError, ValueError, AttributeError, IndexError, KeyError, TypeError) as error:
    print(f"unreadable metadata.json ({error.__class__.__name__})")
    sys.exit(1)

problems = []
for name in expected:
    function = functions.get(name)
    if function is None:
        problems.append(f"missing function {name} (has: {', '.join(sorted(n for n in functions if n)) or 'none'})")
        continue
    samples = name.removeprefix("len_")
    inputs = function.get("inputSchema") or []
    outputs = function.get("outputSchema") or entry.get("outputSchema") or []
    if [i.get("shape") for i in inputs] != [f"[1, {samples}]"]:
        problems.append(f"{name} takes {[i.get('shape') for i in inputs]}, expected [1, {samples}]")
    if f"[1, {dimension}]" not in [o.get("shape") for o in outputs]:
        problems.append(f"{name} returns {[o.get('shape') for o in outputs]}, expected [1, {dimension}]")

for problem in problems:
    print(problem)
sys.exit(1 if problems else 0)
PY
}
