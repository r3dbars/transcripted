# SpeakerEvalHarness

Headless, re-runnable eval for Transcripted's speaker-naming pipeline against **real
labeled audio** (AMI Meeting Corpus). Measures the two thresholds the team tunes by feel:

- **within-meeting consolidation** — `EmbeddingClusterer.postProcess(pairwiseMergeThreshold:)`
  (the same-voice merge; 0.88 on the `feat/embedding-clusterer-same-voice-consolidation` branch).
- **cross-meeting match** — `SpeakerDatabase.matchSpeaker(threshold:)` (0.6).

It uses the **app's own** diarizer + embeddings via `TranscriptedCore.DiarizationService`
(pyannote or Nemotron; WeSpeaker 256-d or ERes2Net 192-d), so thresholds transfer to
production. The **speaker lab** below puts those combinations side by side.

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
   DER (pyannote.metrics conventions) · fragmentation · false-merge · cross-meeting re-ID curve
```

The replay feeds sessions **in order** so profiles accumulate across meetings exactly as in
real usage. The DB starts empty each replay (a fresh user).

## Commands

```bash
# diarize one WAV, dump segments+embeddings (expensive; cache once per variant)
speaker-eval-harness dump --audio path.wav --meeting NAME --out raw.json \
    [--backend pyannote|nemotron] [--embedder native|eres2net] [--eres2net-model Model.mlmodelc]

# replay a series in order through clusterer + DB, emit hypothesis assignments (cheap; sweepable)
speaker-eval-harness replay --inputs a.json,b.json,c.json,d.json \
    --consolidation none|0.88 --match 0.6 --out result.json

# A/B the write-path fixes (#6 write-time contamination gate + #8 cross-cluster link/merge decouple)
speaker-eval-harness replay --inputs ... --write-path-fixes off|on --out result.json

# production-shaped replay: the app's adaptive match floor, per-model thresholds, fingerprint-update knobs
speaker-eval-harness replay --inputs ... --match adaptive --thresholds auto|weSpeaker|eRes2Net \
    --same-voice profile|none|0.88 --dedup match|0.6 --write-path-fixes on \
    --blend-confident 0.15 --blend-cautious 0.05 --writeback-confident-sim 0.80 \
    --writeback-cautious-sim 0.72 --writeback-margin 0.12 --out result.json
