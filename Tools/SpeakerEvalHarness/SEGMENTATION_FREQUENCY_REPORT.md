# Under- vs over-segmentation frequency + write-time contamination drift

**Date:** 2026-06-20 · **Purpose:** size the LATER roadmap item *"No unsupervised
within-cluster split"* (`docs/FIX_ROADMAP.md`, PR #1227) before committing to a large,
regression-risky change. The roadmap explicitly says **quantify the merge-indicator rate
before building it** — this is that measurement. Bonus: sizes roadmap **#6** (write-time
voiceprint contamination) by measuring EMA write-back drift.

**Method:** the existing `SpeakerEvalHarness` (app's own FluidAudio PyAnnote segmentation +
256-dim WeSpeaker embeddings + VBx clustering via `TranscriptedCore.DiarizationService`,
then the real `EmbeddingClusterer.postProcess` + `SpeakerDatabase` match/learn/merge),
scored against ground-truth RTTMs by `scripts/score_speaker_eval.py`. Production config:
`consolidation = 0.88`, `match = 0.60`. All corpus data is gitignored.

The two metrics that answer the question (both already emitted by the scorer):

- **under-segmentation proxy = false-merge** — DB profiles whose mass spans ≥2 distinct true
  people (≥10% each). This is the *exact* failure `SpeakerNamingSimulationMergeIndicator`
  (`SpeakerNamingSimulationRunner.swift:140`) scores, and the *only* failure the proposed
  split would fix.
- **over-segmentation proxy = fragmentation** — distinct DB profiles each holding ≥10% of one
  person's speech (the "how many profiles must I name for one person" number). This is the
  failure the codebase already mitigates three times (`absorbSmallClusters`,
  `consolidateSameVoiceClusters`, `RetroactiveSpeakerUpdater`).

---

## TL;DR / VERDICT

**The unsupervised within-cluster split is NOT worth the large/regression-risky effort as
scoped.** Under-segmentation IS frequent — but *only* in 3+-party audio (AMI 69%, VoxConverse
67% of ≥3-spk files), where it is a **diarizer** limitation (clusters are already mixed before
the matcher runs), and 3+-party in-room/in-the-wild audio is **not** Transcripted's core
1–2-party regime. That regime is isolated two ways here — VoxConverse's ≤2-speaker files
(diarizer 77% exact) and the VoxCeleb single-voice matcher test — and in both the dominant
failure flips to the **opposite**, over-segmentation (one person → ~1.8 profiles), which the
three existing fixes already target. A cold unsupervised splitter would fire on exactly those
clean clusters and risk **re-introducing the over-segmentation those three fixes exist to
suppress**. The roadmap's own hypothesis is confirmed, with one refinement: under-seg is common
in multi-party audio but is upstream of the split (diarizer-bound) and out of the core domain.

| Corpus | Regime | under-seg | over-seg | DER = miss + conf | Dominant error |
|---|---|---|---|---|---|
| **AMI** (in-room, 4-party) | diarizer stress | **22 / 32 mtgs** false-merge (11 span 2 ppl, 9 span 3, 2 span 4) | 1.59 / person frag (≈ideal 1.0) | 0.437 = .105 + **.298** | **UNDER** (diarizer-bound) |
| **VoxConverse** (in-the-wild, 216) | diarizer stress | **50% of files** under-segment; **67% of ≥3-spk files** | 5% of files over-segment | 0.201 = .046 + **.125** | **UNDER** (diarizer-bound, multi-party only) |
| ↳ VoxConverse **≤2-spk files** (66) | the product's regime | 9 / 66 (14%) | 6 / 66 (9%) — **77% exact** | — | diarizer mostly **correct** |
| **VoxCeleb** (singles, 1 clean voice) | matcher isolation | **6** false-merge (low) | **2.23 / person** → 30 ppl = **53 profiles** | 0.111 = .088 + .023 | **OVER** (matcher-bound) |

