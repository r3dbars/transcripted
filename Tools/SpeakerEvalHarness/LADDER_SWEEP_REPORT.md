# Multi-meeting confidence-ladder sweep — prompts vs false-positives

**Question:** in an ideal state, how few times must a user **TYPE** or **TAP** before a
returning meeting speaker is recognized, at **near-zero false auto-naming** — and which
gate design gets us there?

**Status:** data + analysis are decision-ready for two domains (AMI in-room, VoxCeleb
clean), **each now swept across 11 audio qualities** (codec/bitrate/telephone/noise/reverb —
see **§11**). This PR changes **no production behavior** (the only production diff is making
three already-pure functions `public` so the harness can call the real matcher; see §8). The
decision on what to ship is the human's, after reading the frontier below.

> **Read §1 and §11 together.** §1's clean-audio recommendation (AUTO bar 0.80) is the
> *prompt-minimizing* point on pristine audio. §11 shows that point is **not robust to audio
> degradation** — under VoIP/telephone/noise the safe gate needs a **higher** AUTO bar
> (~0.85) **plus a best-vs-second margin ≥ 0.12**, which is the universal false-positive lever.

---

## 1. TL;DR

| Domain | Production today | Recommended @ false-auto < 0.5% | Win |
|---|---|---|---|
| **AMI (in-room)** | 3.16 prompts/person, **0% ever auto-recognized**, 0 false-auto | **2.53 prompts/person, 34% reach AUTO**, 0 false-auto | −20% prompts **and** silent recognition kicks in by the 3rd meeting |
| **VoxCeleb (clean, single short utterance/meeting)** | 20.9 prompts/person, 13% reach AUTO, 0 false-auto | **19.5 prompts/person, 57% reach AUTO**, 0 false-auto | reach-AUTO 13%→57%; prompts only −7% (bottleneck is *match recall*, not the gate) |

Three findings that change how to think about the ladder:

1. **The AUTO bar (0.88) + the `callCount > 4` rule are the binding constraints, and they're
   miscalibrated.** Production *never* auto-recognizes anyone within a normal 4-session AMI
   relationship, and only 13% of clean recurring speakers. Lowering the bar to **0.80 with a
   best-vs-second-best margin requirement** unlocks silent recognition at **zero** measured
   false-auto.
2. **Evidence-score promotion beats fixed `callCount` thresholds** when audio is good
   (AMI: 2.53 vs 2.78 prompts/person), and ties it when audio is poor (VoxCeleb). It reaches
   AUTO faster for confident matches without lowering the bar for shaky ones.
3. **Demote-on-dispute and un-blend are *not* the lever for false-positives or
   contamination — and on AMI demote consistently *increases* false-auto** (+8.2 pp across
   3,675 matched policy pairs; 0% of pairs improved). The margin gate, not demotion, is the
   false-positive control. (Mechanism + caveats in §6.)

> **Statistical caveat (read before acting):** with 30–32 distinct identities per domain,
> a "0% false-auto" point rests on **0 wrong auto-accepts out of 16–44** auto decisions. That
> is consistent with a true rate anywhere up to ~3–6%. The directional conclusions are robust;
> *certifying* < 0.5% needs a larger-N run (ICSI / full-AMI / 300-identity VoxCeleb — see §7).

---

## 2. What was built (and why it transfers)

A two-stage extension of the existing `speaker-eval-harness`, plus a Python analysis layer.
**It reuses the real production pipeline** — diarizer, clusterer, mean-embedding, cosine
matcher, EMA blend — so tuned thresholds calibrate against the exact model the app ships.

