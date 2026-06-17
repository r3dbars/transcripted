# Diarizer arm — can better clustering/segmentation cut within-meeting speaker merging? **No.**

**Date:** 2026-06-17 · **Corpus:** AMI scale set, 32 meetings × 4 speakers (128 true speakers/arm), 6 codec
arms (clean → Opus 24/16/12/8k → G.711). **Measurement only — no app code, no re-diarization.** Re-clusters
the per-segment 256-dim WeSpeaker embeddings already in the cached dumps with alternative methods, evaluated
on the identical quality-filtered set (quality ≥ 0.3, dur ≥ 1 s); `app` = the dump's own diarizer `speakerId`
on that set. DER = pyannote optimal-mapping confusion (isolates clustering quality; no miss/FA term).

> **Why this experiment.** The AMI-codec work showed the dominant false-positive source is the diarizer
> merging distinct speakers *within* a meeting (~28/30 trapped), untouchable by the matcher (threshold ✗,
> mean-centering ✗). This tests the remaining downstream knobs: can a **better clusterer** — or **finer
> segmentation** — recover the merged speakers from the same embeddings? Verified by 4 probes (full method
> matrix, mixed-segment diagnosis, pure-segment separability, end-to-end through the real matcher).

> **Validity.** `clean`/`app` reproduces the established headline exactly (clusters/true 0.969, coverage 0.75,
> purity 0.80, DER 0.30); an independent recompute of the opus8k pure-vs-all coverage matches (0.617 vs 0.641).

---

## Bottom line

**Clustering is not the lever, and neither is segmentation. The within-meeting merging is baked into the
WeSpeaker embeddings — distinct speakers' vectors collapse together, and compression makes it strictly worse.
The only lever the data supports is codec-robust speaker embeddings.** We have now systematically ruled out
*every* tunable downstream knob: match threshold, mean-centering, clustering algorithm/k, and finer/overlap-
aware segmentation.

**🟢 GREEN** — exhaustive (13 clustering methods × 6 arms × centerings), the clean control reproduces prior
results exactly, and the embedding-bound conclusion is confirmed by two independent controls + an end-to-end
replay. (A negative result for the knobs, but a *positive*, decision-useful localization of the real lever.)

---

## 1. Better clustering does not lower DER on any arm

Best DER over all 13 methods (oracle-k agglo/ward/spectral/kmeans, ± mean-centering, and an auto-k threshold
sweep) vs the app diarizer:

| arm | app coverage / DER | best DER (method) | best coverage (method) | DER gain |
|---|---|---|---|---|
| clean | 0.75 / 0.301 | 0.292 (spectral-k) | 0.805 (spectral-k) | −0.009 |
| opus24k | 0.66 / 0.355 | 0.354 | 0.750 | −0.001 |
| opus16k | 0.71 / 0.303 | 0.303 | 0.789 | −0.001 |
| opus12k | 0.69 / 0.329 | 0.328 | 0.734 | −0.001 |
| opus8k | 0.57 / 0.474 | 0.474 | 0.672 | ±0.000 |
| g711u | 0.56 / 0.431 | 0.430 | 0.688 | −0.001 |

- **Oracle-k** (handing the clusterer the true count = 4) **does not lower DER anywhere.** It lifts *coverage*
  (+0.05 to +0.13; opus8k 0.57 → 0.67), but those gains come from spectral carving extra **low-purity**
  clusters (0.61–0.76 vs 0.78–0.84) — recovered "speakers" that don't reduce confusion. For the metric that
  matters (within-meeting confusion), the gain is ~0.
- **Mean-centering: ✗** (moves DER ≤ 0.002). **Auto-k threshold sweep: ✗** — the best threshold (0.8) just
  converges to the app's own clustering; lower thresholds only over-merge.
- Even at oracle-k, compressed-audio coverage tops out ~0.62–0.67 — **a third of speakers stay merged** when
  you already know how many there are.

## 2. The ceiling is the embeddings, not segmentation

**Mixed/overlap segments do not explain the ceiling.** Segments whose time span straddles ≥ 2 speakers
(dominant share < 0.8) are a 15–21 % minority; the median filtered segment is **100 % one speaker**. Across
the 6 arms, %mixed correlates **positively** with oracle-k coverage (r = +0.86) — the opposite of the
segmentation hypothesis — and heavy compression *reduces* mixing by emitting ~70 % more, shorter segments
(opus8k median 4.45 s vs clean 7.45 s) yet coverage still collapses. Two controls clinch it: (a) true speakers
appearing *only* in mixed segments: **0 of 128** on every arm — a clean embedding exists for essentially every
speaker; (b) dropping mixed segments and re-running oracle-k on the pure set gives coverage **equal-to-or-below**
the all-segment number.

**Pure single-speaker segments still don't separate** (the decisive test):

