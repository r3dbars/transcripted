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
false positives, not reduce them. The match threshold is the **weakest** lever. The one lever with real
headroom is the **diarizer**: ~28 of 30 trapped speakers are fused *within a meeting* before matching
ever runs, so the dominant false-positive source is upstream and untouchable by any matcher-side knob.
A matcher-side follow-up (§3a) shows **mean-centering does *not* reduce downstream false positives** — it
only un-collapses mega-profiles on heavy codecs (a fragmentation effect), and no online form is deployable.
Pair the diarizer fix with compression-robust embeddings for the smaller cross-meeting tail.

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

**Implication (band level):** the embeddings still carry speaker identity even at Opus 8k — the codec adds
a *removable* shared mean-shift, not irrecoverable loss. **But this is a statement about the embedding
bands, not the matcher.** We then tested whether it translates into fewer downstream false positives by
replaying centered embeddings through the real matcher — **it does not** (§3a). Read §3a before treating
mean-centering as a fix.

## 3a. Follow-up: does centering actually reduce false positives through the matcher? **No.**

We applied mean-centering to the cached dump embeddings and replayed them through the real clusterer + DB
matcher (modes: `normonly` control, `global` oracle, `running`/`frozen` online; measurement only, no app
code). Cleanly recomputed precision metrics (mass-weighted, collapse-robust) overturn the optimistic read:

- **At profile-count-matched operating points, centering does not move the precision frontier.** Merge-
  contamination (`fp_mass`) is within ±0.02 of baseline on clean/opus12k/g711u (clean −0.022, **opus12k
  +0.011 — slightly *worse***, g711u −0.031), and **every `fp_mass` drop is paid for by a near-equal
  `fn_mass` rise** — it converts merge errors into split errors (collapse → fragmentation), not removing
  error. Mean best-profile recall falls in every arm; clean 1:1 identity recovery (`iso1:1`) barely moves
  (Δ +1/−3/+1/+2) and never approaches 32. Baseline and `global` ride the **same fp-vs-profiles curve** —
  `global` just slides the operating point rightward to more profiles.
- **The only genuine effect is un-collapsing mega-profiles** on heavy codecs (opus8k baseline survives on
  5 profiles, `fp_mass` up to 0.87 → `global` ~20 profiles). That restores band separation and a countable
  profile set; it does **not** recover clean identities (people-trapped stays ~30/32 through the un-collapse).
- **The residual is a within-meeting diarizer floor centering cannot touch.** Centering only changes
  embedding vectors, never the diarizer's clusters/timings (verified byte-for-byte; `normonly` ≡ baseline).
  **~75–88 % of fused pairs and ~28 of ~30 trapped speakers are speakers the diarizer co-clustered inside a
  single meeting** — only ~2 speakers/arm are matcher-side (cross-meeting), and `global` leaves that thin
  tail flat (clean 8→8). A matcher-free floor of ~28–32 trapped speakers exists on **every** arm before any
  matching runs.
- **No deployable online estimator approaches the oracle.** The oracle `global` mean averages over all 32
  meetings' speakers, cancelling content and leaving only the codec direction — a property no causal window
  has until it has effectively seen everything. Best online variant (running EMA α=0.005) recovers ~71 % of
  the band-sep gain on opus12k but ~4 % on opus8k and still over-fragments; the original α=0.05 (~20-segment
  window) tracks the current speaker and destroys separation; frozen-warmup (calibrate on meeting 1) matches
  the oracle direction (cos ~0.8) but is too noisy and under-merges. A real fix needs **out-of-band per-codec
  calibration**, not live-stream estimation.

**Correction to the lever ranking below:** "mean-center embeddings before matching" is **not** a precision
lever and is **downgraded** — it is a narrow *offline anti-collapse* remedy for heavy codecs only. The
dominant ceiling is the diarizer's within-meeting co-clustering.

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

*(Ranking revised after the §3a matcher experiment — mean-centering is demoted; the diarizer is promoted.)*