| Stage | Command | Reuses (real production code) | Output |
|---|---|---|---|
| 1. Diarize | `dump` / `dump-batch` | `DiarizationService.diarizeOffline` (FluidAudio PyAnnote + 256-d WeSpeaker) | per-segment embeddings (cached, idempotent) |
| 2. Fingerprint | `ladder-fingerprints` | `EmbeddingClusterer.postProcess` + `Transcription.computeMeanEmbedding` | policy-independent per-(speaker, meeting) fingerprint |
| 3. Sweep | `ladder-sweep` | `Transcription.cosineSimilarityStatic` (real) + EMA blend ported verbatim | per-policy CSV (prompts, false-auto, reach-AUTO, drift, …) |
| — | `ladder-parity` | real `Transcription.matchAgainstProfiles` + `SpeakerDatabase.addOrUpdateSpeaker` | proves the reused math is faithful |
| 4. Analyze | `scripts/ladder/analyze_ladder.py` | — | Pareto frontier, recommendations, plots |

**Faithfulness is proven, not asserted (`ladder-parity`, run in CI):**
- EMA blend (ported) vs real `SpeakerDatabase.addOrUpdateSpeaker`: **maxAbsDiff = 6e-8 → PASS**.
- Generalized gate (production params) vs real `Transcription.matchAgainstProfiles`:
  **1600 cases, 0 decision mismatches, sim diff 0 → PASS**. i.e. the swept matcher reduces
  *exactly* to production at the production parameters.

### The simulation model
For each ground-truth speaker, appearances are assembled as a chronological sequence of
meetings. Walking meetings in order, each per-(speaker, meeting) fingerprint is matched
against the **current** simulated DB → best / second-best / margin recorded → the gate under
test decides **AUTO / SUGGEST / UNKNOWN** → a ground-truth oracle simulates the human:

- **UNKNOWN** → 1 **TYPE** (creates the profile; if that identity already existed but didn't
  match, the type *merges by name* — a missed recurrence, counted as a false-UNKNOWN).
- **SUGGEST** → 1 **TAP**; if the proposed name is wrong, +1 **correction** (tap to reject +
  type/select the right person) and the wrongly-suggested profile is disputed (if demote on).
- **AUTO** → no action. If the silently-applied name is wrong it is a **FALSE-AUTO**: the
  transcript is mislabeled *and* the profile is poisoned via the EMA blend (worst case: never
  noticed, never repaired).

Enrollment uses the real EMA blend (α swept). Contamination drift = cosine distance between a
profile's live centroid and its "clean" centroid (mean of only correctly-attributed
fingerprints).

### Gate parameterization (the design space, all crossed)
`SUGGEST_FLOOR` {.40 .45 .50 .55 .60} × `AUTO_BAR` {.80 .83 .85 .88 .90 .92 .95} ×
`MARGIN_MIN` {0 .03 .05 .08 .12} × promotion {fixed callCount>{2,3,4,5}; evidence≥{.25,.40,.60}}
× EMA α {.10 .15 .25} × demote {off, demote, demote+un-blend}, with the production maturity
bonus (+0.08/+0.04) and 0.05 separation check ON (a small ablation toggles them off).
**= 11,025 policies + baseline + 28-policy ablation = 11,053 policies per domain**, run in
3.8 s (AMI) / 17.4 s (VoxCeleb). The production policy is included as an explicit baseline
point. Nothing was dropped from the requested grid.

---

## 3. Corpus coverage (honest accounting)

| Domain | Corpus | Status | Meetings | Speakers | Appearances/person |
|---|---|---|---|---|---|
| in-room | **AMI scale** (ES2002…ES2010, a–d) | ✅ done | 32 | 32 (26 recurring) | up to **4** (a–d) |
| clean | **VoxCeleb** (mini_voxceleb1, singles) | ✅ done | 600 | 30 | **~20** |
| in-room (deep) | **ICSI** | ⛔ **blocked** | — | — | — |
| in-the-wild | **VoxConverse** | ⏳ **deferred** | — | — | — |

- **ICSI is blocked**: its RTTMs come from a *gated* HF dataset (`diarizers-community/icsi`)
  and this environment is not `hf auth login`'d. ICSI is the only corpus with >4 cross-session
  appearances per real person, so it is the right way to extend the *in-room* meetings-to-AUTO
  curve beyond appearance 4. **Action: log in to HF and run `CORPUS=icsi`.**
