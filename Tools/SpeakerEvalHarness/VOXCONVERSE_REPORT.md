# Speaker-naming eval — VoxConverse (in-the-wild YouTube, real RTTMs)

**Date:** 2026-06-16 · **Corpus:** VoxConverse **dev**, 216 files, 19.65 h speech (~20.0 h span),
mean **4.50 speakers/file** (range 1–20), **972 distinct true speakers**, measured overlap **3.60 %**
of speech (per-file mean 3.45 %, max 26.1 %; 158/216 files have some overlap), 22 single-speaker files (10 %).
**License:** VoxConverse, CC-BY 4.0 (VGG/Oxford); ground-truth RTTMs from `joonson/voxconverse`. Audio/RTTMs/dumps gitignored.
**Config under test:** `TranscriptedCore.DiarizationService.diarizeOffline` (PyAnnote seg + VBx + 256-dim WeSpeaker);
within-meeting consolidation knob = `EmbeddingClusterer.postProcess(pairwiseMergeThreshold:)`; cross-meeting
match = `SpeakerDatabase.matchSpeaker(threshold:)`. Grid: **consolidation {none, 0.88} × match {0.45, 0.50, 0.55, 0.60, 0.65}** (10 combos), DER collar 0.25 s.

> **Measured vs assumed.** Every number in §§1–5 is **measured** by the harness on real VoxConverse dev
> audio (216/216 files diarized, zero skips). Claims about *codec/telephone* compression and the
> AMI-VoIP band are **inferred** from the prior AMI reports + literature and are labelled *(inferred)* —
> VoxConverse itself is **not** codec-compressed, so it cannot measure that regime.

> **Scoring-correctness fix (required for honest numbers).** VoxConverse RTTM labels (`spk00, spk01, …`)
> are **per-file** and reused across all 216 files — every file's `spk00` is a different person. The scorer
> was built for AMI's globally-recurring participant ids (`FEE005`). Run unmodified, it would conflate
> 216 different people into one "speaker," set the ideal profile count to ~20 instead of 972, **mis-report
> false-merge as near-zero**, and recommend the *lowest* threshold — the exact opposite, wrong conclusion.
> Fixed with an opt-in `--per-file-ids` flag (`score_speaker_eval.py`) that namespaces true ids by file;
> the runner enables it for `CORPUS=voxconverse` only. **AMI/VoxCeleb scoring is byte-identical** (validated:
> same `true_speakers`, same DER). This is measurement tooling — no app behavior changed.

> **Throughput:** 216 files diarized in ~10 min (~115× realtime, Apple Silicon, models cached) + 10
> replay/score combos in <2 min. Whole eval < 15 min after the (download-dominated, ~2 GB) dev fetch.

---

## TL;DR — does in-the-wild audio over-segment and pull the match threshold down toward 0.50?

**No — both halves of the hypothesis are unsupported on VoxConverse, for a concrete measured reason: VoxConverse is in-the-wild but *not* codec-compressed (16 kHz, 93 % speech, 3.6 % overlap), so its embedding bands stay clean and well-separated and its diarizer UNDER-segments, exactly like AMI.**