```

Dumps record `backend`, `embedder`, `embeddingDimension`, `diarizeSeconds`, `audioSeconds`,
`initSeconds`, and `nemotronPreset` (all optional, so pre-lab dumps still load as pyannote +
WeSpeaker). `nemotronPreset` is the preset that actually ran, as Core resolves it
(`DiarizationService.resolvedNemotronPresetName()`, so `fast128` when the env var is unset;
older dumps say `default`, which the lab treats as `fast128`). `dump` never falls back
silently: if ERes2Net is requested and can't load, or `TRANSCRIPTED_NEMOTRON_PRESET` names a
preset Core wouldn't honor, it fails. `replay` refuses to mix embedding dimensions and, with `--thresholds auto`, uses the
ERes2Net threshold set for ERes2Net dumps. Its defaults (`--match 0.6 --same-voice profile
--dedup match --write-path-fixes off`) reproduce the pre-lab harness for WeSpeaker dumps.
Each replayed meeting also reports `rawDiarizerClusters`, `profilesAfterMeeting`, and
`clusterStatus` (per cluster: `matched` an existing profile or `new`).

`--write-path-fixes` (default `off`): `off` is the legacy write path (every match blends at the
full EMA rate; clusters matching the same profile collapse together). `on` applies the
`SpeakerWritePathPolicy` gates, mirroring `TranscriptionPipeline` (gated EMA blend + cross-cluster
spin-off of distinct voices). Replay the same dumps both ways to get a clean before/after.

## Speaker lab (diarizer + fingerprint bake-off)

One command runs our meeting speaker pipeline on the same calls with every diarizer /
fingerprint combo you name and puts them side by side. It answers two questions:

1. **Did it find the right speakers in each meeting?** DER, its parts, JER, and speaker-count
   error, scored twice: on the **raw** diarizer output and on the **pipeline** output (after
   `EmbeddingClusterer` consolidation and speaker-DB matching, i.e. what the app would save).
2. **Did it recognize people on their next call?** Every time a person shows up again, the
   lab checks where their voice landed:
   - **recognized**: on the profile that already held their voice, so no re-naming
   - **wrong person**: on someone else's profile (the worst outcome, a wrong name)
   - **asked again**: on a brand-new profile, so the user has to name them again
   - **undetected**: no speech attributed to them at all

   It also counts **new people false-matched**: a first-time speaker glued to a profile the
   app already knew. A profile "belongs" to whoever held most of its speech in earlier
   meetings. Appearances under `--min-appearance-sec` (default 5 s) are skipped.

A **variant** is diarizer backend × embedding model (× Nemotron preset):

| piece | options | where it plugs in |
|---|---|---|
| backend | `pyannote` (ships today: FluidAudio `OfflineDiarizerManager`), `nemotron` (NVIDIA Nemotron 3 Diarization) | `DiarizationService(backend:)` |
| embedder | `native` (both backends: FluidAudio WeSpeaker 256-d), `eres2net` (ERes2Net 192-d, re-embeds every segment) | `DiarizationService(segmentEmbedder:)` |
| preset | `fast128` (default), `fast32`, `offline`, `low` … | `TRANSCRIPTED_NEMOTRON_PRESET` at dump time |

Each variant gets its own dump cache (`data/eval/<corpus>/dumps/<variant>/`). A cached dump is
reused only if its recorded backend/embedder/preset match, so variants never mix.

### Run it on the public set

```bash
bash build-deps.sh --force                 # once
bash scripts/download_ami.sh lab           # 16 AMI series × 4 sessions (same 4 people per series), ~3.5 GB
bash scripts/run_speaker_lab.sh            # pyannote vs nemotron (+ eres2net variants if the model is staged)
# last line printed = reports/speaker-lab/<stamp>/scores.json; REPORT.md sits next to it
```

`download_ami.sh scale` (8 series) or `es2002` (1 series) work too; `SERIES="ES2002 IS1000"`
narrows a run (a bare series id expands to its downloaded sessions). The report has a
headline table per variant at its best setting, a settings table, a "what moved
recognition" breakdown per knob, and per-meeting rows. Raw per-appearance outcomes land in
`recognition-events.json`.

**Public sets where the same people recur** (what the recognition test needs): AMI scenario
series (ES/IS/TS, 4 sessions each, same 4 participants; speaker ids are global across the
corpus) and ICSI (lab members recur across many meetings; `CORPUS=icsi`). VoxConverse does
not recur speakers across files; the VoxCeleb `sessions` mode stitches recurring identities
synthetically.

### Run it on your own calls

```bash
bash scripts/run_speaker_lab.sh --own-calls "$HOME/Library/Application Support/Transcripted/captures/meetings"
# or a relocated capture library's meetings/ folder; --own-calls-limit 20 keeps the 20 most recent
```

It reads each saved meeting's call track in place (`meetings/audio/<stem>_audio/system_audio.*`,
or `recording.*` for system-only and imported meetings; the `microphone` track is you, so it
is skipped). Meetings replay oldest first. There's no ground truth, so it reports behavior:
speakers found (raw / pipeline), speech covered, clusters matched to a known profile vs new,
profiles at the end, and how much each variant disagrees with the first one (DER of B scored
against A). Open `timeline.html` in the run folder to eyeball every variant's speaker turns
stacked per call. Same color = same profile across calls, striped = a profile created in that
call. Audio is never copied. Dumps (with voice embeddings) stay in `data/eval/own-calls/`,
reports in `reports/speaker-lab/`, both gitignored. `scores.json` carries meeting ids only; no
paths, names, or transcript text anywhere.

### Knobs

Every knob is a flag with an env twin (flag wins). Grid knobs take a space-separated list and
the replay sweeps their cartesian product.

| flag / env | default | what it changes |
|---|---|---|
| `--variants` / `VARIANTS` | `pyannote:native nemotron:native` (+ `:eres2net` twins when the model exists) | `backend:embedder[:preset]` list |
| `--backend` `--embedder` `--preset` / `BACKEND` `EMBEDDER` `NEMOTRON_PRESET` | — | shorthand for one variant |
| `--eres2net-model` / `ERES2NET_MODEL` | FluidAudio Models cache | ERes2Net `Model.mlmodelc` path |
| `--match` / `MATCH` | WeSpeaker `adaptive 0.55 0.60 0.65 0.70`, ERes2Net `adaptive 0.45 0.50 0.55 0.60` | cross-call match floor; `adaptive` = the app's per-segment-count floor |
| `--same-voice` / `SAME_VOICE` | `profile` | same-voice consolidation; `profile` = the model's calibrated value |
| `--consolidation` / `CONSOLIDATION` | (none) | extra pairwise merge (the old sweep knob) |
| `--thresholds` / `THRESHOLDS` | auto | `weSpeaker` / `eRes2Net` threshold set; auto = from the dumps |
| `--write-path-fixes` / `WRITE_PATH_FIXES` | `on` | gated write-back + cross-cluster link decouple (what ships) |
| `--dedup` / `DEDUP` | `0.6` | `mergeDuplicates` threshold after each meeting (app default) |
| `--blend-confident` `--blend-cautious` | 0.15 / 0.05 | how far a matched voiceprint moves toward this meeting (EMA weight) |
| `--writeback-confident-sim` `--writeback-cautious-sim` `--writeback-margin` | 0.80 / 0.72 / 0.12 | similarity gates for those weights; below cautious or inside the margin, the voiceprint is frozen |
| `--corpus` `--series` `--collar` | `ami`, all downloaded, `0.25` | corpus + DER collar (pyannote convention: total width) |
| `--min-appearance-sec` `--wrong-penalty` | `5`, `2` | recognition scoring |
| `--single` / `SINGLE=1` | off | one variant, one setting, no sweep; unset knobs = production defaults |
| `--out-dir`, `--skip-build`, `--redump`, `ALLOW_PARTIAL_CORPUS=1` | | plumbing |

The fingerprint-update knobs mirror `SpeakerWritePathPolicy`. Setting both blend weights to 0
means a profile never learns after first sight. The cross-cluster link floor (0.78), the
exemplar policy (3 exemplars, 0.80 same-condition bar), and the ghost-merge floor are Core
constants the replay can't override yet.

### Driving it from an optimizer

`--single` runs one trial and the **last stdout line is always the absolute path of
`scores.json`** (progress goes to stderr). The exit status is non-zero on any failure (build,
missing corpus, dump, replay, or scoring), and nothing prompts. Example trial:

```bash
path=$(bash scripts/run_speaker_lab.sh --single --skip-build --backend nemotron --preset fast32 \
        --match 0.62 --blend-confident 0.1 --writeback-margin 0.08 | tail -1)
