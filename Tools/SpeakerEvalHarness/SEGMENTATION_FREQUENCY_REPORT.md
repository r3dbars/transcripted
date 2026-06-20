# Under- vs over-segmentation frequency + contamination drift

**Date:** 2026-06-20 · **Question (gating):** On real corpora, how often is the speaker
error **under-segmentation** (two+ distinct people fused into one cluster — the case a
within-cluster *split* would fix) vs **over-segmentation** (one voice fragmented into many
clusters — already handled by `absorbSmallClusters` / `consolidateSameVoiceClusters` /
`RetroactiveSpeakerUpdater` + the match threshold)? The big-effort unsupervised-split work
is only worth it if under-segmentation is actually common.

---

## Provenance & what could / couldn't run (read this first — no silent gaps)

This task was scoped to run **locally on a Mac** against corpora downloaded under `data/`.
It was actually executed in a **cloud Linux container** (`x86_64`, no Swift toolchain, no
Apple frameworks). Concretely, in this environment:

- **No Swift toolchain** (`swift`/`swiftc` absent) and the harness is `platforms: [.macOS("26.0")]`,
  linking CoreML / Metal / Accelerate / ScreenCaptureKit / AVFoundation and FluidAudio via
  prebuilt `deps-frameworks/*.framework`. None of that builds or runs on Linux.
- **No prebuilt deps** (`deps-libs/`, `deps-frameworks/`, `deps-modules/` all absent — they
  come from `build-deps.sh`, Apple-Silicon only).
- **No corpora and no cached dumps/RTTMs** anywhere on the box (`data/` does not exist).

