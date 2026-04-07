# FluidAudio OfflineDiarizerConfig — Transcripted Champion Snapshot

Snapshot of Transcripted's tuned `OfflineDiarizerConfig` values as of 2026-04-04,
captured per merge-plan.md v6 Phase 2.0 step 2b. These are the DER-optimized
values that **must** survive any FluidAudio version bump, binary retirement,
or core-extraction refactor. If a downstream step ever flattens the config to
`.default`, the numbers are recoverable from this file.

**Source**: `Transcripted/Services/DiarizationService.swift:106-123` (on branch
`feat/extract-core`, reflecting the state committed in `596d294` during Phase
2.0 FluidAudio 0.7.9 port — these values were **not** touched by Phase 2.0,
only the Swift-level `initialize(models:)` rename).

**Tuning provenance** (per the inline comment at
`DiarizationService.swift:104-105`):

> Optimized config from DER grid search (v2, 100 iterations across 16 Zoom
> meetings). Key win: `Fa` 0.07→0.25 (~halves DER by letting VBx reconsider
> speaker assignments).

**Speaker range**: `.withSpeakers(min: 3, max: 11)` is appended via a
backward-compat wrapper. This is applied AFTER the flat 16-field init and
takes precedence over any `.default` speaker count; it encodes Transcripted's
assumption that real meetings have 3-11 participants.

---

## Champion fields (11, per merge-plan v6)

These are the fields whose values differ meaningfully from FluidAudio's
`OfflineDiarizerConfig.default` or whose values are explicitly a product of
the DER grid search. Losing any of these during a version bump would
regress diarization quality.

| # | Field                     | Champion value | Note                                                                                                                          |
|---|---------------------------|----------------|-------------------------------------------------------------------------------------------------------------------------------|
| 1 | `clusteringThreshold`     | `0.6`          | VBx agglomerative-clustering cutoff; downstream EmbeddingClusterer handles merge/split refinement.                            |
| 2 | `Fa`                      | `0.25`         | **Key DER win** — raised from FluidAudio default `0.07` to let VBx reconsider speaker assignments; ~halves DER on Zoom set.   |
| 3 | `Fb`                      | `0.63`         | VBx backward pass weight; paired with `Fa` above as the most sensitive DER lever in the grid search.                          |
| 4 | `windowDuration`          | `10.0`         | Segmentation window in seconds; matches PyAnnote segmentation model's native receptive field.                                 |
| 5 | `segmentationStepRatio`   | `0.266`        | Overlap between segmentation windows (~26.6% step → ~73.4% overlap) for smooth boundaries.                                    |
| 6 | `embeddingBatchSize`      | `32`           | WeSpeaker embedding batch; tuned for M-series GPU throughput without VRAM pressure.                                           |
| 7 | `minSegmentDuration`      | `1.1821`       | Segments shorter than this are dropped pre-clustering; removes fragmentary hits.                                              |
| 8 | `minGapDuration`          | `0.2874`       | Gaps shorter than this are bridged; prevents micro-splits within a single utterance.                                          |
| 9 | `exclusiveSegments`       | `true`         | Each audio frame assigned to at most one speaker (no overlap output). Required by downstream per-speaker Parakeet transcription. |
| 10 | `speechOnsetThreshold`   | `0.4472`       | VAD onset posterior threshold; paired with offset below, tuned by grid search.                                                |
| 11 | `maxVBxIterations`       | `24`           | VBx convergence cap; higher than FluidAudio default to tolerate difficult multi-speaker meetings.                             |

---

## Non-champion fields (5, for completeness)

These are the remaining fields in the 16-field flat init. Included here so the
full config is recoverable from a single file.

| Field                          | Value    | Note                                                                                                   |
|--------------------------------|----------|--------------------------------------------------------------------------------------------------------|
| `embeddingExcludeOverlap`      | `true`   | Skip embedding extraction from frames where speakers overlap; cleaner speaker fingerprints.            |
| `speechOffsetThreshold`        | `0.4472` | VAD offset posterior; symmetric with `speechOnsetThreshold` by grid-search result.                     |
| `segmentationMinDurationOn`    | `0.0`    | No minimum-on constraint from segmentation model; handled downstream via `minSegmentDuration`.         |
| `segmentationMinDurationOff`   | `0.2738` | Minimum silence between regions at segmentation stage; paired with `minGapDuration` downstream.        |
| `convergenceTolerance`         | `0.0001` | VBx convergence criterion; standard value, not tuned in grid search.                                   |

---

## Post-init modifier

```swift
.withSpeakers(min: 3, max: 11)
```

Applied after the flat init. Encodes Transcripted's meeting assumption (3-11
participants). Backward-compat wrapper in FluidAudio 0.7.9 — still supported,
not renamed.

---

## Verbatim source (for byte-level recoverability)

Copied from `Transcripted/Services/DiarizationService.swift:106-123` on branch
`feat/extract-core` at commit `596d294`:

```swift
let offlineConfig = OfflineDiarizerConfig(
    clusteringThreshold: 0.6,
    Fa: 0.25,
    Fb: 0.63,
    windowDuration: 10.0,
    segmentationStepRatio: 0.266,
    embeddingBatchSize: 32,
    embeddingExcludeOverlap: true,
    minSegmentDuration: 1.1821,
    minGapDuration: 0.2874,
    exclusiveSegments: true,
    speechOnsetThreshold: 0.4472,
    speechOffsetThreshold: 0.4472,
    segmentationMinDurationOn: 0.0,
    segmentationMinDurationOff: 0.2738,
    maxVBxIterations: 24,
    convergenceTolerance: 0.0001
).withSpeakers(min: 3, max: 11)
```

## Verification guarantee

A future FluidAudio version bump or TranscriptedCore extraction is only safe
if the resulting `OfflineDiarizerConfig` instance produces the same 16 field
values as the table above. If any field drifts, DER regression is expected and
the fix is to restore from this snapshot.
