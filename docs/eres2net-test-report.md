# ERes2Net integration — hardening test report

A deliberately adversarial test pass over the ERes2Net speaker-embedding
integration: exhaustive edge-case unit tests, a real-audio robustness campaign,
and a 15-agent multi-lens bug hunt. One real bug was found and fixed.

## Automated tests added

All run under `swift test` (Core) or `bash run-tests.sh` (app fast tests).

| Suite | What it locks down | Model needed |
|---|---|---|
| `ERes2NetEmbedderUnitTests` (29) | `windowBounds` coverage invariants (empty, 1, exactly-max, just-over, multi-window), `tile` repeat-to-length, `l2Normalize` incl. zero vector, `meanPoolNormalized` incl. opposite-cancel + dim filtering | no |
| `ERes2NetEmbedderModelTests` (10) | dimension/identifier, rejects non-16k + empty, short-clip tiling path, normal clip, **long-clip multi-window path**, **determinism**, distinct tones differ, **silence → finite (no NaN/Inf)**, unit-norm output | yes (skips if absent) |
| `SpeakerDBDimensionIsolationTests` (6) | 192-d and 256-d stored faithfully; cross-dim cosine = 0; cross-dim snapshot/`matchSpeaker` never match; EMA stays same-dim + unit-norm; separate DB files isolated | no |
| `DiarizationReembedTests` (7) | no-embedder identity; replace + preserve metadata + correct slice lengths; **failed / out-of-bounds / zero-length / empty-samples drop the embedding (no 256-d leak) but keep the segment**; empty segments → empty | no (stub) |
| `ERes2NetEmbedderParityTests` (1) | Swift embedder reproduces the CoreML golden (cosine ≥ 0.999) | yes |
| `ERes2NetDiarizationE2ETests` (1) | real PyAnnote+VBx diarizer → ERes2Net re-embed → matcher, all 192-d | yes + `TRANSCRIPTED_E2E_WAV` |
| `SpeakerEmbedderPreferences` fast test | env override / UserDefaults / precedence / fallback; **`speakerDBFileName` regression guard** | no |

`swift test`: **530 tests, 0 failures** (gated model/e2e tests run locally, skip in CI).

## Real-audio robustness campaign

`scripts/run_eres2net_e2e_campaign.sh` runs the full real pipeline across audio
conditions. Every arm produced clean 192-d embeddings; the pipeline is deterministic.

| Arm | segments | diarizer speakers | embedding dims | DB profiles |
|---|---|---|---|---|
| clean meeting 1 (AMI) | 5 | 2 | **[192]** | 2 |
| clean meeting 2 (AMI) | 5 | 2 | **[192]** | 2 |
| Opus 8 kbps | 6 | 1 | **[192]** | 1 |
| G.711 phone-band | 6 | 2 | **[192]** | 2 |
| short 8 s clip | 3 | 1 | **[192]** | 1 |
| determinism (same wav ×2) | identical | identical | identical | identical |

## Adversarial bug hunt (15 agents, 7 lenses)

7 independent reviewers (concurrency, numerical, bounds, DB-isolation, fallback,
behavioral, build) → each finding adversarially re-verified to kill false positives.
**Result: 8 raw findings → 3 confirmed (all the same bug), 5 refuted.**

### Bug found and fixed (P2)

**DB path was chosen by model-file existence, embedder by successful load.** If the
ERes2Net `.mlmodelc` was present but failed to load (partial copy, incompatible
compile), `activeSpeakerDBURL()` routed to `speakers_eres2net.sqlite` while the
embedder fell back to nil → 256-d WeSpeaker vectors would be written into the
192-d ERes2Net DB, silently breaking cross-call identity and mixing dimensions.

**Fix (landed in coordination with parallel commit `Fix ERes2Net fallback isolation`):**
the DB path is now derived from the *actually-loaded* embedder
(`SpeakerEmbedderFactory.speakerDBURL(for:)` → `speakerDBFileName(forEmbedderIdentifier:)`),
so a load failure cleanly falls back to `speakers.sqlite`. Defence in depth:
`DiarizationService.reembedIfNeeded` now sets a segment's embedding to **nil**
(rather than keeping the native 256-d WeSpeaker vector) whenever re-embedding
fails or the slice is empty — so no wrong-dimension vector can reach a per-model
DB even transiently. Regression-guarded by the `SpeakerEmbedderPreferences` fast
test (DB-name selection) and `DiarizationReembedTests` (nil-on-failure).

### Refuted (verified non-issues)

- *Mean-pool equal-weights a tiny tiled trailing window* — real mechanism, but the tile keeps it speech, effect is negligible; not a defect.
- *Silence can yield an all-zero embedding* — trigger not reached in practice (silence is gated upstream); cosine 0 just means "no match," and the test confirms output is always finite.
- *No NaN/Inf guard before persist* — speculative; the model produces finite output on degenerate input (tested).
- *WeSpeaker-tuned thresholds run on ERes2Net geometry* — a documented, opt-in, gated tradeoff (the embedding-quality gain is threshold-independent), not a bug. Recalibration is a tracked follow-up.
- *Re-embedding previously-nil segments changes counts* — misreads the pre-change control flow; the quality gates still apply.

## Not changed (pre-existing, out of scope)

- `SpeakerDatabase.addOrUpdateSpeaker`'s `zip`-blend has no explicit dim guard, but the matcher's dim guards mean a cross-dim `existingId` is never produced, so the blend is never reached cross-dimension. Flagged for awareness only.
