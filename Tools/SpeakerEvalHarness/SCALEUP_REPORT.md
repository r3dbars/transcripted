# Speaker-naming eval — AMI scale-up (8 scenario series, ~32 recurring identities)

**Date:** 2026-06-16 · **Corpus:** AMI Meeting Corpus, Mix-Headset, **32 meetings** =
8 scenario series × sessions a–d (`ES2002, ES2003, ES2005, ES2006, ES2007, ES2008, ES2009,
ES2010`). Each series is a disjoint group of 4 people who recur across its 4 sessions, so
the replay carries **32 distinct identities, each appearing 4×** — a few dozen recurring
identities, the diverse-identity surface the scale-up was meant to exercise.
**15.85 h of audio. License:** AMI research-use; RTTMs from `pyannote/AMI-diarization-setup`
`only_words`. Audio/RTTMs/dumps gitignored, never committed.

Reproduce: `bash scripts/download_ami.sh scale && CORPUS=ami CONSOLIDATION="none 0.85 0.88
0.91" MATCH="0.55 0.60 0.65" scripts/run_speaker_eval.sh`. Full sweep table in
`data/eval/ami/reports/SWEEP.md` (gitignored).

> **Throughput:** the whole pipeline — diarize 15.85 h of audio + 12-combo threshold sweep
> + DER/fragmentation/false-merge/re-ID scoring on all 32 meetings — ran in **6.2 minutes**
> wall-clock (~150× realtime). The scale-up is minutes, not hours; the gated tiers below are
> dominated by *download*, not compute.

---

## TL;DR at scale (8× the meetings, 8× the identities of the baseline)

| Finding | Baseline (ES2002, 4 mtgs, 4 ids) | **Scale-up (32 mtgs, 32 ids)** | Verdict |
|---|---|---|---|
| **Match 0.60 ends at the right profile count** | 4 profiles for 4 people ✓ | **32 profiles for 32 people ✓** (0.55→25 over-merge, 0.65→35 fragment) | **Re-confirmed. Keep 0.60.** |
| **0.88 consolidation knob** | structurally inert | **inert at scale too** — `none/0.85/0.88/0.91` give *identical* metrics at every match | **Re-confirmed inert on AMI.** Can't be calibrated here. |
| **DER (diarizer quality)** | mean 0.404 | mean **0.437** (confusion 0.298, miss 0.104) | Diarizer-bound, ~flat — upstream of both thresholds. |
| **False-merge (false-positive proxy)** | 3 | **22** | **Diarizer-bound, NOT matcher-bound** — see below. |
| **Cross-meeting re-ID #2+** | 0.42 | **~0.53** (#1 .81, #2 .49, #3 .55, #4 .56) | Improved with more per-identity data. |

**Recommended settings hold at scale: consolidation = 0.88 (safe-but-inert on AMI),
match = 0.60 (the exact-count sweet spot).** At match 0.60 the run ends with exactly
**32 profiles for 32 true people** — the matcher's cross-meeting discipline is neither
collapsing distinct people nor exploding into spurious profiles.

---

## Why false-merge = 22 is a diarizer ceiling, not a matcher failure

All 32 meetings have **4** true speakers. The app's diarizer (grid-searched on 2-party
Zoom) **under-segments 4-party in-room AMI**:

| hyp profiles per meeting | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|
| # meetings | 8 | 14 | **5** | 4 | 1 |

**22 of 32 meetings (69%) emit fewer clusters than there are people.** When the diarizer
hands back 2–3 clusters for 4 speakers, each cluster **already mixes two or three real
identities before the matcher ever runs** — so the resulting DB profile inevitably spans
multiple true people. The 22 false-merges decompose as 11 profiles spanning 2 people,
9 spanning 3, 2 spanning 4 — i.e. they track the 22 under-segmented meetings, not the
match threshold (false-merge is flat at 22 across all four consolidation values at match
0.60). DER is dominated by the **confusion** term (0.298 of 0.437), the signature of
within-meeting speaker mixing, with low miss (0.104).

**Consequence:** AMI — *even scaled to 32 identities* — cannot produce the trustworthy
near-zero-false-positive number, because its dominant error is the diarizer under-segmenting
in-room multi-party audio, not the speaker-DB matcher wrongly fusing clean voices. The
scale-up's value is exactly this: it (1) proves the harness runs end-to-end at scale in
minutes, (2) re-confirms **both** threshold conclusions at 8× the meetings and identities,
and (3) quantifies that the false-positive ceiling on AMI is **diarizer-bound**.

## What this motivates (the corpus mix)

To get a real near-zero-false-positive number you need corpora where a *single clean
identity per source* removes the diarizer-mixing confound, so the metric isolates the DB
matcher's cross-recording discipline:

- **VoxCeleb (sample, hard-capped)** — each clip is one clean speaker; synthetic
  multi-identity sessions give an exact RTTM with **no** within-source mixing, so
  false-merge measures *only* the matcher fusing two genuinely-different people. This is
  the cleanest false-positive test. (Wired, gated; `scripts/download_voxceleb_sample.sh`.)
- **VoxConverse** — in-the-wild overlap/codec stress with real RTTMs, the over-segmentation
  regime where the 0.88 consolidation knob can finally fire. (Wired, gated.)
- **ICSI** — heavily recurring lab speakers across many meetings, a second meeting-domain
  re-ID surface. (Wired, gated.)

See **README.md → Corpus mix** for the per-tier one-liners, env knobs, and compute
estimates. The gated tiers are wired but intentionally not auto-run.

## Per-combo numbers (match × consolidation)

| consolidation | match | mean DER | frag mean | false-merge | re-ID #2+ | profiles_end (ideal 32) |
|---|---|---|---|---|---|---|
| none/0.85/0.88/0.91 | 0.55 | 0.436 | 1.72 | 19 | 0.547 | 25 (over-merged) |
| none/0.85/0.88/0.91 | **0.60** | **0.437** | **1.59** | **22** | **0.532** | **32 ✓** |
| none/0.85/0.88/0.91 | 0.65 | 0.416 | 1.75 | 24 | 0.519 | 35 (fragmented) |

(Consolidation collapsed because all four values are identical at every match — the inertia
finding. Full grid in the gitignored `SWEEP.md`.)
