# SpeakerEvalHarness

## What this package owns

`Tools/SpeakerEvalHarness/` is a standalone Swift package for headless speaker-naming evaluation against the AMI Meeting Corpus. It dumps app diarizer segments and WeSpeaker embeddings, then replays threshold sweeps through `TranscriptedCore` clustering and cross-meeting speaker matching.

It also hosts the YODAS3 speaker lab (`YODAS_LAB_PLAN.md`, `YODAS_LAB_RESULTS.md`): simulated meetings with an answer key, run through the real meeting pipeline and naming sheet headless.

AMI and YODAS3 audio, RTTMs, dumps, simulated meetings, and eval reports are local-only and gitignored (`data/eval/`). Do not commit corpus data or raw eval artifacts.

## Key files

- `Package.swift` wires the harness to root `TranscriptedCore` and the repo-level native dependency bundle.
- `Sources/speaker-eval-harness/main.swift` owns the `dump` and `replay` commands and dispatches `autoeval` / `autoeval-self-test` / `meeting-series` / `dump-e2e` / `dump-set`.
- `Sources/speaker-eval-harness/MeetingLab.swift` — `meeting-series`: runs each simulated meeting through a real `TranscriptionTaskManager` (real `DiarizationService`, Parakeet, `SpeakerDatabase`) over throwaway paths with a stub stats store, answers the naming sheet from the answer key the way `SpeakerNamingSheet` builds updates, and writes `lab_result.json`. `--speaker-hint` passes calendar or oracle speaker-count bounds through `DiarizationService.labSpeakerBounds`.
- `Sources/speaker-eval-harness/E2EDump.swift` — `dump-e2e` (NVIDIA Sortformer / LS-EEND from our FluidAudio build) and `dump-set` (raw production diarizer under a `TRANSCRIPTED_LAB_KNOBS_FILE`, models loaded once per set).
- `Sources/speaker-eval-harness/AutoResearch.swift` — the `autoeval` command: replays frozen fingerprint caches (verified against a sha256 manifest) through candidate configs per split and condition slice, and writes a JSON report.
- `Sources/speaker-eval-harness/AutoResearchModels.swift` — fingerprint-cache input types, train/dev/holdout splits, condition-slice guardrail buckets, and `AutoResearchConfig`.
- `Sources/speaker-eval-harness/AutoResearchSelfTests.swift` — `autoeval-self-test`: evaluator parity and integration fixtures that fail closed when the baseline simulation drifts from production policy.
- `README.md` describes setup, commands, and corpus requirements.
- `BASELINE_REPORT.md` records the current measured baseline and tuning notes; `SCALEUP_REPORT.md`, `SEGMENTATION_FREQUENCY_REPORT.md`, and `AB_DOT_VS_CLOUD.md` are point-in-time study write-ups (check each one's provenance notes before trusting its numbers), and `contamination_drift_sim.py` simulates EMA write-back drift.
- `../../scripts/download_ami.sh`, `../../scripts/run_speaker_eval.sh`, `../../scripts/score_speaker_eval.py`, and `../../scripts/aggregate_sweep.py` drive the end-to-end AMI sweep. `../../scripts/run_speaker_autoresearch.py` (with `speaker_autoresearch_contract.py`, `speaker_autoresearch_runtime.py`, and `test_speaker_autoresearch.py`) drives the `autoeval` auto-research loop.
- `../../scripts/speaker_lab/` — the YODAS3 lab: `download_yodas.sh`, `voicebank.py` (embed/select/verify single-voice identities with two independent voice models), `meeting_sim.py` (families A–F plus hard companies), `run_set.sh`, `score.py`, and `naming_replay.py`.

## Verification

Mirrors the SpeakerEvalHarness rule in `.agents/test-matrix.yml` (that file wins if they drift; `bash scripts/dev/agent-preflight.sh` prints the exact set):

- `scripts/dev/agent-preflight.sh`
- `bash -n scripts/speaker_lab/download_yodas.sh`
- `bash -n scripts/speaker_lab/run_set.sh`
- `python3 -m py_compile scripts/speaker_lab/voicebank.py scripts/speaker_lab/meeting_sim.py scripts/speaker_lab/score.py scripts/speaker_lab/naming_replay.py`
- `bash -n scripts/download_ami.sh`
- `bash -n scripts/run_speaker_eval.sh`
- `python3 -m py_compile scripts/score_speaker_eval.py`
- `python3 -m py_compile scripts/aggregate_sweep.py`
- `python3 -m py_compile scripts/run_speaker_autoresearch.py`
- `python3 -m py_compile scripts/speaker_autoresearch_contract.py`
- `python3 -m py_compile scripts/speaker_autoresearch_runtime.py`
- `python3 -m py_compile scripts/test_speaker_autoresearch.py`
- `python3 scripts/test_speaker_autoresearch.py`
- `bash build-deps.sh --force`
- `swift build --package-path Tools/SpeakerEvalHarness`
- `Tools/SpeakerEvalHarness/.build/debug/speaker-eval-harness autoeval-self-test`