- **VoxConverse is deferred (not silently dropped)**: RTTMs downloaded (216 dev files); audio
  was still downloading at cutoff. More importantly, under the recurrence-based ladder model it
  is *uninformative as-is* — VoxConverse speaker labels are per-file (each file's speakers are
  distinct people), so with the (already-implemented) `--namespace-speakers` flag every speaker
  appears once, no profile ever matures, and false-auto is trivially ~0. The *informative*
  in-the-wild experiment is a **cross-corpus distractor**: seed the DB with mature AMI/VoxCeleb
  profiles, then stream VoxConverse novel speakers and count wrong auto-names. That needs a
  DB-seeding mode (specified in §9) and is the recommended next build.
- **AMI's 4-appearance cap** means production's `callCount > 4` rule can *never* fire in AMI —
  a finding, but it also truncates the in-room meetings-to-AUTO curve. Within-session
  partitioning could synthesize more appearances but would inflate re-ID ease (same recording),
  so it was deliberately not used; ICSI is the correct fix.

---

## 4. Pareto frontier (prompts/person vs false-auto rate)

Plot: `data/eval/_analysis/pareto.png` (one curve per domain, production baseline = ★).
Per-domain frontier points (`data/eval/<corpus>/ladder/pareto_<corpus>.csv`):

### AMI (in-room) — 32 people, 91 appearances
Production baseline ★: **3.16 prompts/person, 0% reach-AUTO, 0% false-auto, drift 0.033.**

| prompts/person | false-auto % | autoBar | floor | margin | promo | α | demote | %reach-AUTO |
|---:|---:|---:|---:|---:|---|---:|---|---:|
| 2.34 | 12.50 | 0.80 | 0.50 | 0.00 | evidence(≥0.25) | 0.25 | off | 44 |
| 2.38 | 8.70 | 0.80 | 0.50 | 0.00 | evidence(≥0.25) | 0.15 | off | 44 |
| 2.41 | 5.56 | 0.80 | 0.60 | 0.00 | evidence(≥0.25) | 0.15 | off | 38 |
| 2.47 | 5.00 | 0.80 | 0.55 | 0.08 | evidence(≥0.25) | 0.25 | off | 41 |
| 2.50 | 4.76 | 0.80 | 0.50 | 0.12 | evidence(≥0.25) | 0.25 | off | 41 |
| **2.53** | **0.00** | **0.80** | **0.60** | **0.12** | **evidence(≥0.25)** | **0.25** | **off** | **34** |

→ **Recommended @ false-auto < 0.5%: 2.53 prompts/person** (1.38 types + 1.16 taps),
**0% false-auto, 34% reach AUTO, median 3 meetings → AUTO.** vs baseline: **−0.62
prompts/person (−20%)**, and silent recognition appears (0%→34%) where production had none.
The margin requirement (0.12) is what holds false-auto at zero while the bar drops to 0.80.

re-ID accuracy by appearance # (no-correction-needed rate): baseline `[.88 .85 .91 1.0]`,
recommended `[.91 .96 .91 1.0]` — and recommended converts 16 of those appearances into
**silent** correct autos (baseline: 0).

### VoxCeleb (clean, single short utterance per meeting) — 30 people, 599 appearances
Production baseline ★: **20.93 prompts/person, 13% reach-AUTO, 0% false-auto, drift 0.008.**

| prompts/person | false-auto % | autoBar | floor | margin | promo | α | demote | %reach-AUTO |
|---:|---:|---:|---:|---:|---|---:|---|---:|
| 18.67 | 22.03 | 0.80 | 0.60 | 0.00 | evidence(≥0.25) | 0.15 | off | 60 |
| 19.00 | 9.62 | 0.80 | 0.60 | 0.00 | fixed(callCount>3) | 0.15 | off | 60 |
| 19.07 | 8.00 | 0.80 | 0.60 | 0.00 | fixed(callCount>4) | 0.15 | off | 60 |
| 19.23 | 6.00 | 0.80 | 0.60 | 0.00 | evidence(≥0.60) | 0.15 | off | 63 |
| **19.50** | **0.00** | **0.80** | **0.60** | **0.08** | **fixed(callCount>3)** | **0.15** | **off** | **57** |

