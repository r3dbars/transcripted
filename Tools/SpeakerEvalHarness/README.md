# SpeakerEvalHarness

Headless, re-runnable eval for Transcripted's speaker-naming pipeline against **real
labeled audio** (AMI Meeting Corpus). Measures the two thresholds the team tunes by feel:

- **within-meeting consolidation** — `EmbeddingClusterer.postProcess(pairwiseMergeThreshold:)`
  (the same-voice merge; 0.88 on the `feat/embedding-clusterer-same-voice-consolidation` branch).
- **cross-meeting match** — `SpeakerDatabase.matchSpeaker(threshold:)` (0.6).

It uses the **app's own** diarizer + 256-dim WeSpeaker embeddings via
`TranscriptedCore.DiarizationService`, so thresholds transfer to production.

See **[BASELINE_REPORT.md](BASELINE_REPORT.md)** for measured results + recommendations.

## How it works

Two stages, split so the expensive diarization runs once and the threshold sweep is cheap:

```
WAV ──dump──▶ raw segments + 256-dim embeddings (JSON, cached)
                  │
            replay (per threshold combo, in session order)
                  │  EmbeddingClusterer.postProcess  ──▶ within-meeting consolidation
                  │  SpeakerDatabase match/learn/merge ──▶ cross-meeting re-ID (DB accumulates across sessions, like real use)
                  ▼
            per-segment hypothesis (DB-profile labels)
                  │
            scripts/score_speaker_eval.py vs AMI RTTM
                  ▼
   DER (pyannote.metrics) · fragmentation · false-merge · cross-meeting re-ID curve
```

The replay feeds sessions **in order** so profiles accumulate across meetings exactly as in
real usage. The DB starts empty each replay (a fresh user).

## Commands

```bash
# diarize one WAV, dump segments+embeddings (expensive; cache once)
speaker-eval-harness dump --audio path.wav --meeting NAME --out raw.json

# replay a series in order through clusterer + DB, emit hypothesis assignments (cheap; sweepable)
speaker-eval-harness replay --inputs a.json,b.json,c.json,d.json \
    --consolidation none|0.88 --match 0.6 --out result.json
```

## Run the whole thing

```bash
bash build-deps.sh            # one-time: native deps -> deps-libs/, deps-modules/, deps-frameworks/
bash scripts/download_ami.sh     # AMI ES2002 a–d audio + RTTMs (~230 MB, gitignored)
scripts/run_speaker_eval.sh   # build + dump + sweep + score -> data/eval/reports/SWEEP.md
```

Override the grids via env: `SERIES`, `CONSOLIDATION`, `MATCH`, `COLLAR`.

## Requirements

- macOS 14+ on Apple Silicon (CoreML diarizer models, downloaded once from HuggingFace).
- Prebuilt deps from `build-deps.sh` (`deps-libs/libExternalDeps.a`, `deps-modules/`,
  `deps-frameworks/`). The harness `Package.swift` resolves them relative to the repo root.
- Python: `pyannote.metrics` (`pip install pyannote.metrics`).

## Files

| Path | Purpose |
|---|---|
| `Sources/speaker-eval-harness/main.swift` | `dump` + `replay` commands |
| `Package.swift` | depends on root `TranscriptedCore`; mirrors deps link flags |
| `BASELINE_REPORT.md` | measured baseline + threshold recommendations |
| `../../scripts/run_speaker_eval.sh` | end-to-end driver |
| `../../scripts/score_speaker_eval.py` | DER + fragmentation + false-merge + re-ID scorer |
| `../../scripts/aggregate_sweep.py` | sweep table + closest-to-ideal picker |
| `../../scripts/download_ami.sh` | fetch the AMI subset |

## Caveats

- **Domain gap.** AMI is in-room headset audio; it stresses the *diarizer*, and on this
  subset the diarizer under-segments (3 clusters for 4 speakers), so cross-person merges and
  the high DER `confusion` term are upstream of both thresholds. The 0.88 consolidation knob
  is inert here (same-voice cluster similarity tops out ~0.72, far below 0.88). To calibrate
  0.88 you need audio that over-segments clean single voices — see BASELINE_REPORT §6.
- AMI is research-use licensed; audio/RTTMs/dumps are gitignored, never committed.