| Question | AMI (clean in-room) | **VoxConverse (this report)** | Verdict |
|---|---|---|---|
| Optimal match threshold | **0.60** (lowest that hits exact count without losing re-ID) | aggregator prefers **0.65** (high end); choice nearly inconsequential | **does NOT drop toward 0.50** |
| Does the diarizer over- or under-segment? | under (69 % of mtgs < true) | **UNDER** — 108/216 (50 %) below true, only **11 (5 %) over**; mean **0.81 clusters/true** | generalizes (under, not the "1→9" over-split) |
| 0.88 consolidation knob | inert (band tops 0.72 clean / 0.54 VoIP) | **INERT** (none ≡ 0.88, identical to 4 dp) — but because under-seg leaves no same-voice cluster *pairs* to merge | inert here too, different cause |
| Mean DER (confusion share) | 0.437 (confusion 0.298 = 68 %) | **0.201** (confusion 0.125 = **62 %**) | confusion-dominated, but **cleaner** than AMI |
| False-merge source | diarizer-bound (22, flat across thresholds) | **189 @ 0.60 → 61 % within-file (diarizer) / 39 % cross-file (matcher)** | diarizer is the larger share; matcher non-negligible |
| Cross-meeting re-ID | measurable (0.53 @ #2+) | **N/A by construction** — no recurring identities across files | VoxConverse can't calibrate the re-ID/threshold tradeoff |

**Headline.** The prior named VoxConverse as *"the over-segmentation regime where the 0.88 knob can finally
fire."* **Measurement refutes that:** VoxConverse under-segments (0.81 clusters/true), so 0.88 stays inert and
the optimal match does not move down. The "diarizer is the real problem" finding **generalizes** beyond AMI's
clean 4-party audio — as **under-segmentation driven by overlap and similar voices**, not the user's `1→9`
over-split (max 3 profiles/person here). The **lower-similarity-band** regime that *would* justify ~0.50
(same-voice cosine ≈ 0.39, over-segmentation) is **AMI-VoIP codec audio** *(inferred)* — VoxConverse, being
uncompressed YouTube, does **not** replicate it. **VoxConverse is the wrong proxy for remote/compressed
Transcripted usage; it is the right proxy for "is the matcher safe in the wild" — and the answer is yes.**

**🟢 GREEN on execution + diarizer characterization · 🟡 YELLOW on the threshold question** — the run was
clean and the diarizer story is definitive, but VoxConverse structurally cannot answer "what match threshold
for compressed remote audio" (no recurring identities, uncompressed band). Next: a **recurring-identity
compressed** corpus (AMI-VoIP with re-ID, or labelled Zoom/Meet).

---

## 1. Does VoxConverse over-segment? (the gating question for the 0.88 knob)

The prior predicted over-segmentation in the wild. **It does not happen.** Raw diarizer cluster count
(from the cached dumps, pre-DB) vs ground-truth speaker count, across all 216 files:

| diarizer clusters vs true speakers | under (<) | exact (=) | over (>) |
|---|---|---|---|
| **# files (of 216)** | **108 (50 %)** | 97 (45 %) | **11 (5 %)** |

- mean **0.806 clusters per true speaker**, median 0.95, mean (clusters − true) = **−1.34** (finds ~1.3 *fewer*
  speakers than truth per file).
- This is **under-segmentation** — the same direction as AMI (where 69 % of meetings emit fewer clusters than
  people). It is driven by overlap and acoustically-similar co-speakers being merged/missed, not by codec.
- The user's production **"one person → 9 speakers"** over-split is **not reproduced**: max fragmentation is
  **3 profiles/person** (§4), and only 5 % of files over-segment at all.

**Consequence for 0.88:** the consolidation knob's only active sub-phase (`pairwiseMergeThreshold`) merges
*duplicate same-voice clusters within a file*. When the diarizer under-segments, there is **at most one
cluster per voice**, so there is nothing for 0.88 to merge — it is inert by absence of input, confirmed in §4
(every `none` row equals its `0.88` row). On AMI the same knob was inert because the band sat below it; here it
is inert because under-segmentation removes the duplicate clusters. **Same outcome, different mechanism** — and
either way VoxConverse cannot calibrate it.

## 2. Baseline metrics (production config: consolidation 0.88, match 0.60)

Macro-mean over 216 files (DER uses optimal per-file label mapping → isolates diarizer quality):

| metric | value | reading |
|---|---|---|
| mean **DER** | **0.2012** | far cleaner than AMI's 0.437 (short, low-overlap files) |
| — confusion | 0.1248 (**62 % of DER**) | within-file speaker **mixing** — under-segmentation signature |
| — miss | 0.0458 | low (little overlapped speech to miss; overlap only 3.6 %) |
| — false alarm | 0.0306 | low (SAD well-calibrated) |
| **fragmentation** | mean **1.195** / person, max **3** | mild over-split; nowhere near "1→9" |
| **false-merge** | **189** profiles span ≥2 people | see §5 attribution |
| **re-ID #2+** | **None** | **no speaker recurs across files** — N/A by construction |
| **profiles_end** | **448** (ideal 972) | diarizer ceiling: only ~half the true identities are recoverable |

DER is **confusion-dominated** (62 %), the textbook under-segmentation fingerprint, but the absolute confusion
(0.125) is < half AMI's (0.298): in-the-wild YouTube is per-file *easier* than long, high-overlap AMI meetings.

*(The harness's raw re-ID curve has only an appearance-#1 entry — **0.915**, i.e. first-sighting within-file
assignment to the anchor profile is high — and **no** appearance #2, because no namespaced speaker recurs across
files. "re-ID #2+ = None" is therefore structural, not a failure.)*

## 3. The similarity bands — why no threshold move helps here (the key measurement)

Cosine between quality-filtered mean embeddings (mirrors BASELINE §4; same-speaker = within-file split-half;
different-speaker split into within-file and the cross-file matcher surface). 200 k sampled cross-file pairs.

| band | mean | p50 | p90 | p95 | p99 |
|---|---|---|---|---|---|
| **same-speaker** (within file) | **0.931** | 1.00 | 1.00 | 1.00 | 1.00 |
| different-speaker, **within file** | 0.39 | 0.268 | **1.00** | 1.00 | 1.00 |
| different-speaker, **cross file** (matcher surface) | **0.145** | 0.129 | 0.314 | 0.377 | **0.501** |

**Fraction of *different*-speaker pairs that would exceed each candidate match threshold** (= false-merge pressure):

| match | cross-file diff | within-file diff | same-speaker recall |
|---|---|---|---|
| 0.45 | 1.9 % | 28.6 % | 93.8 % |
| 0.50 | 1.0 % | 26.3 % | 93.8 % |
| 0.55 | 0.6 % | 24.5 % | 93.8 % |
| 0.60 | **0.4 %** | 23.2 % | 93.6 % |
| 0.65 | 0.3 % | 22.2 % | 93.4 % |

Three decisive facts:
1. **Same-speaker band stays HIGH (0.93), not low.** Same-speaker recall is flat-to-slightly-falling
   (**93.4–93.8 %**, n = 563 within-file pairs, low-tail p5 ≈ 0.31) across 0.45–0.65 — lowering toward 0.50 buys
   **negligible** recall, it only raises false-merge pressure. This is the opposite of the *(inferred)* AMI-VoIP
   codec band (same-voice ≈ 0.39), confirming VoxConverse is **not** the compressed low-band regime.
2. **The cross-file matcher surface is nearly clean** (different-speaker mean 0.145, p99 ≈ 0.50): distinct people
   from different videos almost never look alike to WeSpeaker. The matcher has a **wide safe margin** — 0.50–0.65
   are all fine on the cross-file axis.
3. **The confusable mass is *within* files** (different-speaker within-file exceeds threshold **22–29 %** of the
   time — a ~25× higher rate than cross-file). That tail is overlap + diarizer-mixed segments: an *upstream*
   phenomenon no match threshold can fix.

## 4. Threshold sweeps (measured)

Full grid — **every `none` row is identical to its `0.88` row to 4 dp**, so consolidation is folded out:

| match | mean DER | frag mean | frag max | false-merge | re-ID #2+ | profiles_end (ideal 972) |
|---|---|---|---|---|---|---|
| 0.45 | 0.2134 | 1.183 | 3 | **155** | None | 213 |
| 0.50 | 0.2061 | 1.192 | 3 | 171 | None | 305 |
| 0.55 | 0.2014 | 1.193 | 3 | 174 | None | 385 |
| **0.60** | 0.2012 | 1.195 | 3 | 189 | None | 448 |
| 0.65 | 0.2005 | 1.197 | 3 | **198** | None | **462** |

- **profiles_end rises monotonically with the threshold** (213→462) and never approaches 972 — the diarizer
  ceiling, not the matcher, caps identity recovery. By the aggregator's objective (minimise |profiles_end − 972|,
  then false-merge, then frag, then re-ID), the **optimal is the *highest* threshold (0.65)** — the opposite of a
  drop toward 0.50.