→ **Recommended @ false-auto < 0.5%: 19.50 prompts/person**, **0% false-auto, 57% reach
AUTO** (vs 13%), median 13 meetings → AUTO. vs baseline: only **−1.43 prompts/person (−7%)**
— because the dominant cost here is **match recall**: ~10 of 20 appearances per person fall
*below the floor* (a single 4–8 s clip is a noisy fingerprint) and become re-types, and that
floor cost barely moves across the whole grid. **For short-utterance/clean encounters the
lever is better per-encounter audio/embeddings (or multi-clip enrollment), not the gate.**

---

## 5. Fixed-count vs evidence-score promotion (head-to-head)

| Domain | Best **fixed** @ <0.5% FA | Best **evidence** @ <0.5% FA | Winner |
|---|---|---|---|
| AMI | 2.78 prompts/person (`callCount>2`) | **2.53** prompts/person (`evidence≥0.25`) | **evidence (−9%)** |
| VoxCeleb | **19.50** (`callCount>3`) | 19.53 (`evidence≥0.60`) | tie |

**Evidence-score wins when audio is good** (AMI): it promotes on *accumulated confident
margin*, so a person seen 2–3× with strong, unambiguous matches reaches AUTO sooner than a
fixed count allows, without lowering the bar for shaky matches. When per-encounter audio is
poor (VoxCeleb), evidence accumulates slowly and the two converge. Net: **evidence-score is
the better default** — same safety, strictly ≤ prompts.

---

## 6. Demote-on-dispute + un-blend → contamination (matched-pair)

Compared as **matched pairs** (identical params, varying only the demote mode) across 3,675
parameter groups per domain — *not* a raw mean, which would be dominated by reckless configs.

| Domain | mode | Δ false-auto | Δ contam-drift | Δ prompts/person | reduces false-auto in |
|---|---|---:|---:|---:|---:|
| AMI | demote vs off | **+8.20 pp** | −0.0018 | +0.18 | **0% of groups** |
| AMI | demote+un-blend vs off | **+8.20 pp** | −0.0018 | +0.18 | 0% of groups |
| VoxCeleb | demote vs off | −2.28 pp | −0.0000 | +0.38 | 31% of groups |
| VoxCeleb | demote+un-blend vs off | −0.22 pp | +0.0032 | +0.36 | 20% of groups |

**Counterintuitive but consistent: demotion does not reduce contamination, and on AMI it
*increases* false-auto.** Two mechanisms:
1. **Demote removes a competitor.** Disputing a wrongly-suggested profile excludes it from
   matching — which *lowers the second-best similarity* for everyone else, so the
   separation/margin guard (the real false-auto control) fires less, and *more* auto-accepts
   slip through, some wrong. At the AMI recommended params, flipping demote on takes false-auto
   0%→5.3% (16→19 autos, 1 of the new ones wrong).
2. **Demotion/un-blend can't touch the dominant contamination.** The biggest contamination
   source is the *silent* false-auto blend, which by definition is never disputed — so drift
   barely moves (≤0.003), and un-blend's rollback to a stale pre-poison centroid can even make
   drift *worse* (VoxCeleb +0.003).

**Implication:** the false-auto and contamination levers are the **margin gate** and **not
auto-accepting low-margin matches** — not post-hoc demotion. *Caveat:* this rests on the
worst-case "false-autos are never caught." A periodic **review that surfaces auto-named
speakers** would give demote/un-blend something real to repair; that mechanism doesn't exist
today and is the more promising contamination defense (see §9).

---

## 7. Domain-specific recommendations

| Domain | Recommended gate | Expected effect | Confidence |
|---|---|---|---|
| **In-room (AMI-like)** | floor **0.60**, AUTO **0.80**, **margin ≥ 0.12**, **evidence ≥ 0.25**, α 0.25, demote off | 3.16→2.53 prompts/person; 0%→34% reach AUTO; 0 false-auto | directional (N=32) |
| **Clean / short-utterance (VoxCeleb-like)** | floor **0.60**, AUTO **0.80**, **margin ≥ 0.08**, **fixed callCount>3** (or evidence≥0.6), α 0.15, demote off | 13%→57% reach AUTO; −7% prompts; 0 false-auto. **Bigger lever: improve per-encounter embeddings.** | directional (N=30) |