| # | Lever | Measured justification | Status |
|---|---|---|---|
| **1** | **Fix the diarizer's within-meeting co-clustering** | ~28/30 trapped speakers + 75–88 % of fused pairs are within-meeting diarizer co-clusters; confusion = 68 % of DER even on clean; clusters/true < 1 everywhere; matcher-free floor ~28–32 trapped | **the only lever with headroom** on real false positives; nothing matcher-side moves it |
| 2 | **Compression-robust / codec-augmented embeddings** | root cause of the *cross-meeting* tail = diff band rising 0.28 → 0.60; FM pressure 5 % → 53 % | durable fix for the (smaller) matcher-side tail; fine-tune WeSpeaker with Opus/G.711 augmentation |
| 3 | **Quality-adaptive threshold tuning** | moves you *along* the fp-vs-profiles frontier; optimal X holds/rises with compression | honest precision/fragmentation trade — no free lunch; never *lower* it |
| 4 | **Offline (oracle) mean-centering** | restores band separation to 0.77–0.81 and un-collapses mega-profiles on heavy codecs | **narrow anti-collapse use only — NOT a precision lever** (§3a: Δfp ≤ 0.02 at matched profile count; fn rises in lockstep) |
| 5 | **Pre-embedding denoise / bandwidth-extension** | motivated by the shared-coloration mechanism | **UNVALIDATED — no arm run**; gate behind a measured BWE arm |
| 6 | **Online running-EMA centering** | best variant α=0.005 recovers ~71 %/4 % of oracle band-sep, over-fragments | **not deployable as-is**; needs out-of-band per-codec calibration |
| 7 | **Lowering the global match threshold** | doesn't drop to 0.50; lowering collapses identities (opus8k → 3 profiles) | **actively harmful** on compressed audio |

## 7. Recommendation for production

- **Keep the global match threshold at 0.60** (0.62–0.65 if you weight re-ID over false-merge). **Do not
  lower it.** Add a quality-adaptive **raise to 0.65–0.70** on detected narrowband / low-bitrate sources.
- **The one lever with real headroom is the diarizer** — reducing within-meeting speaker co-clustering is
  the only thing that moves the ~28/30 people-trapped floor. Pair it with codec-augmented embeddings for the
  cross-meeting tail. **Do not rely on mean-centering as a precision fix** (§3a) — it only un-collapses
  mega-profiles on heavy codecs and is not deployable online.
- Opus 8k / narrowband telephony is **structurally unrecoverable by matcher-side tuning** (threshold *or*
  centering) — it needs a better diarizer + embeddings.

## 8. What this eval cannot justify

- **Real-Transcripted thresholds.** AMI is 4-party **in-room headset** audio synthetically codec-degraded,
  not captured Zoom/Meet/Teams **system audio**. The *direction* (compression inflates the stranger band;
  under-segmentation worsens) is robust; the absolute numbers **overstate** a typical 2–3-person call's
  difficulty.
- **Any denoise / bandwidth-extension gain** — no such arm was run (lever 4 is a hypothesis).
- **Highest-value next experiment:** a small **labelled real Zoom/Meet/Teams corpus** with recurring
  identities, plus — most importantly — a **diarizer arm** (a multi-party / compression-tuned segmenter) to
  attack the within-meeting co-clustering floor that §3a shows is the real ceiling.

## Reproduce

```bash
# clean AMI audio + RTTMs already under data/ami/ (scale set, 32 meetings, gitignored)
MATCH="0.40 0.45 0.50 0.55 0.60 0.65 0.70" bash scripts/run_all_codec_arms.sh
#   -> data/eval/ami_<arm>/reports/{SWEEP.md, bands.json}  (per arm)
python3 scripts/aggregate_codec_arms.py --out-md data/eval/AMI_CODEC_SWEEP.md   # X-vs-compression table
python3 scripts/recompute_bands_verify.py    # independent band recompute + mean-centering test
python3 scripts/jackknife_series_bands.py    # leave-one-series-out robustness
python3 scripts/bootstrap_series_bands.py    # paired cluster bootstrap (ordering)

# §3a mean-centering matcher experiment
ARMS="clean opus24k opus16k opus12k opus8k g711u" MODES="normonly global running" \
  bash scripts/run_centering_experiment.sh     # center dumps -> replay real matcher -> score
python3 scripts/compare_centering.py --out-md data/eval/CENTERING_COMPARE.md   # people-trapped view
python3 scripts/center_purity_analysis.py       # collapse-robust precision frontier (fp_mass/fn_mass)
python3 scripts/q3_attribution.py ; python3 scripts/q3_floor.py   # within-meeting diarizer floor
bash scripts/dev/run_online_centering_sweep.sh  # alpha-sweep + frozen-warmup deployability test
```
All `data/` artifacts are gitignored. Re-ID uses AMI's recurring participant ids (no `--per-file-ids`).
`scripts/center_dumps.py` modes: normonly (control) · global (oracle) · running (online EMA) · frozen (warmup).