- **The choice barely moves quality — but it is not free.** DER moves only 0.013 and frag 0.014, and re-ID — the
  metric that made AMI prefer 0.60 — is **absent** here, so the lever AMI used to pick 0.60 does not exist on
  VoxConverse. On the **false-merge axis the threshold does matter, just unhelpfully**: lower fuses fewer-but-
  bigger mega-profiles and shifts blame to the matcher; higher traps more distinct people upstream (§5). There is
  no good setting — which is the point: **the match knob is not the lever on this corpus.**
- **No ⭐ row** (no combo hits exactly 972 with zero merges): unreachable given under-segmentation.

## 5. False-positive attribution — diarizer-bound or matcher-bound?

Each false-merge profile spans ≥2 namespaced true ids (`meeting␟spk`). If they share **one** meeting → the
diarizer under-segmented within a file (upstream); if they span **≥2** meetings → the matcher fused distinct
people across files.

| match | false-merge total | within-file (diarizer) | cross-file (matcher) | % matcher | % of 972 speakers in a merge |
|---|---|---|---|---|---|
| 0.45 | 155 | 71 | 84 | 54 % | 38 % |
| 0.50 | 171 | 82 | 89 | 52 % | 41 % |
| 0.55 | 174 | 95 | 79 | 45 % | 41 % |
| **0.60** | **189** | **115** | **74** | **39 %** | 44 % |
| 0.65 | 198 | 121 | 77 | 39 % | 45 % |

- **At the production 0.60, 61 % of false-merges are upstream (diarizer under-segmentation within a file)** — the
  contaminated cluster mixes two real people *before* the matcher runs, so no threshold can split it. This is the
  AMI finding, reproduced in the wild.
- **The matcher is not fully exonerated — but its share is bounded and is an upper bound.** The 39 % cross-file
  figure overstates the matcher: **31 % of those cross-file profiles (23/74 at 0.60) are *also* internally
  diarizer-contaminated** (one meeting contributing ≥2 people to the same profile), so the matcher-*only* share
  is ≈ **27 % (51/189)**. Still, **lowering the threshold shifts blame toward the matcher** (cross-file share
  39 % → 54 % at 0.45) while the *total* does not fall — a low threshold is strictly worse here.
