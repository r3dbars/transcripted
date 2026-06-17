# SpeakerEvalHarness

## What this package owns

`Tools/SpeakerEvalHarness/` is a standalone Swift package for headless speaker-naming evaluation against the AMI Meeting Corpus. It dumps app diarizer segments and WeSpeaker embeddings, then replays threshold sweeps through `TranscriptedCore` clustering and cross-meeting speaker matching.

AMI audio, RTTMs, dumps, and eval reports are local-only and gitignored. Do not commit corpus data or raw eval artifacts.

## Key files

- `Package.swift` wires the harness to root `TranscriptedCore` and the repo-level native dependency bundle.
- `Sources/speaker-eval-harness/main.swift` owns the `dump` and `replay` commands.
- `README.md` describes setup, commands, and corpus requirements.
- `BASELINE_REPORT.md` records the current measured baseline and tuning notes.
- `../../scripts/download_ami.sh`, `../../scripts/run_speaker_eval.sh`, `../../scripts/score_speaker_eval.py`, and `../../scripts/aggregate_sweep.py` drive the end-to-end AMI sweep.

## Verification

- `bash build-deps.sh --force`
- `swift build --package-path Tools/SpeakerEvalHarness`
- `bash -n scripts/download_ami.sh`
- `bash -n scripts/run_speaker_eval.sh`
- `python3 -m py_compile scripts/score_speaker_eval.py`
- `python3 -m py_compile scripts/aggregate_sweep.py`
