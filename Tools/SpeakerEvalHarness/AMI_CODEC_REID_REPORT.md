# AMI codec sweep — cross-meeting speaker re-ID under compression

**Date:** 2026-06-17 · **Corpus:** AMI scale set, 32 meetings (ES2002–ES2010, series a–d),
**32 recurring speakers** (4 per series, each appears in exactly 4 meetings — a real cross-meeting
re-ID testbed). **Arms:** clean · Opus 24k · Opus 16k · Opus 12k · Opus 8k · G.711 μ-law 8k,
bracketing pristine headset → Zoom/Meet wideband → aggressive VoIP → narrowband telephone.
**Config under test:** `TranscriptedCore.DiarizationService.diarizeOffline` (PyAnnote + VBx + 256-dim
WeSpeaker) on codec-degraded audio; cross-meeting match = `SpeakerDatabase.matchSpeaker(threshold:)`.
Grid: consolidation none × match {0.40 … 0.70}. Re-ID scoring on (AMI ids recur; no `--per-file-ids`).

> **Measured vs assumed.** Every §-numbered value is **measured** by the harness on real AMI audio,
> synthetically codec-degraded with ffmpeg (libopus / pcm_mulaw), and **independently recomputed from
> raw dumps + RTTMs** by five verifier passes (all reproduced to the rounding digit). Claims about
> *real Transcripted Zoom/Meet audio* and *bandwidth-extension gains* are **inferred / unvalidated** and
> labelled as such.

> **Validity check (passed).** The clean control reproduces the prior SCALEUP baseline **exactly**:
> match 0.60 → 32 profiles for 32 people, false-merge 22, re-ID #2+ 0.532. The harness is sound, so the
> codec arms are directly comparable.

---

## Bottom line

**Compression does NOT want a lower match threshold — the opposite.** It holds at ~0.60 or rises,
because codec degradation inflates the *different-speaker* similarity band (strangers start looking
alike: 0.28 → 0.60) while same-speaker similarity stays flat. Lowering toward 0.50 would **increase**
false positives, not reduce them. The match threshold is the **weakest** lever. The two real levers for
fewer false positives are (0) **mean-centering embeddings before matching** — newly proven here to undo
nearly all the codec damage essentially for free — and (1) **compression-robust embeddings + a
multi-party diarizer**, since the diarizer's under-segmentation is the dominant error source at every
compression level.

**🟢 GREEN.** The eval ran clean, the control reproduces SCALEUP exactly, the headline survived
adversarial re-derivation under three threshold definitions, and the degradation ordering held in 8/8
leave-one-series-out folds and 0/5000 bootstrap resamples.

---

## 1. Per-arm results (recomputed + verified)

Cross-meeting embedding bands (per-(meeting,speaker) L2-normalized mean; same-speaker = 192 cross-meeting
pairs; different-speaker = 7,744 cross-meeting pairs). False-merge pressure @0.60 = fraction of
different-speaker pairs ≥ 0.60. DER macro-mean over 32 meetings at match 0.60.

| arm | simulates | same-spk | diff-spk | **separation** | FM pressure @0.60 | DER (confusion) | clusters/true |
|---|---|---|---|---|---|---|---|
| **clean** | pristine headset | 0.828 | 0.284 | **0.544** | 5.4 % | 0.437 (0.298) | 0.969 |
| **opus24k** | Zoom/Meet typical | 0.835 | 0.329 | **0.506** | 7.0 % | 0.501 (0.362) | 0.875 |
| **opus16k** | Zoom low / Meet | 0.844 | 0.365 | **0.478** | 7.0 % | 0.474 (0.334) | 0.930 |
| **opus12k** | aggressive VoIP | 0.852 | 0.431 | **0.421** | 10.2 % | 0.495 (0.356) | 0.953 |
| **opus8k** | very low bitrate | 0.888 | 0.601 | **0.287** | **52.6 %** | 0.612 (0.424) | 0.656 |
| **g711u** | PSTN / telephone | 0.871 | 0.450 | **0.421** | 10.0 % | 0.570 (0.397) | 0.750 |

Separation collapses 0.544 → 0.287, driven **entirely by the different-speaker band rising** (same-speaker
is flat-to-slightly-up, 0.83 → 0.89). Note G.711 narrowband (0.421) is *less* destructive than very-low-
bitrate Opus 8k (0.287): band-limiting hurts less than aggressive lossy coding.