The right gate **does differ by domain**: in-room tolerates an aggressive evidence promotion
with a strong margin (good audio → confident, separable matches); clean-but-short audio needs
a slightly looser margin but its real ceiling is match recall, not the gate. A single shipped
default of **AUTO 0.80 + margin ≥ 0.08 + evidence≥0.3** is a reasonable compromise across both.

**To certify < 0.5% false-auto (next step):** rerun with larger N so the false-auto estimate
has power — `hf auth login` then `CORPUS=icsi` (deep in-room recurrence), `AMI_SET=scale`→`full`,
and `VOXCELEB_IDENTITY_CAP=300`. The harness is built to absorb these unchanged.

---

## 8. Production change in this PR (visibility only — no behavior change)

Three already-pure `nonisolated static` functions in `SpeakerMatchingService.swift` were made
`public` so the harness can call the **real** matcher instead of reimplementing it
(`matchAgainstProfiles`, `computeMeanEmbedding`, `cosineSimilarityStatic`, + `SnapshotMatchResult`).
This is the "factor out the real code" path; it changes no logic and is covered by
`ladder-parity`. **No threshold, gate, clustering, or DB behavior is altered.**

---

## 9. Proposed `SpeakerNamingPolicy` diff (SKETCH — *not applied*)

This is what shipping the recommended in-room gate would look like. **Do not apply without the
larger-N certification (§7) and the consolidation-decoupling caveat below.**

```swift
public enum SpeakerNamingPolicy {
    // CHANGED 0.88 → 0.80. ⚠️ Today this constant is tied to
    // EmbeddingClusterer.sameVoiceConsolidationThreshold (guarded by EmbeddingClustererTests).
    // The 0.80 AUTO bar is only safe BECAUSE of the new margin guard below; within-meeting
    // consolidation must NOT also drop to 0.80. → DECOUPLE the two constants first.
    public static let autoAcceptSimilarityThreshold: Double = 0.80
    public static let autoAcceptMarginMin: Double = 0.12        // NEW: best − secondBest
    public static let autoEvidenceTarget: Double = 0.25         // NEW: evidence-score promotion

    // Was: callCount > 4 && similarity > 0.88. Now: evidence-based + margin guard.
    public static func shouldAutoAccept(
        profile: SpeakerProfile,
        similarity: Double,
        secondBestSimilarity: Double,        // NEW: requires the matcher to surface 2nd-best
        evidence: Double                      // NEW: accumulated confident-match evidence
    ) -> Bool {
        let margin = secondBestSimilarity >= 0 ? similarity - secondBestSimilarity : .infinity
        return profile.displayName != nil
            && profile.disputeCount == 0
            && similarity > autoAcceptSimilarityThreshold
            && margin >= autoAcceptMarginMin
            && evidence >= autoEvidenceTarget   // replaces callCount > 4
    }
}
```

Supporting changes (sketch): `matchAgainstProfiles` already computes `secondBestSimilarity`
— surface it in `SnapshotMatchResult`; add an `evidence: Double` column to `SpeakerProfile` /
the `speakers` table, incremented in `addOrUpdateSpeaker` by `max(0, sim−floor) + 0.25·margin`.
Leave the maturity bonus and 0.05 separation check as-is. Per §6, **do not** add demote-driven
un-blend as a contamination fix; invest in a review-surfacing flow instead.

---

## 10. Reproduce

