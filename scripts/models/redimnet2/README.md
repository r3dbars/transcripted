# ReDimNet2 b4 voiceprint model

Transcripted names people in meetings by comparing voiceprints. Its default
voiceprint model is ReDimNet2 b4 (Palabra.ai's
[redimnet2](https://github.com/PalabraAI/redimnet2), `b4-vox2-lm` weights),
the winner of the voiceprint bake-off
(`Tools/SpeakerEvalHarness/VOICEPRINT_RESULTS.md`).

Nobody publishes a Core ML build of it, and the repo never commits model
files. So the model lives in the local model cache, and the build scripts copy
it into the app:

- cache: `~/Library/Application Support/FluidAudio/Models/redimnet2-b4-slim/Model.mlmodelc`
- app: `Transcripted.app/Contents/Resources/redimnet2-voiceprint/Model.mlmodelc`

The app looks in its bundle first, then the cache. Without either it falls back
to its previous voiceprint model (WeSpeaker and `speakers.sqlite`).
`bash build.sh` bundles the model when the cache has it and says so when it
doesn't. `bash build-beta.sh` refuses to build without it, unless you set
`REQUIRE_BUNDLED_VOICEPRINT_MODEL=0 BUNDLE_VOICEPRINT_MODEL=0`.

## The model

A fused Core ML model: raw 16 kHz mono audio in, a 192-d embedding out
(compare with cosine). It's a multifunction model with one fixed-length
function per input length, `len_16000`, `len_32000`, `len_64000` and
`len_128000` (1, 2, 4 and 8 s), stored fp16 (about 15 MB) and run on the GPU.
Fixed lengths keep Core ML on the GPU; the app tiles or windows each speaker
turn to fit. `scripts/entrypoints/lib/voiceprint-model.sh` checks all four
functions before anything is bundled or installed.

## Install

```bash
bash scripts/models/redimnet2/install.sh                  # the bake-off's build in this checkout
bash scripts/models/redimnet2/install.sh --from <path>    # a Model.mlmodelc, or a model.mlpackage to compile
bash scripts/models/redimnet2/install.sh --convert        # convert the PyTorch weights first
```

With no arguments it installs the bake-off's build,
`data/eval/voiceprint/coreml/redimnet2-b4-vox2-lm-slim/model.mlpackage`,
compiled with `xcrun coremlcompiler` (needs the full Xcode app). `--from` takes
any copy of the model, for example one from another Mac or from a built
`Transcripted.app`. `--convert` runs
`scripts/voiceprint/convert/redimnet_slim.py build --tag install --lengths 1,2,4,8 --precision fp16`,
which converts the PyTorch checkpoint and measures each function against
PyTorch on the lab's parity clips; the install stops if any cosine on
`CPU_AND_GPU`, the compute units the app uses, is under 0.999 (the bake-off
build scored 0.99999). A fresh conversion produces the same `weight.bin`,
byte for byte, as the bake-off build. It writes its own
folder, `data/eval/voiceprint/coreml/redimnet2-b4-vox2-lm-install/`, so the
bake-off's build stays as it was. It needs the voiceprint lab's Python
environment (`data/eval/voiceprint/venv`), the checkpoint and code in
`data/eval/voiceprint/models/redimnet2-b4-vox2-lm/`, and the lab's clips; see
`Tools/SpeakerEvalHarness/VOICEPRINT_BAKEOFF.md`.

Every path compiles or copies into a staging folder, checks the four
functions, and only then replaces the installed copy, so a bad model never
lands. `REDIMNET2_INSTALL_DIR` installs somewhere else (for testing);
`VP_ROOT` points at a different voiceprint lab folder.

Quit and reopen Transcripted afterwards; it loads the model once per launch.

## Remove it

```bash
rm -rf ~/Library/Application\ Support/FluidAudio/Models/redimnet2-b4-slim
```

The app then falls back to WeSpeaker. People already learned with ReDimNet2
stay in `speakers_redimnet2-b4.sqlite` and come back when the model does.

## License and credit

ReDimNet2 is MIT-licensed (Copyright (c) 2026 Palabra.ai; the repo license
also covers the released weights). Parts of its code carry ID R&D, Inc.'s MIT
notice from the original [ReDimNet](https://github.com/IDRnD/redimnet). The
weights were trained on VoxCeleb2 (CC BY 4.0). Transcripted converts them to
Core ML unchanged otherwise. The full notices ship in the app as
`THIRD_PARTY_LICENSES.md`.
