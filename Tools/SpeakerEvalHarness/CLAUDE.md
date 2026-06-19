# SpeakerEvalHarness

## What this package owns

`Tools/SpeakerEvalHarness/` is a standalone Swift package for headless speaker-naming evaluation against the AMI Meeting Corpus. It dumps app diarizer segments and WeSpeaker embeddings, then replays threshold sweeps through `TranscriptedCore` clustering and cross-meeting speaker matching.

AMI audio, RTTMs, dumps, and eval reports are local-only and gitignored. Do not commit corpus data or raw eval artifacts.

## Key files

- `Package.swift` wires the harness to root `TranscriptedCore` and the repo-level native dependency bundle.
- `Sources/speaker-eval-harness/main.swift` owns the `dump` and `replay` commands.
- `Sources/speaker-eval-harness/DumpBatch.swift` — `dump-batch` (one model load, many WAVs).
- `Sources/speaker-eval-harness/Fingerprints.swift` — `ladder-fingerprints` (real `EmbeddingClusterer.postProcess` + `Transcription.computeMeanEmbedding`; RTTM max-overlap attribution → policy-independent per-(speaker,meeting) fingerprint cache).
- `Sources/speaker-eval-harness/LadderSweep.swift` — `ladder-sweep` (multi-meeting AUTO/SUGGEST/UNKNOWN promotion ladder over the swept policy grid; reuses real cosine + ported EMA blend; CSV checkpoints).
- `Sources/speaker-eval-harness/LadderParity.swift` — `ladder-parity` (asserts the simulator's EMA/matcher == real `SpeakerDatabase`/`Transcription` code; CI gate).
- `README.md` describes setup, commands, and corpus requirements.
- `BASELINE_REPORT.md` records the current measured baseline and tuning notes.
- `LADDER_SWEEP_REPORT.md` + `ladder_results/` — the multi-meeting confidence-ladder sweep findings (prompts vs false-positives), Pareto frontier, and per-domain recommended operating points.
- `../../scripts/download_ami.sh`, `../../scripts/run_speaker_eval.sh`, `../../scripts/score_speaker_eval.py`, and `../../scripts/aggregate_sweep.py` drive the end-to-end AMI sweep.
- `../../scripts/ladder/` — `run_dumps.sh` (dump-only driver), `build_voxceleb_singles.py` (clean-domain substrate from the local HF cache), `analyze_ladder.py` (Pareto frontier + recommendations + plot).

NOTE: making `Transcription.{matchAgainstProfiles,computeMeanEmbedding,cosineSimilarityStatic}` and `SnapshotMatchResult` `public` is a visibility-only change so the harness reuses the real matcher; it changes no production behavior (verified by `ladder-parity`).

## Verification

- `bash build-deps.sh --force`
- `swift build --package-path Tools/SpeakerEvalHarness`
- `bash -n scripts/download_ami.sh`
- `bash -n scripts/run_speaker_eval.sh`
- `python3 -m py_compile scripts/score_speaker_eval.py`
- `python3 -m py_compile scripts/aggregate_sweep.py`