jq '.variants[0].best | {objective, r: .recognition.recognizedRate, der: .pipeline.meanDER}' "$path"
```

Dumps are cached, so after the first trial per variant each trial is just replay + scoring
(seconds).

### `scores.json` schema (`schemaVersion` 1)

```text
{
  schema: "transcripted.speaker-lab.scores", schemaVersion: 1,
  generatedAt: ISO-8601 UTC, gitRevision: short sha, gitDirty: bool, command: string,
  mode: "corpus" | "own-calls", corpus, single: bool,
  collar, minAppearanceSeconds, wrongPenalty,
  requestedKnobs: {variants, series, match, same_voice, consolidation, write_path_fixes,
                   thresholds, dedup, blend_confident, blend_cautious, writeback_confident_sim,
                   writeback_cautious_sim, writeback_margin}      // as passed (strings)
  meetings: [meeting id, ...]                                     // replay order
  variants: [ corpus-mode variant | own-calls variant ]
}

corpus-mode variant = {
  name, backend, embedder ("native" | "eres2net"), nemotronPreset | null, meetingsScored,
  speed: {audioSeconds, diarizeSeconds, xRealtime, meanInitSeconds},
  raw: {meanDER, meanMiss, meanFalseAlarm, meanConfusion, meanJER,
        meanSpeakerCountError, meanAbsSpeakerCountError, exactSpeakerCountRate,
        perMeeting: [{meeting, der, miss, falseAlarm, confusion, jer, refSpeakers, rawSpeakers,
                      countError, xRealtime}]},
  best: {tag, knobs, objective, pipeline, recognition, identity} | null,   // = the best setting
  settings: [{
    tag, replay (path relative to the run dir), objective,
    knobs: {match (float | "adaptive"), consolidation, sameVoice, thresholds, dedup,
            writePathFixes, blendConfident, blendCautious, writebackConfidentSim,
            writebackCautiousSim, writebackMargin},              // effective values the replay used
    pipeline: {meanDER, meanMiss, meanFalseAlarm, meanConfusion, meanJER,
               meanSpeakerCountError, meanAbsSpeakerCountError, exactSpeakerCountRate},
    recognition: {returningAppearances, recognized, wrongPerson, askedAgain, undetected,
                  recognizedRate, wrongPersonRate, askedAgainRate, undetectedRate,
                  firstAppearances, firstAppearanceFalseMatches, firstAppearanceFalseMatchRate,
                  byAppearance: {"1": {outcome: count}, "2": ...}, minAppearanceSeconds},
    identity: {trueSpeakers, profilesAtEnd, fragmentationMean, falseMergeProfiles, reidCurve},
    perMeeting: [{meeting, der, miss, falseAlarm, confusion, jer, refSpeakers, hypSpeakers,
                  countError, clustersMatched, clustersNew}]
  }]
}