| arm | all-seg coverage | **pure-seg coverage** | pure-seg purity | verdict |
|---|---|---|---|---|
| clean | 0.83 | **0.77** | 0.88 | embedding-bound (mild) |
| opus12k | 0.73 | **0.72** | 0.83 | embedding-bound |
| opus8k | 0.68 | **0.60–0.65** | 0.83 | embedding-bound (severe) |
| g711u | 0.66 | **0.62–0.66** | 0.84 | embedding-bound (severe) |

All 4 true speakers survive the pure filter (31/32 clean, 32/32 opus8k), so low coverage is **genuine
merging, not a dropped speaker**. If overlap were the bottleneck, pure-segment coverage would jump toward 1.0;
instead it is flat-to-worse. Distinct WeSpeaker vectors collapse together even with one clean voice per
segment, and compression worsens it (codec severity ↔ oracle-k coverage r = −0.87).

## 3. Better clusters never even reach the matcher — and a flag is misnamed

Feeding exactly 4 oracle-k clusters/meeting and replaying through the real harness, the app's
`EmbeddingClusterer.postProcess` **re-collapses them** to the baseline diarizer's under-segmented grouping:

| arm | oracle-k input k | surviving k after postProcess | baseline post-k | DER change downstream |
|---|---|---|---|---|
| clean | 4 | 3.41 | 3.84 | +0.006 … +0.013 (worse) |
| opus12k | 4 | 3.22 | 3.75 | +0.006 (worse) |
| opus8k | 4 | **2.62** | 2.59 | **bit-identical on all 32 meetings** |

**Code finding (read-only):** the harness ran with `--consolidation none`, but that flag does **not** disable
within-meeting consolidation. `postProcess` runs `absorbSmallClusters` + `consolidateSameVoiceClusters`
(agglomerative merge at cosine **0.88**, the auto-accept bar) + `dbInformedSplit` **unconditionally**
(`Sources/TranscriptedCore/Speaker/EmbeddingClusterer.swift:60–83`); only the optional `pairwiseMerge` and the
consolidation *threshold* are nil-able. The 0.88 same-voice merge is the mechanism that re-collapses oracle-k.
This is a real, actionable bug-ish: **the named knob doesn't turn off the collapse** — worth fixing/renaming
if these passes are meant to be skippable for eval. (Secondary to the embedding ceiling: even uncollapsed,
oracle-k's upside was small.)

## 4. The lever — bounded to what the data shows

With match-threshold ✗, mean-centering ✗, clustering ✗, and finer/overlap segmentation ✗:

1. **Codec-robust speaker embeddings (primary).** Retrain/fine-tune WeSpeaker (or adopt a more robust model)
   with codec augmentation (Opus 8–24k, G.711). This is the *only* intervention that can move the floor —
   every probe shows the merging lives in the embeddings and compression worsens it. **Bounded expectation:**
   even clean audio's oracle-k ceiling is ~0.83 coverage, so expect *improvement, not elimination* (~1 in 6
   speakers may stay hard even uncompressed).
2. **Loosen `postProcess` within-meeting consolidation (secondary, capped).** Raising the 0.88 same-voice bar
   (or making `--consolidation none` actually skip the pass) lets a few more separable clusters survive —
   a small false-merge/fragmentation cleanup on clean/opus12k. Capped by the low oracle-k ceiling; only
   worthwhile alongside the embedding fix.
- **Explicitly not levers:** matcher match-threshold, clustering algorithm/k, embedding mean-centering, finer
  segmentation.

## Limits

- AMI 4-party in-room headset, synthetically codec-degraded — not captured Zoom/Meet system audio (direction
  robust; absolute coverage/DER will differ on real 2–3-person calls). DER here is optimal-mapping confusion
  on the quality-filtered set, so it is a *clustering-quality* DER, comparable across methods but not equal to
  the full-pipeline DER in the codec report.
- "Coverage" counts a true speaker as recovered if it is the time-dominant speaker of ≥ 1 cluster; it does not
  credit partial recovery. The embedding-bound verdict is corroborated by purity and DER, which agree.

## Reproduce

```bash
# full method matrix (per arm/method/center), 32 meetings each
for arm in clean opus24k opus16k opus12k opus8k g711u; do
  for m in app agglo_oraclek ward_oraclek spectral_oraclek kmeans_oraclek; do
    python3 scripts/recluster_eval.py --arm $arm --method $m --out-json data/eval/reclust_${arm}_${m}.json
  done
done
python3 scripts/mixed_segment_diag.py            # segmentation vs embeddings (mixed-segment rate)
python3 scripts/pure_segment_separability.py     # pure single-speaker oracle-k (embedding-bound test)
python3 scripts/oraclek_dumps.py                 # rewrite dumps with oracle-k speakerId for end-to-end replay
```
All `data/` artifacts are gitignored. Consolidation source inspected read-only:
`Sources/TranscriptedCore/Speaker/EmbeddingClusterer.swift`.
