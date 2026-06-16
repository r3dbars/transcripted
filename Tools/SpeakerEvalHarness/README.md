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
bash build-deps.sh                 # one-time: native deps -> deps-libs/, deps-modules/, deps-frameworks/
bash scripts/download_ami.sh       # AMI ES2002 a–d audio + RTTMs (~230 MB, gitignored)
scripts/run_speaker_eval.sh        # build + dump + sweep + score -> data/eval/ami/reports/SWEEP.md
```

One driver, any corpus. `CORPUS` selects the dataset; `dump -> sweep -> score` is shared.
Outputs land under `data/eval/<CORPUS>/{dumps,results,reports}/` (all gitignored).

## Corpus mix (chosen, compute-capped — diverse identities, not all-of-everything)

The point is a trustworthy near-zero-false-positive number from **diverse identities**,
without burning multi-day compute. Each corpus has its own downloader; all data is
gitignored under `data/`. Pick the tier that matches the compute you want to spend.

| Corpus | What it tests | Downloader | Source / license | Footprint | Diarize compute¹ |
|---|---|---|---|---|---|
| **AMI** (default `scale`) | cross-meeting re-ID + false-merge, real recurring identities | `scripts/download_ami.sh scale` | AMI Corpus, research-use; RTTMs from pyannote/AMI-diarization-setup | ~1.8 GB (32 mtgs) | ~3 min |
| **AMI full** | all scenario + non-scenario, ~100 h | `scripts/download_ami.sh full` | same | ~9–10 GB (~170 mtgs) | ~1–2 h |
| **ICSI** | meeting corpus, heavily recurring lab speakers | `scripts/download_icsi.sh` | ICSI Corpus, research-use; RTTMs from HF `diarizers-community/icsi` (gated) | ~0.5–10 GB | ~10–60 min |
| **VoxConverse** | in-the-wild YouTube, overlap, unknown counts | `scripts/download_voxconverse.sh` | VoxConverse, CC-BY 4.0; RTTMs from joonson/voxconverse | ~4 GB (dev+test) | ~30–90 min |
| **VoxCeleb** (sample) | cross-recording re-ID / false-positive (matcher-isolated) | `scripts/download_voxceleb_sample.sh` | VoxCeleb1, CC-BY-SA 4.0 (public `s3prl/mini_voxceleb1` default; larger mirrors gated) | bounded by cap (~few GB) | ~20–60 min |

¹ Apple-Silicon diarization, ~100–200× realtime. **Excludes** the one-time CoreML model
download and the per-corpus dataset download (which can dominate — see footprints).

### Run each corpus / tier (one-liners)

```bash
# --- AMI: landed + scale-up validated (this is the always-safe tier) ---
bash scripts/download_ami.sh scale      &&  CORPUS=ami        scripts/run_speaker_eval.sh   # ~32 mtgs, hours-bounded

