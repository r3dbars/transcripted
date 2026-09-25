# SpeakerEvalHarness

## What this package owns

`Tools/SpeakerEvalHarness/` is a standalone Swift package for headless speaker-naming evaluation against labeled meeting audio (AMI and friends) and, in the speaker lab's own-calls mode, the user's saved meetings. It dumps the app's diarizer segments and speaker embeddings (per variant: diarizer backend pyannote|nemotron × embedder WeSpeaker|ERes2Net), then replays them through `TranscriptedCore` clustering and cross-meeting speaker matching.

AMI audio, RTTMs, dumps, eval reports, and speaker-lab runs (`data/`, `reports/speaker-lab/`) are local-only and gitignored. Do not commit corpus data, own-call dumps, or raw eval artifacts.

## Key files

- `Package.swift` wires the harness to root `TranscriptedCore` and the repo-level native dependency bundle.
- `Sources/speaker-eval-harness/main.swift` owns the wire models (`RawDump`, `ReplayResult`, …), shared helpers, and the command entry; it dispatches `autoeval` / `autoeval-self-test`.
- `Sources/speaker-eval-harness/Dump.swift` owns `dump` (`--backend`, `--embedder`, `--eres2net-model`).
- `Sources/speaker-eval-harness/Replay.swift` owns `replay` (match / same-voice / thresholds / dedup / write-path and fingerprint-update knobs).
- `Sources/speaker-eval-harness/EmbeddingParity.swift` owns `embedding-parity` (pyannote's offline WeSpeaker vectors vs Core's `FluidWeSpeakerSegmentEmbedder` on the same segments; decides whether Nemotron voiceprints could share `speakers.sqlite`). Its `ParityVerdict` constants are mirrored as `PARITY_*` in `scripts/score_speaker_lab.py`; change both together.
- `Sources/speaker-eval-harness/AutoResearch.swift` — the `autoeval` command: replays frozen fingerprint caches (verified against a sha256 manifest) through candidate configs per split and condition slice, and writes a JSON report.
- `Sources/speaker-eval-harness/AutoResearchModels.swift` — fingerprint-cache input types, train/dev/holdout splits, condition-slice guardrail buckets, and `AutoResearchConfig`.
- `Sources/speaker-eval-harness/AutoResearchSelfTests.swift` — `autoeval-self-test`: evaluator parity and integration fixtures that fail closed when the baseline simulation drifts from production policy.
- `README.md` describes setup, commands, corpus requirements, the speaker lab, and the `scores.json` schema.
- `BASELINE_REPORT.md` records the current measured baseline and tuning notes; `SCALEUP_REPORT.md`, `SEGMENTATION_FREQUENCY_REPORT.md`, and `AB_DOT_VS_CLOUD.md` are point-in-time study write-ups (check each one's provenance notes before trusting its numbers), and `contamination_drift_sim.py` simulates EMA write-back drift.
- `../../scripts/download_ami.sh`, `../../scripts/run_speaker_eval.sh`, `../../scripts/score_speaker_eval.py`, and `../../scripts/aggregate_sweep.py` drive the end-to-end AMI sweep. `../../scripts/run_speaker_autoresearch.py` (with `speaker_autoresearch_contract.py`, `speaker_autoresearch_runtime.py`, and `test_speaker_autoresearch.py`) drives the `autoeval` auto-research loop.
- `../../scripts/run_speaker_lab.sh` + `../../scripts/score_speaker_lab.py` drive the speaker lab (diarizer / fingerprint bake-off, `--single` optimizer trials, `--own-calls`); `../../scripts/speaker_eval_common.py` holds the scoring math both scorers share.

## Speaker lab in one paragraph

`bash scripts/run_speaker_lab.sh` dumps every meeting once per variant into `data/eval/<corpus>/dumps/<variant>/` (reused only when the dump's recorded backend/embedder/preset match), replays each variant over a knob grid, and scores raw vs pipeline DER, speaker-count error, and returning-speaker recognition (recognized / wrong person / asked again / undetected, plus new people false-matched) into `reports/speaker-lab/<stamp>/{REPORT.md,scores.json}`. The last stdout line is the `scores.json` path; exit is non-zero on any failure. `--own-calls <meetings folder>` runs the same variants on saved call tracks (read in place) and adds `timeline.html`. Adding a backend or embedder: see README "Add a new diarizer or embedder".

## Rules

- The harness must exercise production code paths (`DiarizationService`, `EmbeddingClusterer`, `SpeakerDatabase`, `Transcription.matchAgainstProfiles`, `planCrossClusterLinks`), not re-implementations. The only mirrored policy is `WriteBackPolicy`, which delegates to `SpeakerWritePathPolicy.voiceprintBlendAlpha` at default knob values.
- Replay defaults must keep reproducing the pre-lab harness for WeSpeaker dumps; new dump/replay JSON fields stay optional or additive.
- `dump` never falls back silently to another model: a cached dump must mean what its variant says.
- Own-call outputs carry no audio, no transcript text, and `scores.json` carries meeting ids only.

## Verification

Mirrors the SpeakerEvalHarness rule in `.agents/test-matrix.yml` (that file wins if they drift; `bash scripts/dev/agent-preflight.sh` prints the exact set):

- `scripts/dev/agent-preflight.sh`
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
- `bash -n scripts/run_speaker_lab.sh`
- `python3 -m py_compile scripts/speaker_eval_common.py scripts/score_speaker_lab.py scripts/test_score_speaker_lab.py`
- `python3 scripts/test_score_speaker_lab.py`