own-calls variant = {
  name, backend, embedder, nemotronPreset, speed, knobs,
  summary: {meetingsScored, meanRawSpeakers, meanPipelineSpeakers, meanSpeechCoverage,
            clustersMatched, clustersNew, profilesAtEnd},
  perMeeting: [{meeting, status, audioSeconds, rawSpeakers, speechSeconds, speechCoverage,
                xRealtime, pipelineSpeakers, clustersMatched, clustersNew}],
  agreement: {baseline, meanDerVsBaseline, perMeeting: [...]}     // absent on the first variant
}
```

Rates are 0–1 (`null` when there's nothing to count). DER parts are fractions of reference
speech. `countError` = found − real (negative = people merged). **`objective`** =
`recognizedRate − wrongPenalty × (wrongPersonRate + firstAppearanceFalseMatchRate)`; the best
setting maximizes it, and ties go to lower pipeline DER. Treat any rise in wrong person, false
match, or `falseMergeProfiles` as a hard regression no matter what the objective does. New
fields may be added within a schema version. Renames or removals bump `schemaVersion`.

### Add a new diarizer or embedder

- **New diarizer backend**: add a case to Core's `DiarizationBackend` and handle it in
  `DiarizationService`. The harness takes any `DiarizationBackend.allCases` value, so the only
  lab change is allowing the name in `run_speaker_lab.sh`'s variant check.
- **New fingerprint model**: implement `SpeakerSegmentEmbedder` (with its own
  `SpeakerEmbeddingThresholds`), add an `--embedder` case in `Dump.swift` that constructs it
  from a path, add a `ThresholdProfile` case in `Replay.swift` (and to `inferred(from:)`), and
  allow the embedder name in the driver. Everything downstream (cache, replay, scoring,
  report, timeline) is keyed by the variant name.

## Automatic parameter research

The `autoeval` path replays frozen fingerprint caches chronologically through
the production matcher and an ASK / SUGGEST / AUTO interaction simulation. It
tests maturity evidence, similarity and margin gates, minimum speech quality,
match thresholds, write-back policy and weight, and exemplar retention. A
candidate is rejected if false automatic names, open-set errors, either
within-meeting or cross-meeting false merges, or profile contamination worsen.
Those gates apply overall, per corpus, and in fixed purity, speech-duration,
segment-count, and cluster-count buckets; each bucket also keeps the baseline
automatic-name coverage floor. Train/dev/holdout are identity-level scoring
splits, but every speaker remains in chronological replay as realistic gallery
and same-meeting context, so cross-split distractors cannot disappear from the
test. The holdout stays locked until a train + dev candidate clears those gates.

```bash
python3 scripts/run_speaker_autoresearch.py \
  --manifest /absolute/path/input-sha256.txt \
  --input-root /absolute/path/to/fingerprint-caches \
  --state-dir .autoeval/speaker-identification-YYYYMMDD \
  --phase all