# --- gated heavy tiers: WIRED, not auto-run. Gate the compute yourself. ---
bash scripts/download_ami.sh full        &&  CORPUS=ami        scripts/run_speaker_eval.sh   # full ~100 h AMI dump (HOURS)
bash scripts/download_voxconverse.sh     &&  CORPUS=voxconverse scripts/run_speaker_eval.sh  # ~4 GB, in-the-wild
bash scripts/download_icsi.sh            &&  CORPUS=icsi       scripts/run_speaker_eval.sh   # needs HF auth for RTTMs
bash scripts/download_voxceleb_sample.sh &&  CORPUS=voxceleb   scripts/run_speaker_eval.sh   # HARD-CAPPED sample + synthetic sessions
```

### Env knobs

| Knob | Default | Meaning |
|---|---|---|
| `CORPUS` | `ami` | `ami` \| `icsi` \| `voxconverse` \| `voxceleb` — selects audio/rttm dirs |
| `SERIES` | all RTTMs present | subset of meeting ids to replay (space-separated) |
| `AMI_SET` | `es2002` | `es2002` \| `scale` (32 mtgs) \| `full` (~170) — `download_ami.sh` preset |
| `ICSI_SET` | `sample` | `sample` (6) \| `full` (75) — `download_icsi.sh` preset |
| `VOXCONVERSE_SPLITS` | `dev test` | which VoxConverse splits to fetch |
| `VOXCELEB_IDENTITY_CAP` | `300` | **HARD CAP** on sampled identities (max 1211; never the full corpus) |
| `VOXCELEB_CLIPS_PER_ID` | `10` | clips kept per sampled identity |
| `VOXCELEB_DATASET` | `s3prl/mini_voxceleb1` | HF mirror (public default; swap for a larger/gated one) |
| `VOXCELEB_MODE` | `singles` | `singles` (1 clip/meeting → isolates the matcher) \| `sessions` (stitched multi-speaker → also stresses diarizer) |
| `CONSOLIDATION` | `none 0.82 0.85 0.88 0.91` | within-meeting same-voice merge grid |
| `MATCH` | `0.50 0.55 0.60 0.65 0.70` | cross-meeting DB match grid |
| `COLLAR` | `0.25` | DER forgiveness collar (AMI convention) |

**Gating note:** the full AMI dump, VoxConverse, ICSI, and the VoxCeleb sample are wired
but intentionally **not** auto-run — they are hours-to-days of download + compute. Run the
one-liner for the tier you want, on purpose. VoxCeleb is **always** sample-only and
hard-capped; there is no "download all of VoxCeleb" path.

## Requirements

- macOS 14+ on Apple Silicon (CoreML diarizer models, downloaded once from HuggingFace).
- Prebuilt deps from `build-deps.sh` (`deps-libs/libExternalDeps.a`, `deps-modules/`,
  `deps-frameworks/`). The harness `Package.swift` resolves them relative to the repo root.
- Python: `pyannote.metrics` (`pip install pyannote.metrics`) for scoring. The VoxCeleb
  sampler additionally needs `datasets` + `ffmpeg`; ICSI RTTM materialization needs
  `datasets` (`pip install datasets`).

## Files

| Path | Purpose |
|---|---|
| `Sources/speaker-eval-harness/main.swift` | `dump` + `replay` commands |
| `Package.swift` | depends on root `TranscriptedCore`; mirrors deps link flags |
| `BASELINE_REPORT.md` | measured baseline (AMI ES2002) + threshold recommendations |
| `SCALEUP_REPORT.md` | AMI scale-up (~32 mtgs / dozens of identities) results at scale |
| `../../scripts/run_speaker_eval.sh` | end-to-end driver, keyed by `CORPUS` |
| `../../scripts/score_speaker_eval.py` | DER + fragmentation + false-merge + re-ID scorer (corpus-agnostic) |
| `../../scripts/aggregate_sweep.py` | sweep table + closest-to-ideal picker |
| `../../scripts/download_ami.sh` | AMI audio + RTTMs (`es2002` \| `scale` \| `full`) |
| `../../scripts/download_icsi.sh` | ICSI audio (Edinburgh) + RTTMs (HF, gated) |
| `../../scripts/download_voxconverse.sh` | VoxConverse dev+test audio + RTTMs |
| `../../scripts/download_voxceleb_sample.sh` | VoxCeleb SAMPLE-only (hard-capped) + synthetic sessions |
| `../../scripts/voxceleb_sample.py` | streaming VoxCeleb sampler with hard identity cap |
| `../../scripts/build_voxceleb_sessions.py` | stitch sampled identities into multi-speaker sessions + RTTM |
| `../../scripts/icsi_rttm_from_hf.py` | materialize loose ICSI RTTMs from the HF dataset |

## Caveats

- **Domain gap.** AMI is in-room headset audio; it stresses the *diarizer*, and on this
  subset the diarizer under-segments (3 clusters for 4 speakers), so cross-person merges and
  the high DER `confusion` term are upstream of both thresholds. The 0.88 consolidation knob
  is inert here (same-voice cluster similarity tops out ~0.72, far below 0.88). To calibrate
  0.88 you need audio that over-segments clean single voices — see BASELINE_REPORT §6.
- AMI is research-use licensed; audio/RTTMs/dumps are gitignored, never committed.
