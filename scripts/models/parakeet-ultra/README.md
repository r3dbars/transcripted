# Parakeet Ultra (experimental)

[Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra) is Moondream's
retrained version of NVIDIA's `parakeet-tdt-0.6b-v3`, the model Transcripted
ships as Parakeet V3. It has the same architecture, size and tokenizer.
Moondream reports fewer word errors than stock v3 (5.80% vs 6.26% on English,
and bigger gains in noise and on long recordings). Those numbers were measured
on NVIDIA GPUs with Moondream's own runtime, so this folder exists to find out
whether the gains hold on a Mac, inside Transcripted.

Nobody publishes a Core ML build of Ultra, so Transcripted never downloads it.
This script converts it on your Mac and installs it where the app looks.

## Install

```bash
bash scripts/models/parakeet-ultra/install.sh
```

Needs macOS on Apple Silicon, the full Xcode app (for `coremlcompiler`), [uv](https://docs.astral.sh/uv/),
network access to GitHub and Hugging Face, about 15 GB free for the build
workspace, and Transcripted opened once so Parakeet V3 is on the Mac.

What it does:

1. Pins [FluidInference/mobius](https://github.com/FluidInference/mobius), the
   converter that produced FluidAudio's own v3 Core ML models, and resets its
   clone to that exact commit (discarding any edits in the build workspace).
2. `build_ultra_nemo.py` fetches Ultra and NVIDIA's v3 `.nemo` at the commits
   in `pins.env` (see below), checks their sha256, loads stock v3 in NeMo,
   swaps in Ultra's weights (renaming them from Transformers to NeMo names),
   and stops unless every
   weight lines up, the config and tokenizer match v3, and a test clip still
   transcribes sensibly.
3. mobius exports Core ML models from that checkpoint.
4. `package_coreml.py` palettizes the encoder to 8 bits with k-means, compiles
   everything, checks each model's inputs and outputs against stock v3, copies
   v3's preprocessor and vocabulary (unchanged in Ultra), and installs to
   `~/Library/Application Support/Transcripted/models/parakeet-ultra/`.
5. If Transcripted is in Applications, its CLI transcribes the test clip with
   the installed model as a final check.

Then pick **Parakeet Ultra (Experimental)** in Settings > General > Model. It
stays hidden there until it's installed.

Environment overrides: `PARAKEET_ULTRA_REVISION` and
`PARAKEET_ULTRA_BASE_REVISION` (use a different Hugging Face commit of Ultra or
NVIDIA's v3 than `pins.env` says), `PARAKEET_ULTRA_ENCODER=fp16` (skip
palettization), `PARAKEET_ULTRA_WORK_DIR`, `PARAKEET_ULTRA_INSTALL_ROOT`.

### Pinning the model versions

`pins.env` holds the Hugging Face commit of each upstream model and the sha256
of its weights (`model.safetensors` for Ultra, the `.nemo` for NVIDIA's v3).
With every pin filled in, each build converts exactly those files and stops if
a download doesn't match. The pins start empty because they have to be read
from Hugging Face: the first build uses the current commits, prints a
ready-to-paste `pins.env` block and saves it to `resolved-pins.env` in the
build workspace. Paste that into `pins.env` and commit it, and later builds on
any Mac are reproducible. The installed model's `transcripted-model.json` and
`ATTRIBUTION.txt` record the commits and checksum either way.

## Compare it with Parakeet V3

```bash
python3 scripts/ops/compare-parakeet-models.py ~/Desktop/test-clips/
```

Runs both models through Transcripted's CLI on the same files and writes a
report to the Desktop. Put a hand-checked transcript next to a recording
(`standup.m4a` + `standup.txt`) to get a real word error rate for each model.
Without one, the report shows how often they disagree and where. Use
`--ultra-dir` for an Ultra copy somewhere else; it has to be a folder named
`parakeet-tdt-0.6b-v3`, because that's the only name the engine loads.

The report says which encoder quantization Ultra used. By default the encoder
is palettized to 8 bits with k-means on your Mac, which may not match how
stock v3's encoder was quantized. To rule quantization out, build with
`PARAKEET_ULTRA_ENCODER=fp16` once and compare again.

## Remove it

Pick another model in Settings, then delete what the install left behind:

```bash
rm -rf ~/Library/Application\ Support/Transcripted/models/parakeet-ultra  # the installed model
rm -rf ~/Library/Caches/Transcripted/parakeet-ultra-build                  # build workspace (~15 GB)
rm -rf ~/.cache/huggingface/hub/models--moondream--parakeet-ultra         # Ultra download
rm -rf ~/.cache/huggingface/hub/models--nvidia--parakeet-tdt-0.6b-v3      # NVIDIA v3 .nemo download
uv cache clean                                                            # torch and the converter's other packages
```

`uv cache clean` empties uv's whole cache, not just this build's packages. The
comparison script writes its reports to the Desktop
(`parakeet-ultra-vs-v3-<time>`), so delete those folders too when you're done.

## Why the folder is shaped this way

FluidAudio's `AsrModels.load(from:)` always reads `<parent>/parakeet-tdt-0.6b-v3`,
so Ultra lives at `parakeet-ultra/parakeet-tdt-0.6b-v3`. When a model fails to
load, FluidAudio deletes the folder and downloads stock v3 into it. The
`transcripted-model.json` marker is written last and deleted along with the
folder, so the app and the comparison script refuse to call anything without
it Ultra. That way stock v3 never gets passed off as Ultra.

## License and credit

Parakeet Ultra by Moondream (M87 Labs), CC-BY-4.0, based on NVIDIA's
parakeet-tdt-0.6b-v3 (CC-BY-4.0). The install writes `ATTRIBUTION.txt` next to
the model describing these changes: weight names converted, Core ML export,
8-bit encoder palettization.