```bash
cd Tools/SpeakerEvalHarness && swift build -c release          # needs deps-{libs,modules,frameworks}
BIN=.build/release/speaker-eval-harness
$BIN ladder-parity                                             # gate: math == production

# AMI (in-room)
scripts/download_ami.sh scale && scripts/ladder/run_dumps.sh ami
$BIN ladder-fingerprints --dumps data/eval/ami/dumps --rttm data/ami/rttm --corpus ami \
     --out data/eval/ami/fingerprints.json
$BIN ladder-sweep --fingerprints data/eval/ami/fingerprints.json --corpus ami \
     --out-dir data/eval/ami/ladder

# VoxCeleb (clean) — local HF cache, no download
python3 scripts/ladder/build_voxceleb_singles.py && $BIN dump-batch \
     --audio-dir data/voxceleb/sessions/audio --out-dir data/eval/voxceleb/dumps
$BIN ladder-fingerprints --dumps data/eval/voxceleb/dumps --rttm data/voxceleb/sessions/rttm \
     --corpus voxceleb --out data/eval/voxceleb/fingerprints.json
$BIN ladder-sweep --fingerprints data/eval/voxceleb/fingerprints.json --corpus voxceleb \
     --out-dir data/eval/voxceleb/ladder

python3 scripts/ladder/analyze_ladder.py ami voxceleb        # frontier + recommendations + plot
```

All datasets and CSV checkpoints live under `data/` (gitignored). Sweep CSVs are
append-checkpointed per policy; the expensive `dump` stage is idempotent per meeting.

---

# 11. Audio-quality robustness (corpus × quality matrix)

The §1–§10 results above are on the cleanest available audio. Real meetings arrive over
VoIP, cellphones, telephone bridges, noisy rooms, and far-field mics. This section sweeps the
**same ladder against 11 audio qualities** to answer: *does a gate that looks safe on clean
audio stay safe when the audio degrades?* **Short answer: no — and the margin gate is what
saves it.**

## 11.1 Method
Each corpus's audio is re-encoded through a degradation chain (ffmpeg) and decoded back to a
**uniform 16 kHz mono WAV**, so the diarizer ingests every quality identically and only the
spectral/noise degradation differs. The full pipeline (degrade → real diarizer dump → real
`postProcess` + `computeMeanEmbedding` fingerprints → 11k-policy sweep) is re-run per quality
(`scripts/ladder/{degrade_corpus.py,run_quality_cell.sh,run_quality_matrix.sh}`), then
`analyze_quality.py` joins policies across qualities **by policyId** (the grid is
deterministic) to find the gate that holds the false-auto budget in *every* quality.

The 11 qualities were **independently FFT-validated** (spectral edge, telephone-band energy,
measured SNR): `orig` (full 8 kHz band) · `mp3_64`/`aac_32`/`mp3_32` (≈ clean, HF retained) ·
`opus_16k` (moderate rolloff) · `mp3_16` (~5 kHz, 6–8 kHz gone) · `opus_8k` (~2.2 kHz, VoIP) ·
`tel_g711` (300–3400 Hz landline, μ-law) · `reverb` (50/80/120 ms echo tail) ·
`noisy_snr10`/`noisy_snr5` (white noise, **calibrated to measured 10.0 / 5.0 dB SNR**).

**Coverage:** WAVE 1 (done) = **VoxCeleb 30×30 + AMI-scale 32**, each × **all 11 qualities**
(22 cells × 11,053 policies = **243,166 policy-sims**). WAVE 2 (in progress) = **AMI-full
(189 speakers, high-N)** + **VoxConverse (in-the-wild)** × 6 representative qualities, to
certify false-auto rates at large N (see §11.5).

## 11.2 Headline: clean-audio safety does NOT transfer to degraded audio
On VoxCeleb, the **production gate shows 0% false-auto on clean codecs but mislabels silently
as audio degrades** (small auto-denominators at N=30 — read with §11.4 caveat, but the
direction is corroborated by suggest-precision below):

| quality | baseline false-auto | autos (wrong/total) | baseline suggest-precision |
|---|---:|---:|---:|
| orig / mp3_64 / aac_32 / mp3_32 / opus_16k | 0% | 0/3–8 | 0.85–0.87 |
| mp3_16 | 10.3% | 3/29 | 0.87 |
| tel_g711 | 8.3% | 1/12 | 0.81 |
| opus_8k | 40% | 2/5 | 0.77 |
| noisy_snr10 | 25% | 1/4 | 0.70 |
| noisy_snr5 | 33% | 2/6 | 0.62 |
| reverb | 50% | 6/12 | 0.75 |

