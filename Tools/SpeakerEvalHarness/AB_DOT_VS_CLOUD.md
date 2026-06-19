# Speaker-Matcher A/B: DOT vs CLOUD — Final Verdict

Adversarially-verified A/B (4 explore variants + 3 independent skeptic passes, every number
re-run and reproduced) comparing the production-style **DOT** matcher against a proposed
**CLOUD** matcher for cross-meeting speaker re-identification.

**Reproduce:**
```bash
# 1. regenerate the 300 single-speaker meetings + cached embeddings (one split):
bash scripts/download_voxceleb_sample.sh    # VOXCELEB_IDENTITY_CAP=30, singles mode
CORPUS=voxceleb MATCH="0.6" scripts/run_speaker_eval.sh   # populates data/eval/voxceleb/dumps/
# 2. run the A/B simulator over the cached embeddings:
python3 scripts/ab_dot_vs_cloud.py --dumps-dir data/eval/voxceleb/dumps --max-app 8
#    JSON for one config: ... --matcher cloud --thr 0.46 --cap 10 --json
```
`scripts/ab_dot_vs_cloud.py` implements both matchers (DOT = one EMA-averaged vector/profile,
match by cosine≥thr; CLOUD = keep each profile's sample vectors, match a new clip to its
*nearest* stored sample). The `cloud+merge` variant below was an explored extension run during
the workflow; it is not in the committed simulator.

## TL;DR
Naive CLOUD does **not** decisively beat DOT. At matched ~30-profile parity CLOUD is
**directionally** better on identity-continuity (reid +5 pts avg) and **cleaner** on
false-merge, while **tied** on "recognized." But the margin sits **inside the N=30 noise
floor** — every bootstrap 95% CI crosses zero. The one statistically robust lever found is
internal to DOT: **tuning its EMA slower (0.3) → +19 pts, CI [+10.7, +27.8]**, a free one-line
change with no extra memory.

## DOT calibration (faithfulness check)
Python DOT @ thr0.50/ema0.5 → reid m2..m5 = **33/50/57/43**, profiles_end **37**. Swift
`SpeakerDatabase` ground truth → ~**36/48/55/33**, profiles ~**32**. Same rise-then-fall shape
peaking at m4; m2/m3/m4 within ~2–3 pts. The PE overshoot is expected — the Python port omits
the production `mergeDuplicates` pass and fixes ema=0.5. **DOT is a faithful stand-in.**

## Fair operating points (the only honest comparison)
Compare **only** where both end near the ideal **30 profiles** with comparable false_merge.

| Config | thr | profiles_end | false_merge | avg reid (m2–m8) | avg recognized |
|---|---|---|---|---|---|
| **DOT** (best fair) | 0.45 / ema0.5 | 33 | 7 | 45 | 93 |
| **CLOUD** (best fair) | 0.46 / cap10 | **30** | **5** | **50** | 94 |
| cloud+merge | 0.55 / merge0.53 / cap10 | 30 | **0** | 48 | 79 |

CLOUD sits at the **ideal 30 profiles with lower false_merge** than the 33-profile DOT it
beats — the **stricter** side, so its edge is conservative, not bought with leniency. Forcing
DOT down to PE=30 (thr~0.40) **doubles its false_merge to 10**.

## Per-meeting comparison (reid-to-anchor = continuity with original identity)

| Meeting | DOT 0.45 | CLOUD 0.46 | CLOUD−DOT | cloud+merge |
|---|---|---|---|---|
| m2 (1st return) | 53 | 47 | **−6** | 40 |
| m3 | 50 | 60 | +10 | 63 |
| m4 | 53 | 63 | +10 | 50 |
| m5 | 47 | 47 | 0 | 40 |
| m6 | 33 | 47 | +14 | 40 |
| m7 | 37 | 40 | +3 | 50 |
| m8 | 40 | 43 | +3 | 53 |
| **avg** | **45** | **50** | **+5** | **48** |

CLOUD wins 5/7 meetings, ties 1, **loses only m2** — the first re-encounter (where DOT also
leads on "recognized," 83 vs 77). The CLOUD advantage **grows at the tail because DOT decays**
(EMA blending lets duplicate badges drift and win the nearest-match), not because CLOUD climbs.

## Does the best CLOUD curve climb with more meetings?
**No.** CLOUD's reid spikes at m3–m4 (~60–63) then plateaus ~43–47. Neither matcher delivers the
intuitive "better every meeting" — what changes is DOT sagging late while CLOUD holds.

## What the skeptics concluded
- **fairness-cherrypick — NOT refuted.** CLOUD wins at the ideal 30 profiles with *lower*
  false_merge than the 33-profile DOT — the opposite of leniency.
- **metric-artifact — refuted the "decisive" framing.** The +5 pt figure is reid-specific; on
  "recognized" it's ~+1 pt and DOT wins m2.
- **noise-overfit — refuted the magnitude.** Every fair pairing's 95% CI crosses zero (best
  P(cloud>dot)=0.92); the matchers are *identical* for ~half the 30 speakers. The only effect
  clearing the noise floor is DOT-internal: slow EMA (0.3) vs fast (0.7) = **+19 pp pooled**.

## Recommendation
1. **First, tune DOT's EMA toward 0.3** — the only change that clears the noise floor; one line,
   zero memory cost.
2. **If tail-continuity is the priority, prefer plain CLOUD (thr~0.46, cap10), not cloud+merge.**
   Plain CLOUD matches DOT's recognized, beats it on reid at the ideal profile count with fewer
   false-merges, and avoids the per-meeting merge pass. cloud+merge buys fm=0 but at a steep
   recognized cost (79 vs 93).
3. **Before any swap, run a larger in-domain eval** (100+ speakers, same-device audio).
   VoxCeleb's harsh cross-recording variance (within-speaker cosine mean 0.49, p5 0.13 — ~40% of
   true pairs below threshold) is an **optimistic upper bound**; the CLOUD edge should shrink
   toward the measured zero on tight same-laptop data.

**Bottom line:** CLOUD is a low-risk, roughly-neutral-to-slightly-positive alternative — safe to
adopt, not proven to be an upgrade. Spend the cheap EMA win first; gate any matcher swap on a
bigger, in-domain study.

## Limits / caveats
- N=30 speakers; per-meeting cells are means of 30 binaries (~9 pp SE) — the dominant constraint.
- Single-speaker synthetic meetings; false_merge measures only cross-person bleed (no overlap).
- Python port omits production `mergeDuplicates` + `EmbeddingClusterer` post-pass; fixes ema=0.5.
- CLOUD memory/compute is ~10×/profile (up to 10 stored vectors vs DOT's 1) — a real cost not
  captured by accuracy metrics.