## 2. The optimal MATCH threshold does not drop — it holds or rises

`profiles_end` (target = 32, one per real person) vs match, all arms:

| match | clean | opus24k | opus16k | opus12k | opus8k | g711u |
|---|---|---|---|---|---|---|
| 0.50 | 20 | 16 | 10 | 6 | 3 | — |
| 0.60 | **32** | 23 | 23 | 20 | 5 | 12 |
| 0.65 | 35 | 27 | 29 | 27 | 6 | 21 |
| 0.70 | 44 | 37 | 32 | 34 | **10** | 27 |

Verified under three independent definitions of "optimal" (profile-count nearest 32; band-separation
argmax; lowest match with false-merge ≤ clean baseline and re-ID ≥ 0.45): **none trends downward.** Clean
is count-optimal exactly at 0.60; every compressed arm needs ≥ 0.60 and most never reach 32 profiles at
all. **Opus 8k caps at 10 identities at any threshold; G.711 caps at 27** — compression destroys identity
recovery in a way no threshold restores. The only place a low number appears (a literal "0.40 minimises
false-merge-count") is a **degenerate artifact**: at low thresholds everything collapses into 3–5
mega-profiles, so the raw count is small only because there are almost no profiles left to merge.

## 3. Why — shared codec coloration, not lost identity (the key finding)

The separation collapse is **not** destruction of speaker information. It is a single shared additive bias
the codec injects into every embedding, whose magnitude grows with bitrate loss. Two pieces of evidence:

- **‖shared centroid‖² tracks the different-speaker band almost 1:1** across all arms (clean 0.312 vs
  diff 0.284; opus8k 0.618 vs diff 0.601). The entire diff-band rise is the projection of every embedding
  onto one common direction.
- **Mean-centering** (subtract the per-arm global centroid, renormalize) **near-fully restores
  separation:**

| arm | separation (raw) | separation (mean-centered) |
|---|---|---|
| clean | 0.544 | 0.791 |
| opus24k | 0.506 | 0.788 |
| opus16k | 0.478 | 0.785 |
| opus12k | 0.421 | 0.773 |
| **opus8k** | **0.287** | **0.770** |
| g711u | 0.421 | 0.805 |

After centering, all six arms land in a tight **0.77–0.81** band — the codec ordering disappears and
opus8k ties clean. The different-speaker band drops to ≈ −0.04 (uncorrelated) for every arm.

**Implication:** the embeddings still carry speaker identity even at Opus 8k. A *fixed global cosine
threshold* fails because of a removable mean-shift — so **running / per-source mean-centering before
matching recovers near-clean discriminability without retraining the model.** (Proven on the bands;
gate on a matcher-side arm before shipping.)

## 4. Diarizer & DER — the bottleneck, and the "1→9" fear

Raw diarizer cluster count vs true speaker count per meeting:

| arm | under | exact | over | clusters/true |
|---|---|---|---|---|
| clean | 15 | 8 | 9 | 0.969 |
| opus24k | 18 | 5 | 9 | 0.875 |
| opus16k | 14 | 8 | 10 | 0.930 |
| opus12k | 15 | 4 | **13** | 0.953 |
| opus8k | **28** | 4 | **0** | 0.656 |
| g711u | 23 | 9 | **0** | 0.750 |

- The diarizer **under-segments** everywhere, and **heavy compression makes it sharply worse** (opus8k
  finds 0.66 clusters per true speaker — it merges a third of the speakers away). This is *why* opus8k can
  never recover 32 identities.
- DER is **confusion-dominated** at every level (≈ 62–68 % of DER). An oracle relabelling shows the
  matcher's residual confusion contribution is ≤ 0 in every arm — i.e. **confusion is 100 % upstream
  (the diarizer mixing speakers within a meeting)**, not the matcher.
- **The user's "one person → 9 speakers" over-split is not the failure mode.** Over-segmentation never
  rises with compression — it peaks mildly at Opus 12k (over = 13) and falls to **0** at Opus 8k / G.711.
  The dominant failure is the opposite: merging distinct people.

## 5. Significance & robustness

The claim rests on 32 speakers across **8 series** (the effective N, not the 7,744 pairs).

- Point estimates reproduce exactly; **ordering clean > opus12k > opus8k holds in 8/8 leave-one-series-out
  jackknife folds and 0/5000 paired cluster-bootstrap resamples.**
- Inter-arm separation gaps (~0.12–0.13) are ≈ 4× the per-arm jackknife SE (~0.03); the most influential
  single series (ES2006) cannot overturn the ordering.
- **Caveat:** at N = 8, **opus12k ≈ g711u ≈ 0.42 are statistically indistinguishable** (overlapping CIs);
  treat the mid-arms as one band. The same-speaker band's slight upward drift under compression is within
  noise (±0.01) — read it as spectral smoothing, not improved identity.

## 6. Fewer false positives — the ranked levers (the product ask)

**Lowering the match threshold INCREASES false positives on compressed audio.** (Cite the right metric:
raw `false_merge.count` is misleading at low thresholds because the DB collapses into a few mega-profiles —
at Opus 8k, lowering to 0.50 fuses 32 people into **3 profiles**. The honest measure is identity collapse /
people-trapped, which is worse at lower thresholds.)

| # | Lever | Measured justification | Status |
|---|---|---|---|
| **0** | **Mean-center embeddings before matching** | Restores separation to 0.77–0.81 on *every* arm incl. opus8k; diff band → −0.04 | **cheapest real win**; proven on bands, gate on a matcher-side arm |
| 1 | **Compression-robust / codec-augmented embeddings** | Root cause = diff band rising 0.28 → 0.60; FM pressure 5 % → 53 % | highest durable impact; fine-tune WeSpeaker with Opus/G.711 augmentation |
| 2 | **Fix the under-segmenting diarizer** | confusion = 68 % of DER even on clean; clusters/true < 1 everywhere; confusion is 100 % upstream | the *current* bottleneck even on clean audio |
| 3 | **Quality-adaptive threshold RAISE on degraded audio** | optimal X rises with compression (0.60 → 0.65–0.70) | cheap, real, modest ceiling — mitigates, doesn't fix |
| 4 | **Pre-embedding denoise / bandwidth-extension** | motivated by the shared-coloration mechanism | **UNVALIDATED — no arm run**; gate behind a measured BWE arm |
| 5 | **Global match-threshold tuning** | doesn't drop to 0.50; clean 0.60, all compressed ≥ 0.60; no clean win | **weakest lever** — the one people reach for first |

## 7. Recommendation for production

- **Keep the global match threshold at 0.60** (0.62–0.65 if you weight re-ID over false-merge). **Do not
  lower it.** Add a quality-adaptive **raise to 0.65–0.70** on detected narrowband / low-bitrate sources.
- **Invest in levers 0–2, not the threshold.** Mean-centering is a near-free first step; codec-augmented
  embeddings + a multi-party/compression-tuned diarizer are the durable fixes.
- Opus 8k / narrowband telephony is **structurally unrecoverable by threshold tuning alone** — only
  centering + better embeddings move it.

## 8. What this eval cannot justify

- **Real-Transcripted thresholds.** AMI is 4-party **in-room headset** audio synthetically codec-degraded,
  not captured Zoom/Meet/Teams **system audio**. The *direction* (compression inflates the stranger band;
  under-segmentation worsens) is robust; the absolute numbers **overstate** a typical 2–3-person call's
  difficulty.
- **Any denoise / bandwidth-extension gain** — no such arm was run (lever 4 is a hypothesis).
- **Highest-value next experiment:** a small **labelled real Zoom/Meet/Teams corpus** with recurring
  identities, plus a **denoise/BWE front-end arm** on the existing opus8k/g711u dumps (promotes levers 0
  and 4 from hypothesis to measurement).

## Reproduce

```bash
# clean AMI audio + RTTMs already under data/ami/ (scale set, 32 meetings, gitignored)
MATCH="0.40 0.45 0.50 0.55 0.60 0.65 0.70" bash scripts/run_all_codec_arms.sh
#   -> data/eval/ami_<arm>/reports/{SWEEP.md, bands.json}  (per arm)
python3 scripts/aggregate_codec_arms.py --out-md data/eval/AMI_CODEC_SWEEP.md   # X-vs-compression table
python3 scripts/recompute_bands_verify.py    # independent band recompute + mean-centering test
python3 scripts/jackknife_series_bands.py    # leave-one-series-out robustness
python3 scripts/bootstrap_series_bands.py    # paired cluster bootstrap (ordering)
```
All `data/` artifacts are gitignored. Re-ID uses AMI's recurring participant ids (no `--per-file-ids`).
