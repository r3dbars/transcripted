# Speaker eval: multi-exemplar + negative-exemplar accuracy delta (2026-07)

## Verdict

The two speaker-identity features that merged into `main` in 2026-07 were measured against the
legacy single-average matcher on **real** cross-condition speaker embeddings (AMI + VoxCeleb, the
same audio-degradation qmatrix used by `Tools/SpeakerEvalHarness`). Both help, neither is free:

- **Multi-exemplar voiceprints (#1488) is a real recall win with a real safety cost.** On AMI
  returning speakers arriving in degraded audio it lifts match recall **+10.9 pp (54.9% → 65.9%)**
  and correct silent auto-recognition **+8.1 pp (1.6% → 9.7%, ~6×)** — but it also introduces
  **12 silent mislabels (false-auto 0.0% → 1.6%)** at the certified operating point, where the
  legacy matcher had **zero**. The "0 false-auto" guarantee the AMI-full ladder certified for the
  average-only matcher (`SpeakerNamingPolicy` header, §11) **no longer holds on degraded audio**
  once best-of-exemplars scoring is in play.
- **Negative-exemplar veto (#1487) is a sound but partial, regime-limited fix.** After a correction
  it removes **46% of repeat wrong-matches in-room (AMI)** but only **12% cross-condition
  (VoxCeleb)**, because the returning wrong voice usually resembles the rejected sample by *less*
  than the 0.80 veto floor once the audio condition changes — the same condition-gap multi-exemplar
  was built to close on the positive side has no analog on the negative side. It carries a small but
  nonzero **~2% owner-collateral** (the true owner's own voice occasionally vetoed).

**Recommendation:** keep both features — the recall/recognition gains are large and real — but
**retune the auto-name gate for the exemplar path** before treating "0 false-auto" as still true.
The 0.12 best-vs-second margin was calibrated against a single average; a best-of-3-exemplars score
can clear both the 0.92 bar *and* the margin for an impostor. Cheapest robust option: compute the
auto-accept **margin against the profile's *average* representative, not its best exemplar** (or
apply a small exemplar-vs-average handicap at the auto gate only). Separately, give the negative
veto a **multi-exemplar-style, cross-condition representation** (or lower its floor with an
owner-protection guard) so it fires in the VoIP/telephone regime where it currently doesn't. See
[Recommendation](#recommendation).

## Metric

Two experiments, both at the production operating point
(`SpeakerNamingPolicy.autoAcceptSimilarityThreshold = 0.92`, `autoAcceptMarginMin = 0.12`, mature
DB-match floor `SpeakerEmbeddingThresholds.weSpeaker.matchManySegments = 0.70`):

1. **Cross-condition identification (failure mode a).** For each ground-truth speaker, a mature,
   multi-condition profile is enrolled from ~60% of their meetings across every audio quality (real
   EMA blend + real `SpeakerExemplarPolicy` exemplar maintenance, through `SpeakerDatabase`). The
   held-out 40% of meetings, restricted to **degraded** conditions (opus_8k, tel_g711, noisy_snr5,
   reverb, mp3_16), are scored against the full gallery two ways:
   - **WITH** — `SpeakerVectorMath.bestSimilarity(candidate, average, exemplars)` + the real
     `SpeakerNegativeExemplarPolicy` veto (both features live).
   - **WITHOUT** — `SpeakerVectorMath.cosineSimilarity(candidate, average)` only, no veto (the
     pre-#1487/#1488 single-average matcher).
   The auto-name decision in both arms is the real `SpeakerNamingPolicy.shouldAutoAccept`.
   Reported: genuine recall@floor, correct silent auto-recognition, **false-auto (silent
   mislabels)**, impostor false-accept@floor, mean genuine similarity.

2. **Post-correction veto (failure mode b).** For every confusable ordered pair (A, B) — a B
   utterance `u1` that wrongly clears A's floor — `u1` is stored as A's negative exemplar (the real
   correction signal) and every *other* held-out B utterance is replayed. Reported: legacy repeat
   wrong-match rate, veto fire rate, **fraction of wrong re-matches the veto removes**, the vetoable
   share (returning voice ≥ 0.80 to the rejected sample), the same-condition designed case, and
   owner-collateral (A's own voice wrongly vetoed).

Guardrails: the harness asserts multi-exemplar is monotone non-decreasing on genuine similarity
(it must never *lower* a true match) and that the negative-exemplar store round-trips through
SQLite. No RNG — fully deterministic (splits by sorted meeting/quality order).

## Commands and sources

- Repo: `r3dbars/transcripted`, branch `eval/exemplar-delta-2026-07`, off `main@17601969` (both
  #1487 and #1488 merged: `eb1ecf19`, `aa74fed8`).
- Harness (new): [`Tests/TranscriptedCoreTests/SpeakerExemplarDeltaEvalTests.swift`](../Tests/TranscriptedCoreTests/SpeakerExemplarDeltaEvalTests.swift)
- Feature code under test:
  - `Sources/TranscriptedCore/Speaker/SpeakerExemplarPolicy.swift`,
    `SpeakerVectorMath.bestSimilarity` (multi-exemplar, #1488)
  - `Sources/TranscriptedCore/Speaker/SpeakerNegativeExemplarPolicy.swift`,
    `SpeakerNegativeExemplarStore.swift` (negative veto, #1487)
  - `SpeakerNamingPolicy.shouldAutoAccept`, `SpeakerEmbeddingThresholds.weSpeaker` (operating point)
- Real embeddings: `Tools/SpeakerEvalHarness` per-quality fingerprint caches
  (`data/eval/qmatrix/<corpus>_<quality>/fingerprints.json`), 256-d WeSpeaker means from the real
  diarizer, produced by `ladder-fingerprints`. Not in-tree (~11 GB); the test XCTSkip's without them.
- Build deps: `bash build-deps.sh` (or symlink prebuilt `deps-*` from a built checkout).
- Run:
  ```bash
  SPEAKER_EVAL_QMATRIX_DIR=/path/to/data/eval/qmatrix \
  SPEAKER_EVAL_OUT=docs/speaker-eval-exemplar-delta-2026-07.result.json \
    swift test --filter SpeakerExemplarDeltaEvalTests
  ```
- Raw output: [`docs/speaker-eval-exemplar-delta-2026-07.result.json`](speaker-eval-exemplar-delta-2026-07.result.json)
  (values below copied from it verbatim).

## Results — multi-exemplar (#1488), degraded cross-condition identification

Operating point: auto-bar 0.92, margin 0.12, match floor 0.70. **WITHOUT** = legacy single average;
**WITH** = best-of-exemplars.

### AMI (in-room) — 147 profiles (138 with ≥1 exemplar), 741 degraded held-out trials

| metric | WITHOUT | WITH | Δ |
|---|---:|---:|---:|
| genuine recall @ floor 0.70 | 0.549 | **0.659** | **+0.109** |
| correct silent auto-recognition @ (0.92, 0.12) | 0.016 | **0.097** | **+0.081** |
| **false-auto (silent mislabels)** @ (0.92, 0.12) | **0.000** (0) | **0.016** (12) | **+0.016** |
| impostor false-accept @ floor 0.70 | 0.287 | 0.553 | +0.266 |
| mean genuine similarity | 0.785 | 0.858 | +0.073 |

### VoxCeleb (clean-source, single short utterance/meeting) — 30 profiles, 1798 degraded trials

| metric | WITHOUT | WITH | Δ |
|---|---:|---:|---:|
| genuine recall @ floor 0.70 | 0.141 | **0.174** | **+0.033** |
| correct silent auto-recognition @ (0.92, 0.12) | 0.000 | 0.001 | +0.001 |
| false-auto @ (0.92, 0.12) | 0.000 (0) | 0.000 (0) | 0.000 |
| impostor false-accept @ floor 0.70 | 0.394 | 0.473 | +0.078 |
| mean genuine similarity | 0.611 | 0.656 | +0.045 |

**Reading it.** Multi-exemplar raises genuine similarity (it stores a per-condition representative
instead of one blended-across-conditions centroid), which is why recall and correct auto-recognition
jump. But `bestSimilarity` is monotone for *every* candidate, impostors included — so impostor
false-accept rises too, and on AMI a handful of impostors now clear both the 0.92 bar and the 0.12
margin, producing 12 silent mislabels the average-only matcher never made. VoxCeleb shows no
false-auto only because its single short utterances essentially never reach the 0.92 bar on degraded
audio (auto-recognition ≈ 0 in both arms); its recall gain is the honest signal there.

## Results — negative veto (#1487), post-correction re-match

After B is wrongly matched to A and corrected (B's mean stored as A's negative exemplar), later B
utterances are replayed. "vetoed-among-re-match" = the fraction of the legacy wrong re-matches the
veto actually removes; "vetoable share" = fraction of returning voices resembling the rejected
sample ≥ the 0.80 veto floor (the veto's precondition).

| corpus | confusable pairs | replays | legacy re-match | veto fires | **wrong re-matches removed** | vetoable share | same-condition veto rate | owner-collateral |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| AMI | 1176 | 4718 | 0.148 | 0.123 | **0.460** | 0.147 | 0.377 | 0.022 |
| VoxCeleb | 103 | 6077 | 0.254 | 0.041 | **0.123** | 0.046 | 0.121 | 0.016 |

**Reading it.** The veto is deliberately conservative: it only fires when the returning voice
resembles an *explicitly rejected* sample at ≥ 0.80 and at least as much as it resembles the profile
itself. In-room (AMI) that precondition holds often enough to remove **46%** of repeat wrong-matches.
Cross-condition (VoxCeleb), the rejected sample and the returning wrong voice are usually > 0.80
*apart* — the vetoable share collapses to 4.6% and the veto removes only **12%**. It is not a
substitute for fixing the false-auto at first contact: the veto can only act on the *second*
occurrence, after the user has already corrected once, so it does nothing about the 12 first-time
false-autos multi-exemplar introduces above.

## Movement vs the previously-documented operating point

The AMI-full ladder (`SpeakerEvalHarness/LADDER_SWEEP_REPORT.md` §11) certified the auto-name gate at
**0.92 bar + 0.12 margin, 0 false-auto on 148 autos (N=175)** — measured on the ported **average-only**
matcher, i.e. exactly this eval's WITHOUT arm, which reproduces **0 false-auto** here. Adding
multi-exemplar (the WITH arm) is what moves it: on the degraded cross-condition slice the operating
point now shows **~1.6% false-auto** on AMI. The operating point's *thresholds* are unchanged and
still correct for the average path; what changed is that best-of-exemplars scoring lets impostors
reach them. The margin gate remains the right lever — it just needs to be applied to the average
rep, not the best exemplar (see below).

## Recommendation

1. **Keep both features.** +10.9 pp recall and +8.1 pp correct silent recognition on real degraded
   in-room audio is a large, real win, and the negative veto is a correct safety layer.
2. **Retune the auto gate for the exemplar path** so "0 false-auto" is restored without giving back
   the recall. Lowest-risk option: at the auto-accept gate only, compute the best-vs-second **margin
   against each profile's blended *average* similarity**, not its best-exemplar similarity — an
   impostor that only clears via one lucky exemplar then fails the margin, while a genuine owner
   (close on *both* average and exemplar) still passes. Alternatives: a small exemplar-vs-average
   penalty at the gate, or raising `autoAcceptMarginMin` ~0.12 → ~0.15 (blunter; costs some genuine
   autos). Re-run this harness to confirm false-auto → 0 and recall retained before shipping a change.
3. **Strengthen the negative veto for degraded audio.** It under-fires cross-condition because a
   single rejected embedding doesn't cover the wrong voice's other conditions. Give a profile's
   negative exemplars the same multi-condition treatment as its positive ones, or lower `vetoFloor`
   below 0.80 *with* an owner-protection margin — the measured ~2% owner-collateral says don't lower
   it naively.
4. **Do not read these as everyday rates.** This is a deliberate worst case (enroll across all
   qualities, test only on degraded held-out conditions, full-gallery impostors). Clean-audio
   false-auto stays ~0 (consistent with the ladder's clean findings); the 1.6% is the degraded-slice
   upper bound, not the expected production rate.

## Risks / caveats

- **Fingerprint-level, not full-pipeline.** The eval operates on per-(speaker, meeting) mean
  embeddings, which is exactly where `SpeakerExemplarPolicy` / `SpeakerNegativeExemplarPolicy` /
  `bestSimilarity` run, so fidelity for *these features* is high — but it does not replay
  within-meeting consolidation, the review UI, or profile-health demotion. `shouldAutoAccept` is
  evaluated with a named, mature, dispute-free profile, so the eval isolates the match-level gates
  (similarity + margin); the profile-health probation path is out of scope.
- **Worst-case slice.** Degraded-only test conditions + large impostor gallery inflate both the
  recall win and the false-auto/impostor-FA cost relative to mixed real usage.
- **VoxCeleb single-utterance meetings** rarely reach maturity + the 0.92 bar on degraded audio, so
  its auto-recognition numbers are ~0 by construction; it informs recall and the veto, not the gate.
- **Ports cross-checked.** A standalone Python re-implementation of the EMA/exemplar/cosine math
  reproduced the AMI recall (0.549 → 0.659) and false-auto (12/741) to the digit, so the numbers do
  not hinge on a single implementation. The committed numbers are from the Swift path calling the
  real `TranscriptedCore` functions.

## Tests run

- `swift test --filter SpeakerNamingSimulationRunnerTests` — 7/7 pass (existing functional
  regression; confirms the Core test target builds + runs with the exemplar features on `main`).
- `swift test --filter SpeakerExemplarDeltaEvalTests` — passes (this eval; ~3.4 s), writes
  `docs/speaker-eval-exemplar-delta-2026-07.result.json`.