So a **fresh live harness run was not possible here.** Rather than produce nothing (the prior
attempt's failure mode), this report is built from real evidence already on hand:

1. **Measured numbers from prior on-Mac harness runs**, committed in this same directory:
   `BASELINE_REPORT.md` (AMI ES2002), `SCALEUP_REPORT.md` (AMI 32-meeting scale-up +
   VoxCeleb addendum), `AB_DOT_VS_CLOUD.md` (matcher A/B). Every per-corpus number below is
   traceable to one of those, produced by the app's own diarizer + WeSpeaker embeddings.
2. **Source-of-truth code reads** for the metric definitions and the EMA write-back constant
   (cited inline).
3. **A new computed artifact** — `contamination_drift_sim.py` (added in this change) — a
   pure-Python simulation of the production EMA write-back using the **exact `alpha = 0.15`**
   and the **measured cosine bands**. It ran here (Python 3.11, stdlib only) and its numbers
   are reproduced in §4.

| Corpus | Tier | Ran? | Where the numbers come from |
|---|---|---|---|
| **AMI ES2002** (4 mtg, 4 ids, in-room) | baseline | prior Mac run | `BASELINE_REPORT.md` |
| **AMI scale-up** (32 mtg, 32 ids, in-room) | scale | prior Mac run | `SCALEUP_REPORT.md` |
| **VoxCeleb mini** (30 ids, 300 single-spk meetings, cross-recording) | matcher-isolated | prior Mac run | `SCALEUP_REPORT.md` addendum, `AB_DOT_VS_CLOUD.md` |
| **VoxConverse** (in-the-wild, overlap/codec) | gated | **NO** | wired (`scripts/download_voxconverse.sh`) but never run; not in any committed report. Couldn't run here: no Mac/Swift/corpora; downloader is the over-seg regime we'd most want, but it needs ~30–90 min Apple-Silicon diarize compute on data not present. |
| **ICSI** (recurring lab speakers) | gated | **NO** | wired (`scripts/download_icsi.sh`); RTTMs are HF-gated (`diarizers-community/icsi`). Couldn't run here. |
| **AMI full** (~170 mtg) | gated | **NO** | only the `scale` tier (32 mtg) was ever run. |

**Bottom line on coverage:** the under/over split is grounded on **two real in-room
multi-party runs (AMI ×2)** and **one matcher-isolated cross-recording run (VoxCeleb)**.
The in-the-wild corpus (VoxConverse) — the one that would most directly stress the
over-segmentation regime with real codecs and overlap — **was not run** and is the single
biggest gap. Treat the verdict as decisive for the *in-room multi-party* regime and
*directional* for in-the-wild.

---

## Definitions (so the two directions are unambiguous)

From the harness scorer (`scripts/score_speaker_eval.py`) and the in-app simulation runner
(`SpeakerNamingSimulationRunner.swift`):

- **Under-segmentation proxy = false-merge.** Scorer: a DB profile whose mass spans ≥2
  distinct true speakers (≥10% each). Runner `falseMergeIndicators` (line 1339): one *actual*
  label maps to >1 expected label **and** >1 truth speaker. This is exactly "two+ people fused
  into one cluster" — the case a within-cluster split would fix.
- **Over-segmentation proxy = fragmentation / false-split.** Scorer: distinct DB profiles
  each holding ≥10% of one person's speech (`fragmentation`, mean profiles/person). Runner
  `falseSplitIndicators` (line 1354) + `duplicateIdentityIndicators`: one truth speaker spread
  across >1 actual label / profile. Already addressed by `consolidateSameVoiceClusters`,
  `absorbSmallClusters`, `RetroactiveSpeakerUpdater`, and the cross-meeting match threshold.
- **DER split** (`pyannote.metrics`, collar 0.25s, overlap not skipped): **confusion** =
  speech assigned to the wrong speaker after optimal label mapping — the within-meeting
  signature of *under*-segmentation (fused clusters). **miss** = speech not detected. **FA** =
  false alarm. High confusion / low miss ⇒ the diarizer is fusing people, not dropping speech.

---

## 1. Per-corpus: under- vs over-segmentation (actual numbers)

| Corpus | DER (mean) | confusion | miss | conf/miss | false-merge (under-seg) | fragmentation (over-seg) | Dominant error |
|---|---|---|---|---|---|---|---|
| **AMI ES2002** (4 mtg, 4 ids) | 0.404 | **0.264** | 0.102 | **2.6×** | **3** profiles fuse ≥2 people (1 fuses 3) | 1.75 profiles/person (max 2) | **UNDER-seg** |
| **AMI scale-up** (32 mtg, 32 ids) | 0.437 | **0.298** | 0.104 | **2.9×** | **22** (11 fuse 2 people, 9 fuse 3, 2 fuse 4) | 1.59 profiles/person | **UNDER-seg** |
| **VoxCeleb mini** (30 ids, matcher-isolated) | 0.101 | low¹ | — | — | 6 (flat 5–6 to thr 0.70) | **53 profiles for 30 people ≈ 1.8/person**, re-ID #2+ = 0.29 | **OVER-seg** |

¹ VoxCeleb runs `--mode singles` (one clean speaker per clip): the diarizer trivially emits
**1 cluster in 278/300 meetings (DER 0.10)**, so there is no diarizer-level under-segmentation
by construction. Its dominant error is matcher fragmentation, not confusion.

### How to read this

- **When a real diarizer runs on multi-party audio (AMI), under-segmentation dominates,
  decisively.** Confusion is ~2.6–2.9× miss; false-merge outnumbers any fragmentation signal
  by an order of magnitude; and **22 of 32 meetings (69%) emit fewer clusters than there are
  people** (cluster-count histogram: 2→8 mtgs, 3→14, 4→5, 5→4, 6→1). Critically, the fusion
  happens **inside a single diarized cluster before the matcher ever runs** — e.g. ES2002b
  cluster 1 = MEE008 43% + MEE006 38% + MEE007 11%. That is precisely the within-cluster-split
  target.
- **When the diarizer is taken out of the loop (VoxCeleb singles), the picture inverts:**
  the matcher's failure is over-segmentation — 30 real people explode into 53 profiles at the
  production match 0.60, and a returning speaker is re-identified to their original profile only
  29% of the time. But this is the regime the existing consolidation/absorb/retroactive
  machinery + match-threshold tuning already target — *not* the within-cluster-split case.

So under-segmentation **is** common — but specifically as a **diarizer** failure on
multi-party audio, not a matcher failure. That distinction drives the verdict.

---

## 2. The DER confusion-vs-miss split (the headline under-seg signal)

| Corpus | confusion | miss | false-alarm | confusion share of DER |
|---|---|---|---|---|
| AMI ES2002 | 0.264 | 0.102 | 0.038 | ~65% |
| AMI scale-up (32) | 0.298 | 0.104 | ~0.035 | ~68% |
| VoxCeleb (singles) | ~0 | — | — | DER 0.10, fragmentation-dominated |

Per-meeting AMI ES2002: confusion climbs to **0.34–0.37** on the three meetings that emit only
3 clusters for 4 people, while miss stays flat at 0.08–0.13. **Confusion tracks the
under-segmented meetings one-for-one.** This is the cleanest single number in the report:
on real in-room multi-party audio the dominant error term is speaker *confusion* (fusion),
not missed speech.

---

## 3. Why "common" doesn't automatically mean "worth building the split"

Two measurements from the same prior runs temper the frequency result:

**(a) The embeddings barely separate the fused speakers — worst exactly where it matters.**
Mean-embedding cosine bands (`BASELINE_REPORT.md` §4):

| audio | same-speaker pairs | different-speaker pairs | overlap? |
|---|---|---|---|
| AMI clean (headset) | 0.21–0.72, mean **0.53** | 0.13–0.60, mean **0.33** | heavy (0.21–0.60) |
| AMI VoIP (Opus 12k) | 0.21–0.54, mean **0.39** | −0.01–0.66, mean **0.36** | **bands collapse** (0.39 vs 0.36) |

An unsupervised within-cluster split must cut a single fused cluster into its constituent
people using embedding separation. On clean audio the same- and different-speaker bands
already overlap; on **compressed/remote audio — the regime where the production "one cluster,
many people" bug is actually reported — they collapse onto each other.** There is no clean
threshold to split on precisely where under-seg is worst. The empirical canary: the BASELINE
consolidation sweep showed that pushing the *merge* knob into its firing band to fix
over-seg **regressed DER by +0.25** because it fused distinct speakers — the space is not
cleanly separable, and a *split* operating on the same space carries the symmetric risk of
fragmenting one person into two.

**(b) The root cause is upstream and cheaper.** The diarizer config (`clusteringThreshold:
0.6`) was grid-searched on **2-party Zoom**. The AMI under-seg is the predictable result of
running a 2-party-tuned diarizer on **4-party in-room** audio. The highest-leverage fix is the
diarizer/clustering config for the actual party-count, not a downstream within-cluster split.
And AMI's 4-party in-room almost certainly **overstates** what Transcripted sees — its real
domain is 1–2 party same-laptop calls (the A/B notes Transcripted audio is "more consistent
than VoxCeleb, less than AMI single-session series").

---

## 4. Bonus — write-time contamination gate (roadmap #6)

Production write-back, on every cross-meeting match (`SpeakerDatabase.swift:252`):

```
alpha = 0.15                                  // "slow adaptation, preserves identity"
v' = l2normalize( 0.85 * v_old + 0.15 * e_new )   // fixed-weight EMA, not a 1/n running mean
```

`contamination_drift_sim.py` runs the **exact** rule on 256-dim unit vectors, with the
between/within cosine bands set to the measured values (within 0.50, between 0.33 clean / 0.36
VoIP), 400 trials, seeded. Results (reproduced verbatim from the run in this environment):

**Single-write drift (closed form) — how far the voiceprint moves per write:**

| incoming sample cosine to voiceprint | cos(v, v') | drift angle |
|---|---|---|
| 1.00 | 1.0000 | 0.00° |
| 0.70 | 0.9938 | 6.40° |
| 0.60 (at match threshold) | 0.9919 | 7.28° |
| 0.50 | 0.9903 | 7.99° |
| 0.30 | 0.9875 | 9.08° |

α=0.15 is genuinely conservative: even a worst-case threshold-margin write only nudges the
stored vector ~7°. **A single bad write does little damage.**

**Cumulative drift after 10 writes (clean headset between=0.33; VoIP nearly identical):**

| stream | cos(v, A_true) | cos(v, B) | margin A−B |
|---|---|---|---|
| clean (all correct A) | 0.840 | 0.279 | **+0.561** |
| low-margin but *correct* (all A near 0.6) | 0.887 | 0.293 | **+0.594** |
| under-seg 1-in-3 (B fused in) | 0.771 | 0.475 | +0.296 |
| under-seg 1-in-2 (B fused in) | 0.717 | 0.570 | +0.146 |
| under-seg every write (B) | 0.495 | 0.800 | **−0.305 (flipped to B)** |

**Runaway:** consecutive wrong-person (under-segmented) absorptions flip the profile's nearest
identity from A to B in a **median of 5 writes** (mean 4.9, min 1, max 7; 400/400 flip within
cap), clean and VoIP alike.

**What this says:**

1. **Low margin alone is NOT contamination.** A correct-but-near-threshold stream actually
   *holds* its margin (+0.59). The voiceprint converges to the true centroid regardless of
   margin, as long as the matches are the right person.
2. **Wrong-person absorption IS contamination, and α=0.15 does not stop it.** Absorbing a
   fused/different person on just 1-in-3 writes nearly halves the margin (+0.56 → +0.30); a
   persistent fused match converts the profile to the wrong identity in ~5 meetings.
3. **Therefore the write-time gate should key on *which person*, not on absolute score** — i.e.
   margin to the second-best profile / cluster purity, not just `cosine ≥ 0.6`. This is a small,
   low-risk change that directly limits exactly the under-seg damage, without the split's
   regression risk. It is the cheaper sibling of the unsupervised split and addresses the same
   harm.

(Independent corroboration: `AB_DOT_VS_CLOUD.md` found the one statistically-robust matcher
lever — CI clears zero — is **slowing the EMA further (0.3 → +19pp re-ID)**; "EMA blending lets
duplicate badges drift and win the nearest-match." Same mechanism this sim quantifies.)

---

## VERDICT

**Is under-segmentation common?** Yes, on real multi-party in-room audio it is the *dominant*
error — 69% of AMI meetings under-segment, confusion is ~2.9× miss, false-merge outnumbers
fragmentation ~14:1, and the fusion lives inside a single diarized cluster (the split target).
So the literal frequency gate **passes** for that regime.

**Is the big-effort unsupervised within-cluster split worth the large / regression-risky
build right now?** **No — not yet. Defer it.** (Overall confidence: **YELLOW** — no fresh live
run was possible here, the in-the-wild corpus didn't run, and the verdict rests on prior
on-Mac artifacts plus the new drift sim.)

Frequency is necessary but not sufficient; "worth it" also needs feasibility and ROI, and both
argue against starting now:

1. **Feasibility is marginal exactly where under-seg is worst.** Same- vs different-speaker
   embedding bands overlap on clean audio and *collapse* on compressed/remote audio (0.39 vs
   0.36) — the regime where the "one cluster, many people" bug is reported. An unsupervised
   split has no clean signal to cut on there, and the +0.25 DER regression from forcing the
   merge knob shows the symmetric split risk (fragmenting one person) is real.
2. **The root cause is a cheaper upstream fix.** The under-seg is largely a 2-party-tuned
   diarizer config meeting 4-party in-room audio. Re-tuning the diarizer/clustering for the
   target party-count is higher-leverage than a downstream split. AMI also likely overstates
   under-seg vs Transcripted's 1–2 party same-laptop reality.
3. **Two cheap, lower-risk levers hit the same damage first:** (a) the write-time contamination
   gate (margin-to-2nd-best, §4) directly limits under-seg's profile-poisoning, and (b)
   EMA → 0.3 (the only A/B lever that clears the noise floor, +19pp, one line).

**Gate the split build behind two preconditions:** (1) confirm under-seg frequency holds on
**in-domain** (1–2 party, same-laptop / Zoom-like) labeled audio — AMI's 4-party in-room may
not represent the product; and (2) a **separability probe** showing within-cluster speaker
embeddings actually separate on that audio. The harness already supports both: drop the WAVs
in, `dump`, sweep. The missing **VoxConverse** run is the cheapest immediate step to test the
in-the-wild over-seg regime and would also stress whether the split has signal to work with.
If under-seg stays common in-domain **and** the embeddings separate, build it; today the
evidence says spend the cheap levers first.

---

## Reproduce

```bash
# contamination-drift sim (runs anywhere, pure stdlib Python):
python3 Tools/SpeakerEvalHarness/contamination_drift_sim.py

# full corpus runs (require macOS + Apple Silicon + build-deps + downloaded corpora):
bash build-deps.sh
bash scripts/download_ami.sh scale && CORPUS=ami \
  CONSOLIDATION="none 0.85 0.88 0.91" MATCH="0.55 0.60 0.65" scripts/run_speaker_eval.sh
bash scripts/download_voxceleb_sample.sh && CORPUS=voxceleb \
  MATCH="0.45 0.50 0.55 0.60 0.65 0.70 0.75" scripts/run_speaker_eval.sh
# not yet run — the highest-value next step (in-the-wild over-seg regime):
bash scripts/download_voxconverse.sh && CORPUS=voxconverse scripts/run_speaker_eval.sh
```

## Limitations

- **No fresh live run** in this environment (cloud Linux, no Swift/Apple frameworks/corpora);
  corpus numbers are from prior committed on-Mac runs, re-interpreted through the under/over
  lens. They were not re-generated here.
- **VoxConverse and ICSI did not run** — the in-the-wild and second meeting-domain surfaces are
  gaps. VoxConverse is the most important missing data point.
- AMI is 4-party in-room and likely **overstates** under-seg relative to Transcripted's 1–2
  party same-laptop domain; VoxCeleb cross-recording variance likely **overstates**
  over-seg/fragmentation. The true product operating point sits between them.
- The drift sim is a synthetic high-dim model of the **exact** production EMA rule, parameterized
  by measured cosine bands — directionally faithful, not a replay of real embeddings.
