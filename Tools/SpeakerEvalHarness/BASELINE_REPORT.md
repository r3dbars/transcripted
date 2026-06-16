# Speaker-naming eval — baseline against AMI ES2002 (a–d)

**Date:** 2026-06-16 · **Audio:** AMI Meeting Corpus, ES2002 scenario series, Mix-Headset
channel, 4 sessions (a/b/c/d), same 4 participants (FEE005, MEE006, MEE007, MEE008)
recurring across all four. ~2h21m total audio. **License:** AMI is research-use
(https://groups.inf.ed.ac.uk/ami/corpus/); used here for internal eval only, not redistributed.
Ground-truth RTTMs from the `pyannote/AMI-diarization-setup` `only_words` set.

**Embeddings under test are the APP'S OWN** — FluidAudio PyAnnote segmentation +
WeSpeaker 256-dim embeddings + VBx clustering, invoked headlessly via
`TranscriptedCore.DiarizationService.diarizeOffline` with the production
`OfflineDiarizerConfig` (`clusteringThreshold: 0.6`, the Zoom-tuned grid-search config).
So the thresholds measured here are calibrated against the exact model the app ships.

> **Measured vs assumed.** Every number below is measured by the harness on real AMI
> audio. The *interpretation* of why a threshold is inert is supported by the
> direct similarity-band measurement (§4). Nothing is hand-waved; where the data
> cannot calibrate a threshold, that is stated rather than guessed.

---

## TL;DR recommendations

| Threshold | Current | Finding on AMI ES2002 | Recommendation |
|---|---|---|---|
| **Cross-meeting match** (`SpeakerDatabase.matchSpeaker` = 0.6) | 0.6 | Sweet spot. ≤0.55 over-merges (3 profiles for 4 people); 0.60–0.65 ends at the correct 4 profiles with best re-ID (0.42); ≥0.70 degrades re-ID hard (0.42→0.20 at 0.75) and fragments. | **Keep 0.60** (0.62–0.65 acceptable). Do **not** raise above ~0.65. |
| **Within-meeting consolidation** (the 0.88 same-voice merge on `feat/embedding-clusterer-same-voice-consolidation`; on `main` this is `EmbeddingClusterer.postProcess(pairwiseMergeThreshold:)`, passed `nil` for offline) | 0.88 | **Structurally inert** on this corpus — same-voice cluster cosine similarities top out at 0.72 (clean) / 0.54 (VoIP), far below 0.88, so the merge never fires. Lowering it into the firing band (≤0.60) over-merges *distinct* speakers and **doubles DER (0.41→0.66)**. | **Cannot be calibrated from AMI.** 0.88 is safe-but-inert here; don't lower it. To tune it, use a dataset that exhibits clean single-voice over-segmentation (see §6). |

**GREEN on infrastructure, YELLOW on the consolidation conclusion**: the harness works
end-to-end on real labeled audio and re-runs in seconds; the match threshold is
validated; but AMI ES2002 turns out to stress the *diarizer*, not the within-meeting
consolidation bug, so 0.88 can't be data-tuned from this subset alone.

---

## 1. Headless feasibility (the gating question)

**Works.** The app's diarizer + 256-dim embeddings run fully headless:

- `TranscriptedCore` compiles from source (`swift build`) against the prebuilt
  `deps-libs/libExternalDeps.a` + `deps-modules/*.swiftmodule` from `build-deps.sh`.
- `DiarizationService.diarizeOffline(audioURL:)` returns `[SpeakerSegment]` carrying the
  per-segment 256-dim WeSpeaker embedding. Confirmed: **103/103, 99/99, 119/119, 230/230
  segments embedded at dim=256**, diarized at ~100–200× realtime on Apple Silicon.
- CoreML models download once from HuggingFace on first run, then cache.

The existing `Tools/TranscriptedCLI diarize` command emits segments but **not** embeddings,
so a new harness target was needed. The harness reuses the app's real
`EmbeddingClusterer.postProcess` and `SpeakerDatabase.matchSpeaker / addOrUpdateSpeaker /
mergeDuplicates`, so it exercises the production code paths, not reimplementations.

## 2. What the two thresholds actually are on `main`

The task named `EmbeddingClusterer.consolidateSameVoiceClusters` @ 0.88. That symbol lives
on the **unmerged** `feat/embedding-clusterer-same-voice-consolidation` branch. On
`origin/main`:

- Within-meeting same-voice merge = `EmbeddingClusterer.postProcess(pairwiseMergeThreshold:)`
  (default 0.85 for Sortformer), but the **offline meeting pipeline passes `nil`** — merge
  delegated to VBx `clusteringThreshold: 0.6`. The harness sweeps `pairwiseMergeThreshold`
  as the consolidation knob (it is the same union-find mean-embedding merge the feature
  branch's `consolidateSameVoiceClusters` performs at 0.88).
- The literal `0.88` on `main` is `SpeakerNamingPolicy.shouldAutoAccept` (auto-accept bar).
- Cross-meeting match = `SpeakerDatabase.matchSpeaker(threshold: 0.6)` — real, as described.

## 3. Baseline metrics (production config: consolidation = none/0.88, match = 0.6)

Per-meeting DER (pyannote.metrics, collar 0.25s, overlap **not** skipped):

| meeting | DER | miss | false-alarm | confusion | ref spk | hyp clusters |
|---|---|---|---|---|---|---|
| ES2002a | 0.284 | 0.111 | 0.110 | 0.062 | 4 | 4 |
| ES2002b | 0.437 | 0.089 | 0.009 | 0.340 | 4 | 3 |
| ES2002c | 0.458 | 0.081 | 0.012 | 0.365 | 4 | 3 |
| ES2002d | 0.436 | 0.127 | 0.022 | 0.287 | 4 | 3 |
| **mean** | **0.404** | | | | | |

- **Fragmentation:** mean **1.75** DB profiles per true person (max 2) — the "how many
  people must I name for one person" number. Cross-meeting, not within-meeting.
- **False-merge:** **3** DB profiles span ≥2 distinct people; one spans all of
  FEE005+MEE007+MEE008.
- **Cross-meeting re-ID curve** (fraction of a person's speech re-identified to their
  first-appearance profile, by appearance #): **#1 = 0.76, #2 = 0.43, #3 = 0.43, #4 = 0.41.**
  Re-ID drops by ~half after the first sighting.

**Root cause (measured, §4): the diarizer under-segments.** ES2002b/c/d yield only
**3 clusters for 4 speakers**; raw clusters — *before any DB matching* — already mix 2–3
true people each (e.g. ES2002b cluster 1 = MEE008 43% + MEE006 38% + MEE007 11%). The high
DER `confusion` term (0.29–0.37) and the irreducible floor of 3 false-merges both originate
here, upstream of either threshold. The app's diarizer config was grid-searched on 2-party
Zoom meetings; AMI is 4-party in-room.

## 4. Why 0.88 is inert — the similarity bands (the key measurement)

Mean-embedding cosine similarity between diarizer clusters, grouped by whether their
dominant true speaker matches:

| audio | same-speaker cluster pairs | different-speaker pairs | pairs 0.88 would merge |
|---|---|---|---|
| AMI clean (headset) | 0.21–0.72, **mean 0.53** | 0.13–0.60, mean 0.33 | **0 of 3 same** (and 0/12 diff) |
| AMI VoIP (Opus 12k) | 0.21–0.54, **mean 0.39** | −0.01–0.66, mean 0.36 | **0 of 5 same** (0/24 diff) |

0.88 sits **above the entire same-voice band**, so the consolidation merge can never
trigger on this audio. Under codec degradation the same- and different-voice bands nearly
collapse onto each other (0.39 vs 0.36) — there is no clean separating threshold.
*(Caveat: these cluster means are computed over diarizer-mixed clusters, which drags
same-speaker similarity below what pristine single-voice clusters would show.)*

## 5. Threshold sweeps (measured)

### Match sweep (consolidation = none, AMI clean)
| match | mean DER | frag mean | false-merge | re-ID #2+ | profiles_end (ideal 4) |
|---|---|---|---|---|---|
| 0.55 | 0.404 | 1.75 | 3 | 0.421 | 3 (over-merged) |
| **0.60** | **0.404** | **1.75** | **3** | **0.421** | **4 ✓** |
| 0.62 | 0.404 | 1.75 | 3 | 0.421 | 4 ✓ |
| 0.65 | 0.404 | 1.75 | 3 | 0.421 | 4 ✓ |
| 0.70 | 0.405 | 1.75 | 3 | 0.420 | 5 |
| 0.75 | 0.407 | 2.00 | 5 | **0.197** | 5 |
| 0.80 | 0.407 | 2.00 | 5 | 0.197 | 6 |

### Consolidation sweep (match = 0.6, AMI VoIP — over-segmented so the knob *can* fire)
| consolidation | mean DER | frag mean | false-merge | re-ID #2+ | profiles_end |
|---|---|---|---|---|---|
| none / 0.65–0.94 | 0.406 | 1.75 | 4 | 0.759 | 6 (inert — no merges) |
| 0.60 | 0.640 | 1.25 | 4 | 0.886 | 5 (merging starts) |
| 0.55 | 0.640 | 1.25 | 4 | 0.886 | 5 |
| 0.50 | 0.659 | 1.00 | 2 | 0.967 | **2 (4 people → 2!)** |
| 0.45 | 0.659 | 1.00 | 2 | 0.965 | 2 |

Lowering consolidation into the firing band trades a cosmetic re-ID/fragmentation
improvement for a **+0.25 absolute DER regression** — it is merging distinct speakers.

## 6. Domain gap & next action

AMI is in-room headset audio. The two production bugs ("one person → many speakers";
"one person clumped across meetings") are reported on **compressed remote** audio, where
WeSpeaker similarities sit in 0.3–0.5 (per the in-code comments) — exactly the band where a
0.88 merge is a no-op and a low merge is dangerous. AMI-clean therefore validates the
*algorithm and the match threshold* but cannot calibrate 0.88.

**To tune 0.88 with data, the highest-value next step** is to run this same harness against
labeled *remote/compressed* audio that exhibits clean single-voice over-segmentation —
either real Zoom recordings with speaker labels, or a more aggressive degradation of AMI
single-speaker headset channels (not the mix). The harness already supports this: drop the
WAVs in, `dump`, then sweep. The VoIP demo here (`data/ami/audio_voip/`, regenerable) is a
first step and already shifts the diarizer toward over-segmentation (ES2002a 4→5, ES2002d
3→5 clusters).

---

## Reproduce

```bash
# 0. one-time: build native deps (produces deps-libs/, deps-modules/, deps-frameworks/)
bash build-deps.sh

# 1. fetch the AMI ES2002 subset (audio + RTTMs; ~230 MB; gitignored)
bash scripts/download_ami.sh

# 2. build + dump-diarize + full threshold sweep + scored report
scripts/run_speaker_eval.sh
#    -> data/eval/reports/SWEEP.md

# custom grids:
CONSOLIDATION="none 0.85 0.88" MATCH="0.55 0.6 0.65" scripts/run_speaker_eval.sh
```
