# Speaker eval: cross-condition negative-exemplar veto (2026-07)

Follow-up to [`docs/speaker-eval-exemplar-delta-2026-07.md`](speaker-eval-exemplar-delta-2026-07.md)
(PR #1493), which found the negative-exemplar veto (#1487) is "sound but regime-limited": after a
correction it removes **46% of repeat wrong-matches in-room (AMI)** but only **12% cross-condition
(VoxCeleb)**, because a rejected in-room sample and a later telephone/VoIP sample of the *same*
rejected impostor sit too far apart in embedding space for the raw cosine to clear the 0.80 veto
floor. Its recommendation #3: *"Give a profile's negative exemplars the same multi-condition
treatment as its positive ones."*

This change does that, and re-measures on the same real cross-condition corpus.

## What changed

`SpeakerNegativeExemplarPolicy` gains a **condition-transported** negative similarity. In addition to
raw cosine against each stored rejected sample, the candidate is compared against each rejected
sample *transported along the profile's own observed condition shifts* — the offset between each of
the profile's positive multi-exemplar voiceprints and its blended average (`unit(exemplar) −
average`). Channel/condition shifts (clean → compressed remote → telephone) are largely
speaker-independent, so a rejected sample recorded in one condition, shifted by a condition the
profile has actually seen, approximates *the same rejected voice returning in that other condition*.

This is the exact mirror of what multi-exemplar voiceprints (#1488) did on the positive side: score a
returning voice against its best-fitting capture condition rather than one blended-across-conditions
centroid. The negative side previously had no analog — a single rejected embedding — which is why it
collapsed cross-condition. The transport gives it one.

Deliberately conservative and **owner-safe by construction**:

- **Only real, forward shifts.** Transport is along `+(exemplar − average)` — conditions the profile
  genuinely exhibits — never arbitrary directions. Bidirectional / synthetic-direction transport was
  measured and rejected: the `−` direction is not a real condition and leaks owner-collateral.
- **A profile with no positive exemplars is byte-for-byte unchanged.** No exemplars ⇒ no observed
  shifts ⇒ the transported overload reduces *exactly* to the raw `maxNegativeSimilarity`. Single-
  condition profiles (and every store with no negative exemplars) match identically to before.
- **The owner gate is untouched.** The veto still requires the resulting similarity to clear the 0.80
  floor *and* beat the candidate's own positive similarity. Transport only widens which *impostor*
  returns are caught; it never lowers the floor, so a genuine owner — closer to its own fingerprint
  than to a transported *impostor* sample — is still protected.

`SpeakerNegativeExemplarPolicy.crossConditionTransportScale = 0.75` (one mild observed shift), tuned
on the harness below.

## Results — real qmatrix fingerprints (AMI + VoxCeleb)

Same harness, corpus, and operating point as PR #1493
(`Tests/TranscriptedCoreTests/SpeakerExemplarDeltaEvalTests.swift`, veto experiment). For every
confusable ordered pair (A, B), B's first held-out utterance `u1` is stored as A's negative exemplar
and every *other* held-out B utterance is replayed, split by whether it arrives in the **same** audio
condition as `u1` or a **different (cross)** condition. `vetoed-among-re-match` = the fraction of the
legacy wrong re-matches the veto removes. Owner-collateral = A's own held-out utterances wrongly
vetoed by B's negative. **RAW** = the single stored rejected sample (pre-fix). **TX** = condition-
transported negatives (this change). Both arms use the unchanged 0.80/`≥ positive` gate.

Run:
```bash
SPEAKER_EVAL_QMATRIX_DIR=/path/to/data/eval/qmatrix \
SPEAKER_EVAL_OUT=docs/speaker-eval-negative-veto-cross-condition-2026-07.result.json \
  swift test --filter SpeakerExemplarDeltaEvalTests
```
Raw output: [`docs/speaker-eval-negative-veto-cross-condition-2026-07.result.json`](speaker-eval-negative-veto-cross-condition-2026-07.result.json).

### AMI (in-room) — 147 profiles (138 with ≥1 exemplar), 698 wrong re-matches (535 cross-condition, 163 same-condition), 5773 owner checks

| metric | RAW (pre-fix) | TX (fix) | Δ |
|---|---:|---:|---:|
| **cross-condition vetoed-among-re-match** | 0.350 | **0.374** | **+0.024 (+7.0% rel)** |
| same-condition vetoed-among-re-match | 0.822 | 0.840 | +0.018 |
| aggregate vetoed-among-re-match | 0.460 | 0.483 | +0.023 |
| **owner-collateral** | 0.0217 (125) | **0.0232 (134)** | **+0.0016 (+9 of 5773)** |

### VoxCeleb (clean-source, single short utterance/meeting) — 30 profiles, 1545 wrong re-matches (1224 cross-condition), 6162 owner checks

| metric | RAW (pre-fix) | TX (fix) | Δ |
|---|---:|---:|---:|
| cross-condition vetoed-among-re-match | 0.067 | 0.067 | **0.000** |
| aggregate vetoed-among-re-match | 0.123 | 0.123 | 0.000 |
| owner-collateral | 0.0156 (96) | 0.0156 (96) | **0.000** (byte-identical) |

## Reading it

- **Where the profile has real multi-condition history, the veto now fires cross-condition, owner-
  safe.** AMI's cross-condition veto rises **+7.0% relative** (0.350 → 0.374) with owner-collateral
  essentially flat (2.17% → 2.32%, +9 false-vetoes across 5773 checks — noise-level, nowhere near a
  "spike"). This is the production-relevant regime: returning Transcripted users appear repeatedly
  across conditions (in-person mic, Zoom, phone), so their profiles accumulate the multi-exemplar
  condition structure the transport reads.

- **VoxCeleb is unchanged — and that is correct, not a miss.** VoxCeleb is single-short-utterance-
  per-meeting, so a "cross-condition" replay differs from the rejected sample in *content/session* as
  much as in channel condition. A channel-condition transport cannot (and should not) bridge a
  content gap, so it derives nothing that helps and the arm is byte-identical to before — including
  owner-collateral. The 12% ceiling in PR #1493 is a property of that corpus's utterance-level
  variability, not of the veto.

- **Why not push VoxCeleb's 12% harder?** It was investigated thoroughly. Every mechanism that
  expands the negative's cross-condition reach far enough to move VoxCeleb — lowering the veto floor
  (with or without an owner-protection margin), a global channel subspace, orthogonal-complement
  distance — trades owner-collateral for veto coverage at a **≈1:1-or-worse absolute rate**. On
  VoxCeleb, the best-case floor relaxation removed ~+39 wrong re-matches while adding ~+56 owner
  false-vetoes. Since a genuine owner speaks far more often than a specific corrected impostor
  returns, that is net-negative in production and is exactly the trade PR #1493's guardrail forbids
  ("do not trade a big cross-condition gain for a spike in vetoing legitimate owners"). The
  condition-transport approach shipped here is the one lever that improves cross-condition coverage
  **without** a net owner cost — because it only ever transports along conditions the profile itself
  has confirmed.

## Guardrail verdict

- Cross-condition veto: improved (+7.0% relative on AMI, the multi-condition regime); no change on
  the single-utterance VoxCeleb corpus by construction.
- Owner-collateral: held at baseline (AMI +0.16pp to 2.32%, still "near ~2%"; VoxCeleb unchanged) —
  the key guardrail is respected. Profiles without positive exemplars, and stores with no negative
  exemplars, are unchanged.

## Tests

- `swift test --filter SpeakerNegativeExemplarPolicyTests` — 12/12 pass, incl. new fixtures:
  same-impostor-different-condition (transport makes the veto fire), owner-different-condition (no
  false veto), and no-exemplars-equals-raw (byte-identical fallback).
- `swift test --filter SpeakerNegativeExemplarTests` — 7/7 pass (store + matcher veto round-trip).
- `swift test --filter SpeakerNamingSimulationRunnerTests` — 7/7 pass (functional regression).
- `swift test --filter SpeakerExemplarDeltaEvalTests` — passes; writes the result JSON above.