```

Use `--phase discover` to run only train + dev exploration. After the finalists
are locked, use `--phase validate --skip-build` to load that saved discovery
state and run only the untouched holdout. `--phase prepare` verifies the frozen
inputs and builds the harness without evaluating candidates.

Every reusable checkpoint is bound to the manifest hash, canonical input root,
split, configs, report schema, evaluator source, compiled binary, and runner.
`--skip-build` also requires a source stamp from a successful runner-managed
build, so an old binary cannot silently validate new source.
Evaluator schema 3 introduced contextual identity scoring and fixed condition
guardrails, so checkpoints from earlier schemas are deliberately not reusable.

The state directory is resumable and gitignored. It contains the full attempt
ledger (`results.tsv`), raw logs, checkpoints, `resume.md`, and the locked
holdout report (`final-report.md`). Ground-truth identities only answer prompts
and score outputs; they are never passed into matching. Raw embeddings are not
written to reports.

## Network-free synthetic A/B (no corpus / no models)

The real corpora need multi-GB downloads + CoreML models. When that's unavailable, the
write-path fixes can still be A/B'd on **synthetic embeddings with controlled cosine geometry** —
the `replay` stage only consumes embeddings + RTTMs, both of which can be fabricated:

```bash
python3 scripts/gen_synthetic_speaker_eval.py     # -> data/eval/synthetic/{normal,twopeople,contamination}
MATCH=0.70 bash scripts/run_synthetic_speaker_eval.sh   # replay off/on + score each, print before/after
```

`normal` is a no-regression control; `twopeople` reproduces the #8 cross-cluster fusion bug;
`contamination` reproduces the #6 voiceprint-drift bug. Data is gitignored; the generator + driver
are committed so the probe is reproducible.

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
| `AMI_SET` | `es2002` | `es2002` \| `scale` (32 mtgs) \| `lab` (64 mtgs, 3 sites) \| `full` (~170) — `download_ami.sh` preset |
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
- Python 3 standard library for scoring (`scripts/speaker_eval_common.py` reimplements
  pyannote.metrics' DER/JER; `scripts/test_score_speaker_lab.py` cross-checks it when
  `pyannote.metrics` happens to be installed). The VoxCeleb
  sampler additionally needs `datasets` + `ffmpeg`; ICSI RTTM materialization needs
  `datasets` (`pip install datasets`).

## Files

| Path | Purpose |
|---|---|
| `Sources/speaker-eval-harness/main.swift` | wire models, helpers, command entry |
| `Sources/speaker-eval-harness/Dump.swift` | `dump`: diarize one file per variant (backend × embedder) |
| `Sources/speaker-eval-harness/Replay.swift` | `replay`: clusterer + speaker DB replay with threshold and fingerprint-update knobs |
| `Sources/speaker-eval-harness/AutoResearch.swift` | frozen chronological ASK / SUGGEST / AUTO evaluator |
| `Sources/speaker-eval-harness/AutoResearchModels.swift` | fingerprint, config, report, and simulation contracts |
| `Sources/speaker-eval-harness/AutoResearchSelfTests.swift` | production-parity and end-to-end replay fixtures |
| `Package.swift` | depends on root `TranscriptedCore`; mirrors deps link flags |
| `BASELINE_REPORT.md` | measured baseline (AMI ES2002) + threshold recommendations |
| `AB_DOT_VS_CLOUD.md` | dot-vs-cloud matcher A/B (cross-meeting re-ID) |
| `SCALEUP_REPORT.md` | AMI scale-up (~32 mtgs / dozens of identities) results at scale |
| `../../scripts/run_speaker_eval.sh` | end-to-end driver, keyed by `CORPUS` |
| `../../scripts/score_speaker_eval.py` | DER + fragmentation + false-merge + re-ID scorer (corpus-agnostic) |
| `../../scripts/aggregate_sweep.py` | sweep table + closest-to-ideal picker |
| `../../scripts/run_speaker_lab.sh` | speaker lab driver: variants × knob grid, corpus or own calls, `--single` trials |
| `../../scripts/score_speaker_lab.py` | speaker lab scorer: `scores.json`, `REPORT.md`, `timeline.html` |
| `../../scripts/speaker_eval_common.py` | shared scoring math (DER/JER, identity metrics, recognition) |
| `../../scripts/test_score_speaker_lab.py` | lab unit tests + fake-harness end-to-end driver tests |
| `../../scripts/run_speaker_autoresearch.py` | resumable parameter sweep, safety gates, and locked holdout promotion |
| `../../scripts/speaker_autoresearch_contract.py` | parameter grids, promotion guardrails, and reports |
| `../../scripts/speaker_autoresearch_runtime.py` | frozen-input, build, and checkpoint integrity |
| `../../scripts/ab_dot_vs_cloud.py` | dot-vs-cloud matcher A/B simulator (runs on cached embeddings) |
| `../../scripts/download_ami.sh` | AMI audio + RTTMs (`es2002` \| `scale` \| `lab` \| `full`) |
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