**Net:** under-seg frequency is high only where the diarizer is fed 3+ simultaneous people
(AMI 69%, VoxConverse 67% of ≥3-spk files). In the product's actual 1–2-party regime —
isolated two ways: VoxConverse ≤2-spk files (77% exact) and the VoxCeleb single-voice matcher
test — under-seg is rare and the dominant error flips to over-segmentation. The split bet loses.

---

## 1. AMI — in-room 4-party (32 meetings, 32 recurring identities, 15.85 h)

`bash scripts/download_ami.sh scale && CORPUS=ami CONSOLIDATION="none 0.88" MATCH="0.55 0.60 0.65" scripts/run_speaker_eval.sh`

At production `consolidation 0.88 / match 0.60`:

- **DER 0.4373 = miss 0.1045 + false-alarm 0.0344 + confusion 0.2984.** Confusion is **68.2%**
  of DER; miss is 23.9%. High confusion is the within-meeting speaker-mixing signature.
- **Cluster count vs truth (truth = 4 every meeting):** hyp-cluster distribution
  `{2: 8, 3: 14, 4: 5, 5: 4, 6: 1}` → **22 of 32 meetings (69%) under-segment** (fewer clusters
  than people), 5 exact, 5 over-segment.
- **under-seg (false-merge) = 22** profiles span ≥2 distinct people: **11 span 2, 9 span 3,
  2 span 4**. The diarizer hands back 2–3 clusters for 4 people, so each cluster already mixes
  identities *before the matcher runs* — the false-merge tracks the under-segmented meetings,
  not the match threshold.
- **over-seg (fragmentation) = 1.59 profiles/person** (max 3) — near the ideal 1.0.
- The `0.88` consolidation knob is **inert** (identical metrics to `none` at every match) —
  same-voice cluster similarities top out far below 0.88 on this audio (see BASELINE_REPORT §4).

**Reading:** AMI is dominated by under-segmentation, and it is **diarizer-bound** — the
FluidAudio PyAnnote+VBx diarizer was grid-searched on 2-party Zoom and collapses 4-party
in-room voices. This is the regime the proposed split targets, but the fix it implies is
upstream (better segmentation/config), not a downstream re-split working on already-contaminated
cluster means.

## 2. VoxCeleb — matcher isolation (30 identities × 10 clips = 300 single-speaker meetings)

`VOXCELEB_IDENTITY_CAP=30 VOXCELEB_CLIPS_PER_ID=10 VOXCELEB_MODE=singles scripts/download_voxceleb_sample.sh && CORPUS=voxceleb CONSOLIDATION=0.88 MATCH="0.50 0.60 0.70" scripts/run_speaker_eval.sh`

One clean voice per clip → the diarizer trivially sees one speaker (**279 / 300 meetings = exactly
1 cluster**, 0 under-segment, 21 mildly over-segment), so the metric isolates the **DB matcher's
cross-recording behavior**. At production `match 0.60`:

- **under-seg (false-merge) = 6** (low, and flat 5–6 up to match 0.70).
- **over-seg (fragmentation) = 2.23 profiles/person** → **30 real people explode into 53
  profiles** (≈1.8×). Raising match makes it far worse (0.70 → 118 profiles for 30 people).
- **DER 0.111 = miss 0.088 + confusion 0.023** — confusion is only 21%; the residual is VAD
  miss on short clips, not segmentation error. The diarizer is *out of the way* here by design.

**Reading:** with the diarizer removed, the matcher's dominant failure is **over-segmentation /
weak cross-recording re-ID** — the same person in a different recording lands below the 0.60
match floor and is filed as a new profile. This is the documented, three-times-mitigated failure
mode, and it is the mode the proposed *split* does **not** help (a split makes more clusters, not
fewer). Caveat: VoxCeleb's celebrity-audio-across-decades is harsher than typical Transcripted
usage, so this overstates absolute fragmentation — read the **direction**, not the exact count.

## 3. VoxConverse — in-the-wild YouTube (dev split, 216 files, diarized)

`VOXCONVERSE_SPLITS=dev scripts/download_voxconverse.sh && CORPUS=voxconverse CONSOLIDATION=0.88 MATCH=0.60 scripts/run_speaker_eval.sh`