- **No threshold is clean.** Total false-merge *rises* with the threshold (155 → 198), and so does the number of
  **distinct real people trapped in a merge (372 → 435, i.e. 38 % → 45 % of all 972)** — higher thresholds
  genuinely fuse more speakers, not merely re-bucket a fixed contaminated mass. What stays constant is the
  *source*: within-file (diarizer) contamination is present at every threshold (within-file-trapped speakers rise
  159 → 262 in lock-step). Lowering shifts blame to the matcher without cutting the total; raising traps more
  people upstream. **That the match knob cannot drive false-merge down — in either direction — is itself the
  evidence that the bottleneck is upstream.**

## 6. Where VoxConverse sits in the corpus mix / next action

Triangulating the three measured corpora:
- **AMI (clean in-room):** diarizer under-segments 4-party audio → false-merge is a diarizer ceiling (22); match
  0.60 is the re-ID/false-merge sweet spot; 0.88 inert (band ≤ 0.72).
- **VoxCeleb singles (matcher-isolated):** clean single voices → matcher *fragments* (30 people → 53 profiles at
  0.60), the opposite failure.
- **VoxConverse (this report):** in-the-wild but uncompressed → **under-segments like AMI** (0.81 clusters/true),
  bands clean and well-separated (same 0.93 / cross-file diff 0.14), 0.88 inert, **re-ID unmeasurable**.

VoxConverse **corroborates AMI's "diarizer is the real problem"** and shows the **cross-file matcher is safe in
the wild** — but it does **not** answer the open question (does compressed/remote audio want ~0.50?). That
question needs the two things VoxConverse lacks: **codec compression** (which lowers the same-voice band into the
0.3–0.5 danger zone — *(inferred)* from AMI-VoIP's 0.39 band) **and recurring identities** (to trade off re-ID vs
false-merge). **Highest-value next step:** an **AMI-VoIP re-ID series** (codec-compress the recurring AMI speakers
and re-run the match sweep with re-ID enabled), or a small **labelled Zoom/Meet** corpus that matches real
Transcripted usage. That, not VoxConverse, is where a move from 0.60 toward 0.50 can be confirmed or rejected.

---

## Limits / caveats

- **216 dev files; test split (232 files) not run** (time-boxed; dev is sufficient for direction). 22 single-
  speaker files contribute to diarizer over-split stress but not to re-ID/false-merge (need ≥2 true speakers).
- **Cross-meeting re-ID is N/A**: VoxConverse files are independent conversations with no cross-file identity
  labels, so the match threshold here is a **false-merge knob only**, not a re-ID lever. This is the central
  reason the corpus can't reproduce AMI's 0.60 sweet-spot logic.
- **VoxConverse ≠ compressed/telephone.** It is 16 kHz, 93 % speech, 3.6 % overlap — in-the-wild *recording
  variety*, not *codec degradation*. Statements about the low (0.39) same-voice band and codec-driven
  over-segmentation are *(inferred)* from AMI-VoIP, not measured here.
- **`--match` moves two knobs** (`matchSpeaker` + `mergeDuplicates`) and the eval `matchSpeaker` path lacks the
  app's maturity-bonus / ambiguity guards, so measured linking is an **upper bound** on aggressiveness vs the
  live app.
- **Always-on consolidation phases** (`absorbSmallClusters` 0.72/0.62, `consolidateSameVoiceClusters` 0.88,
  `dbInformedSplit` 0.62) shape every grid cell regardless of the swept `--consolidation` value.
- The within-file different-speaker high tail (§3) is partly overlap-driven mislabeling of mixed-embedding
  segments; it reflects real upstream confusability but its exact magnitude is approximate.

## Reproduce

```bash
VOXCONVERSE_SPLITS="dev" bash scripts/download_voxconverse.sh   # CC-BY; ~2 GB, gitignored (auto-resumes mirror drops)
ls data/voxconverse/audio | wc -l                              # must be 216 before launching
CORPUS=voxconverse CONSOLIDATION="none 0.88" MATCH="0.45 0.50 0.55 0.60 0.65" \
  scripts/run_speaker_eval.sh 2>&1 | tee data/eval/voxconverse/full_run.log
#   -> data/eval/voxconverse/reports/SWEEP.md            (the 10-combo grid)
python3 scripts/analyze_voxconverse_bands.py --out-json data/eval/voxconverse/reports/bands.json
#   -> diarizer over/under-segmentation + same/different-speaker similarity bands
```
All `data/` artifacts are gitignored. The `--per-file-ids` scorer fix is auto-enabled for `CORPUS=voxconverse`.
