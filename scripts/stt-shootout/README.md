# STT shootout

How much faster, and how accurate, is each on-device speech-to-text model than
the Parakeet V3 model Transcripted ships? One command on an Apple Silicon Mac
answers it on an hour of real speech.

```bash
bash scripts/stt-shootout/run.sh --minutes 3   # quick check: every model loads and runs, weights download
bash scripts/stt-shootout/run.sh               # the real test: the whole hour, every model
```

Before the full run: plug the Mac in, and quit Transcripted if you're not
recording (it shares the GPU and Neural Engine with the models; the report
records both). It needs about 20 GB free and stops downloading models below
that, so recordings always keep room.

The report lands in `~/stt-shootout/runs/full/report.md` (plus `report.json`,
`report.csv`, and each model's transcript under `transcripts/`). Re-running
skips models that already have a result; `--rerun` redoes them.

## What it measures

| Column | Meaning |
|---|---|
| Whole test took | Wall time to transcribe the whole file, model already loaded |
| Speed (× real time) | Audio length ÷ that time. 60× = an hour in one minute |
| vs Parakeet V3 | Speed relative to the app's current model |
| Latency (10 s clip) | A 10-second dictation, model loaded, median of 3 warm runs |
| First-use latency | The first run right after loading (Core ML and MLX compile on first use) |
| Load | Model load time (for the app CLI: load plus audio decode) |
| Peak memory | Peak physical footprint of the model's process (Activity Monitor's number, MLX GPU memory included). Core ML rows are a lower bound (Neural Engine memory likely isn't counted) and Apple Speech's model runs in a system process, so it shows n/a |
| WER | Word error rate against the video's human-made captions, after Whisper's English text normalizer |

Captions are lightly cleaned up by the people who write them, so every model
has the same WER floor. Compare models to each other, not to zero.

A row marked ⚠ produced far more or far fewer words than the answer key (or a
WER over 50%). That's a broken model or adapter, not a slightly worse one, so
it's left out of the pick. A row marked ‡ ran while Transcripted was open or
the Mac was on battery (checked right before and after that model).

## Test audio

By default: the first of these MIT OpenCourseWare lectures (Creative Commons
BY-NC-SA) that still has human-made English captions on YouTube:

1. MIT 6.006 Introduction to Algorithms, Fall 2011, Lecture 1 — https://www.youtube.com/watch?v=HtSuA80QTyo
2. MIT 6.006, Spring 2020, Lecture 1 — https://www.youtube.com/watch?v=ZA-tUyM_y7s
3. MIT 6.034 Artificial Intelligence, Fall 2010, Lecture 1 — https://www.youtube.com/watch?v=TjZBTDzGeGg

Auto-generated captions never count. Use your own with `--url <youtube url>`
(needs human captions), or a local file with `--audio file.m4a --reference
transcript.txt` (or `.vtt`).

## Models

`bash scripts/stt-shootout/run.sh --list-engines` prints the current list.
Pick some with `--engines a,b,c` or drop some with `--skip a,b`.

| Name | Model | Runtime |
|---|---|---|
| `parakeet-v3` | Parakeet TDT 0.6B v3 (the baseline) | the installed app's `transcripted-cli` (FluidAudio, Core ML) |
| `parakeet-ultra` | Parakeet Ultra | same CLI, Ultra model from PR #1783 (skipped until installed) |
| `apple-speech` | Apple SpeechTranscriber | macOS 26 SpeechAnalyzer, `engines/apple_speech.swift` |
| `whisperkit-turbo` | Whisper large-v3-turbo | WhisperKit, the app's own Whisper engine and revision |
| `whisper-turbo` | Whisper large-v3-turbo | mlx-whisper (GPU) |
| `distil-whisper` | Distil-Whisper large-v3 | mlx-whisper (GPU), English only |
| `parakeet-v3-mlx` | Parakeet TDT 0.6B v3 | parakeet-mlx (GPU) |
| `parakeet-v2-mlx` | Parakeet TDT 0.6B v2 | parakeet-mlx (GPU), English only |
| `canary-1b-v2` | NVIDIA Canary 1B v2 | onnx-asr + Silero VAD (CPU) |
| `canary-180m-flash` | NVIDIA Canary 180M Flash | onnx-asr + Silero VAD (CPU) |
| `moonshine-base` | Moonshine base | moonshine-voice, English only |
| `moonshine-medium` | Moonshine medium streaming | moonshine-voice, English only |
| `whisper-cpp-turbo` | Whisper large-v3-turbo | whisper.cpp with Metal (pywhispercpp) |
| `granite-speech` | IBM Granite Speech 4.0 1B | mlx-audio (GPU), 30 s pieces |
| `nemotron-streaming` | NVIDIA Nemotron streaming 0.6B | mlx-audio (GPU), English only |

`parakeet-v3` and `parakeet-ultra` never touch the app's own model files: the
shootout makes an APFS clone (no extra disk) under `~/stt-shootout/models/app-cli/`
and runs on that, because FluidAudio deletes and re-downloads a model folder it
fails to load. If the Ultra copy gets swapped for stock V3 that way, the Ultra
row fails instead of reporting V3 numbers.

Each model runs in its own process and its own Python env under
`~/stt-shootout/envs/`, so one model's crash or memory can't touch another's
numbers. A model that fails shows up under "Didn't run" with the reason; the
rest still run. Logs are in `runs/<run>/logs/<model>.log`.

## Adding a model

Python: add a class with `load()` and `transcribe(audio) -> str` to
`engines/py_engines.py`, register it in that file's `ENGINES`, and add an
`Engine(...)` entry with its pip packages to `ENGINES` in `shootout.py`.
Anything else: write a runner that takes `--audio --clip --runs --out` and
writes the same result JSON (see `engines/apple_speech.swift`).

## Where things go, and cleaning up

Everything lands in `~/stt-shootout`: the video, Python envs, uv's cache and
Python, and every model's weights (Hugging Face models via `HF_HOME`;
WhisperKit, whisper.cpp, Moonshine and the onnx-asr models in `models/`). Expect 15-30 GB. The one
exception is Apple's own speech files, which macOS manages. To remove it all:

```bash
rm -rf ~/stt-shootout ~/stt-shootout-src && git -C ~/transcripted worktree prune
```

Pip packages are pinned in `shootout.py`, and `report.json` records every
engine's installed packages, each Hugging Face model's snapshot hash, the
machine, and whether Transcripted was running or the Mac was on battery.

## Checks that run anywhere

```bash
python3 scripts/stt-shootout/shootout.py --self-test
```

Local only: nothing leaves the Mac except the video download and each model's
first-time weight download.

## Hill-climb lab bench

`hillclimb_bench.py` lets the hill-climb lab (`scripts/hillclimb/`) use the
shootout as a bench: knob `stt.engine` picks the model, each suite item
(`{"id", "audio", "truth"}`) is one recording, and it returns full time,
speed, clip latency, load, peak memory and WER per item. See its docstring.