Ground truth: 216 dev files, **mean 4.5 speakers/file, median 4, max 20**; speaker-count
distribution `{1:22, 2:44, 3:35, 4:24, 5:31, 6:17, 7:12, 8:11, 9:4, 10:6, 11:3, 12:3, 15:2, 17:1, 20:1}`
→ **1-spk 10% · 2-spk 20% · 3+-spk 69%.** This is the in-the-wild over/under tiebreaker, and it
splits cleanly by party size.

**Important scoping caveat (handled, not ignored):** VoxConverse RTTM speaker labels are
**per-file local** (`spk00`, `spk01`, …) and there is **no cross-file identity** (each file is a
different YouTube video). So the harness's *cross-meeting* metrics — `false_merge` (188),
`profiles_end` (448), re-ID (0.0) — are **artifacts of label collision** (the scorer buckets every
file's `spk00` into one global "person") and are **not used here**. The valid, per-file metrics are
**per-meeting DER** (optimal local label mapping) and the **per-file cluster deficit**
(hyp clusters vs true speakers) — which is exactly the *within-meeting* under-/over-segmentation
this question is about.

At production `consolidation 0.88 / match 0.60`:

- **DER 0.2012 = miss 0.0458 + false-alarm 0.0306 + confusion 0.1248** — confusion is **62%** of
  DER, the within-meeting speaker-mixing signature, same shape as AMI.
- **Per-file cluster count vs truth: 109 / 216 (50%) under-segment, 97 (45%) exact, 10 (5%)
  over-segment.** Mean cluster delta −1.37 (hyp has *fewer* clusters than people). Under-seg
  outnumbers over-seg **11:1**.
- **Split by party size — the decisive cut:**
  - Files with **≥3 true speakers (150): 67% under-segment** — matches AMI's 69%. The diarizer
    collapses simultaneous voices whenever there are 3+.
  - Files with **≤2 true speakers (66): 77% exact (51), 14% under (9), 9% over (6).** In the
    1–2-party regime — *Transcripted's actual domain* — the diarizer is mostly correct and under-
    vs over-segmentation are both rare and roughly balanced.

**Reading:** real in-the-wild audio confirms the thesis directly and within a single corpus:
catastrophic under-segmentation is a **3+-party / diarizer phenomenon**; in the 1–2-party regime it
mostly doesn't happen. The split's target failure is concentrated exactly where Transcripted
usually isn't.

## 4. Write-time contamination drift (sizes roadmap #6)

`python3 scripts/contamination_drift.py --dumps data/eval/ami/dumps --rttm-dir data/ami/rttm`

`SpeakerDatabase.addOrUpdateSpeaker` (`SpeakerDatabase.swift:250-262`) blends **every** accepted
match into the persisted voiceprint with a fixed EMA and **no write-time quality/margin gate**:
`blended = old*0.85 + new*0.15`, then L2-normalize. This sim replays that exact write-back on the
real AMI WeSpeaker cluster embeddings and measures how far the stored voiceprint drifts when a
profile absorbs a **clean** match (another high-purity cluster of the same person) vs a
**contaminated / under-segmented** match (a cluster dominated by the person but carrying ≥20% of
someone else — roadmap #6's "0.70 match from an under-segmented cluster").

Drift = cosine distance (1−cos) between the voiceprint before and after the blend. Anchor:
**inter-person baseline = 0.765** mean cosine distance between two different real speakers'
clean centroids (378 pairs) — so drift can be read as a fraction of the gap to a *different
identity*.

| | clean write | contaminated write |
|---|---|---|
| per-write drift (mean) | **0.0027** (0.35% of inter-person gap) | **0.0079** (1.03% of gap) — **2.9× larger** |
| moved *toward* the contaminant identity / write | — | **+0.042** cosine (median 0.041, max 0.121) |
| cumulative drift after absorbing all eligible clusters | **0.0002** (washes out) | **0.018** mean, **0.105** worst-case (≈14% of the inter-person gap) |

(123 clusters, 28 people with a clean centroid; 67 clean vs 28 contaminated write samples.)

**Reading:** the drift is **real and directional** — a single contaminated blend pulls the
voiceprint ~0.042 cosine *toward the very identity it is being confused with*, ~3× the benign
drift of a clean blend, and clean blends essentially wash out (0.0002) while contaminated ones
accumulate (worst-case 0.105). It is also **bounded**: per-write ~1% of the inter-person gap, and
the matcher already rejects immature/ambiguous matches upstream, so this only fires on accepted
low-margin matches. This matches the roadmap's own "narrower than every match, but real" framing.

**Implication for the split decision:** #6 is the *cheaper, lower-risk* lever that addresses the
**consequence** of under-segmented matches (contaminated write-back) directly — a write-time
margin/quality gate at `SpeakerDatabase.swift:250` — without the regression risk of a cold
splitter. It should be done before, and likely instead of, the split.

## 5. Why the split is regression-risky (architecture)

- The **only** existing splitter, `EmbeddingClusterer.dbInformedSplit`
  (`EmbeddingClusterer.swift:457`), **requires `!profiles.isEmpty`** and only splits a cluster
  when **≥2 already-enrolled DB profiles** each match ≥8 of its segments (`:463`, `:507`). So
  under-segmentation is recoverable today **only when both speakers are pre-enrolled.**
- The proposed *unsupervised* split would fire **cold** (no enrolled profiles — the gap
  `dbInformedSplit` leaves). Firing cold means deciding, with no identity prior, whether a single
  cluster is one voice or two — on exactly the clean single-voice clusters that dominate the
  product's 1–2-party regime.
- A cold splitter that mis-fires **shatters a clean cluster into two**, i.e. it manufactures the
  **over-segmentation** that `absorbSmallClusters`, `consolidateSameVoiceClusters`, and
  `RetroactiveSpeakerUpdater` were written to suppress. The split is therefore not just Effort-L;
  it is **adversarial to three shipping mitigations** — every false split it makes is work those
  three then have to undo, and the measured common-case error is already over-segmentation.

## 6. Recommendation

1. **Do not build the unsupervised within-cluster split as scoped.** Its target failure
   (under-seg) is frequent only in 3+-party audio that is (a) outside the core 1–2-party regime
   and (b) diarizer-bound — upstream of where the split operates. In the core regime the dominant
   error is the opposite (over-seg), which a cold split would worsen.
2. **Ship roadmap #6 first** — a write-time margin/quality gate at `SpeakerDatabase.swift:250`.
   It is cheap, low-risk, and directly caps the measured contamination drift (the real harm of an
   under-segmented match) without touching cluster counts.
3. **If under-seg ever becomes a core target** (e.g. Transcripted moves into in-room multi-party
   capture), extend the **enrollment-gated** `dbInformedSplit` (low regression risk) and/or
   revisit the diarizer segmentation config for 3+-party audio — both attack the cause (diarizer
   under-segmentation) rather than re-splitting contaminated downstream cluster means.

---

## Reproduce

```bash
bash build-deps.sh
bash scripts/download_ami.sh scale
CORPUS=ami CONSOLIDATION="none 0.88" MATCH="0.55 0.60 0.65" scripts/run_speaker_eval.sh

VOXCELEB_IDENTITY_CAP=30 VOXCELEB_CLIPS_PER_ID=10 VOXCELEB_MODE=singles scripts/download_voxceleb_sample.sh
CORPUS=voxceleb CONSOLIDATION=0.88 MATCH="0.50 0.60 0.70" scripts/run_speaker_eval.sh

VOXCONVERSE_SPLITS=dev scripts/download_voxconverse.sh    # ~1.9 GB, slow KAIST mirror
CORPUS=voxconverse scripts/run_speaker_eval.sh

python3 scripts/contamination_drift.py --dumps data/eval/ami/dumps --rttm-dir data/ami/rttm
```

Per-meeting DER confusion/miss splits are in the gitignored
`data/eval/<corpus>/reports/cons_*_match_*.json`; the sweep tables are in each corpus's
`reports/SWEEP.md`. Corpus audio/RTTMs/dumps are gitignored and never committed.