## 11.3 The robust signal: suggest-precision collapses under degradation
False-auto rate has a tiny denominator at N=30; **suggest-precision** (fraction of proposed
names that were correct) is computed over *every* SUGGEST and is the statistically robust
measure of the same confusion. It degrades monotonically with audio quality:

| quality | VoxCeleb suggest-prec | AMI suggest-prec |
|---|---:|---:|
| orig | 0.86 | 0.81 |
| mp3_64 / aac_32 / mp3_32 | 0.85–0.86 | 0.81–0.83 |
| opus_16k | 0.87 | 0.85 |
| mp3_16 | 0.87 | 0.55 |
| tel_g711 | 0.81 | 0.69 |
| reverb | 0.75 | 0.82 |
| noisy_snr10 | 0.70 | 0.60 |
| opus_8k | 0.77 | **0.40** |
| noisy_snr5 | 0.62 | 0.53 |

Mild codecs (`mp3_64`, `aac_32`, `opus_16k`, `mp3_32`) are indistinguishable from clean.
The cliff is **heavy low-bitrate (`opus_8k` 8 kbps) and noise (`snr5`)**: at `opus_8k`, AMI
suggest-precision falls to **0.40** — 60% of proposed names are wrong — because aggressive
band-limiting (~2.2 kHz) collapses different voices toward each other in embedding space.
Plots: `ladder_results/quality/quality_{voxceleb,ami_scale}.png`.

## 11.4 The quality-robust gate (false-auto ≤ 0.5% in EVERY quality)
Joining by policyId across all 11 qualities and requiring the budget in the worst quality:

| corpus | robust gate | mean prompts/person | worst-case false-auto | reach-AUTO |
|---|---|---:|---:|---:|
| VoxCeleb (clean/short) | `auto=0.83, margin=0.12, fixed cc>5, α=0.15` | 31.0 | 0% (2,159 policies qualify) | 42% |
| AMI (in-room) | `auto=0.95, margin=0.12, evidence≥0.25, α=0.15` | 3.02 | 0% (3,566 policies qualify) | 8% |

**Two robustness rules emerge, and they revise §1's clean-only recommendation:**
1. **The margin requirement `best − second ≥ 0.12` is universal** — it appears in *every*
   quality-robust gate, both corpora. It is the single most important false-positive lever:
   degradation inflates the top similarity, but rarely the *gap* to the runner-up, so a margin
   gate rejects the ambiguous auto-accepts that a bare similarity bar lets through.
2. **The AUTO bar must go UP, not down, for cross-quality safety** (0.83–0.95), the opposite
   of the clean-audio optimum (0.80 in §1). The clean-audio "auto=0.80" point is *not* robust
   — it produces the degraded-audio false-autos in §11.2. If degraded audio is in scope, ship
   **auto ≈ 0.85 + margin ≥ 0.12** rather than auto 0.80.

## 11.5 Caveats / status
- **N=30/32 makes per-quality false-auto rates noisy** (denominators 4–29 autos). The
  *direction* is robust (corroborated by suggest-precision over hundreds of suggests), but
  certifying "< 0.5%" needs the high-N run: **WAVE 2 (AMI-full, 189 speakers)** is dumping now
  and will replace the AMI false-auto column with statistically powered rates; **VoxConverse**
  (in-the-wild YouTube) adds a genuinely-compressed real-world domain. This section will be
  updated when WAVE 2 lands.
- Noise SNR labels are calibrated to **measured** 10.0 / 5.0 dB (FFT-verified after correcting
  an ffmpeg `amix` normalization that initially offset them ~4.7 dB).
- `reverb` does not band-limit (≈ orig spectrum); its effect is the echo tail, so its impact on
  re-ID is milder/noisier than the band-limiting codecs.
