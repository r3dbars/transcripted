# Voices model upgrade plan — Nemotron 3.5 streaming + FluidAudio 0.15.x

Status: in progress (2026-07-01)
Owner: app/speech
Related: `Sources/Speech/CLAUDE.md`, `docs/qa-test-bench.md`, `.agents/test-matrix.yml`
In-flight speaker work this must sequence around: #1330 (reversible speaker merges), #1175 (ERes2Net voiceprint)

## Progress log

- 2026-07-01: sequencing prerequisites landed — #1330 merged, #1175
  superseded by #1346 (rebased onto main) and merged.
- 2026-07-01: #1345 spike probed 0.15.4 (two CI rounds), breakage list
  recorded on the PR; closed after phase 1 opened.
- 2026-07-01: phase 1 in flight as #1347 — full 0.7.9 → 0.15.4
  migration; app build + all 575 package tests green on first real CI
  round, integration smoke fixed in follow-up.
- 2026-07-01: phase 2 in flight on `claude/phase2-nemotron-optin` —
  `NemotronEngine` (batch entry over the 0.15.4 `StreamingAsrManager`
  protocol, `nemotron1120ms` variant), `nemotron-streaming-0.6b` model
  case, `SpeechModelBetaPreferences` gate + Beta-page toggle, STTRouter
  wiring, fast tests. Default stays Parakeet; Nemotron is hidden unless
  the beta toggle is on and `effectiveModel()` self-heals when it's
  turned back off.

### Phase 1 exit checklist (before #1347 merges)

Cache-continuity finding (source-verified against both FluidAudio tags):
0.15.x renames the v3 cache folder (`parakeet-tdt-0.6b-v3-coreml` →
`parakeet-tdt-0.6b-v3`) and adds one required file
(`JointDecisionv3.mlmodelc`). Without mitigation that means a silent full
~600MB re-download. #1347 ships the mitigation: ParakeetEngine renames the
legacy cache folder in place on first init (so only the new joint file
downloads), `ModelCacheInventory` swaps active/stale names so storage
cleanup can't delete the live cache, and `build.sh` bundles under the new
folder name gated on the new file.

Needs a real Mac with an existing Parakeet install:

```bash
# 1. Confirm the cache migration: after launching the PR build once, the
#    Models dir should show parakeet-tdt-0.6b-v3 (renamed, not re-downloaded)
#    plus a newly fetched JointDecisionv3.mlmodelc — and no -coreml folder:
ls "$HOME/Library/Application Support/Transcripted/FluidAudio/Models"
ls "$HOME/Library/Application Support/Transcripted/FluidAudio/Models/parakeet-tdt-0.6b-v3"

# 2. Quality gate vs the pre-upgrade baseline:
bash scripts/ops/transcripted-qa-bench.sh --mode corpus-compare

# 3. Real-hardware capture smoke:
bash run-live-capture-smoke.sh --skip-build
```

Known accepted deltas on 0.15.4: two Swift-6-mode Sendable warnings in
`DiarizationService` (upstream diarizer manager types); batch segments
now use a fresh caller-owned `TdtDecoderState` per call (replaces the
removed per-source internal state — strictly less cross-talk risk).

## TL;DR

Upgrade FluidAudio from 0.7.9 to 0.15.x and add NVIDIA Nemotron 3.5 ASR
Streaming 0.6B (June 2026 release) as a new opt-in transcription model.
That gets us live-as-you-speak dictation, live meeting transcript preview,
and 40 language-locales — none of which the current batch-only Parakeet
path can do. Parakeet TDT v3 stays the default; nothing changes for
existing users unless they opt in.

## Where we are today

- Primary STT is Parakeet TDT 0.6b v3 via FluidAudio `AsrManager`
  (`Sources/Speech/ParakeetEngine.swift`). Batch-only: audio is buffered
  and transcribed after the user stops talking.
- Whisper Large V3 / Turbo via WhisperKit are the alternate choices
  (`Sources/Support/TranscriptionModelPreferences.swift`).
- FluidAudio is pinned at **0.7.9**
  (`scripts/entrypoints/build-deps.sh:52`). Upstream is at **0.15.4**
  (June 16, 2026). That pin is why live display is dead: 0.7.9 dropped
  the old streaming EOU manager, so `ParakeetAudioEngineSupport.swift`
  carries a no-op `StreamingEouAsrManager` stub and
  `ParakeetEngine.liveDisplayEnabled` is hardcoded `false`.
- Diarization is offline PyAnnote through `OfflineDiarizerManager`
  (`Sources/TranscriptedCore/Services/DiarizationService.swift`), with an
  unused Sortformer streaming path.
- No language selection UI; Parakeet v3 covers 25 European languages,
  anything else means falling back to slower Whisper.

## What the new model buys us

**Nemotron 3.5 ASR Streaming Multilingual 0.6B** (NVIDIA, released
2026-06-04; CoreML port shipped in FluidAudio v0.15.0 "Multistreamer"):

- Cache-aware FastConformer-RNNT — true streaming, processes only new
  audio chunks instead of re-running overlapping buffers.
- Controllable latency 80ms–1s, sub-100ms end-of-utterance detection.
- 40 language-locales in one 600M checkpoint, including CJK, Arabic,
  Hebrew, Thai — well past Parakeet v3's 25 European languages.
- Punctuation + capitalization built in; optional language-ID
  conditioning and auto language detection.
- Same weight class as Parakeet v3 (~600 MB), so no memory-budget
  surprise.

What that means product-wise:

1. **Live dictation text.** Words appear in the overlay while the user is
   still talking, and sub-100ms EoU makes the stop→paste path feel
   instant. This is the single biggest perceived-latency win available.
2. **Live meeting transcript.** The meeting overlay transcript drawer
   (`LiveMeetingCodexPreferences`) can show a rolling transcript during
   capture instead of only after processing. Per-token timings landed in
   FluidAudio v0.15.4, which also tightens segment/speaker alignment.
3. **Real multilingual dictation.** One local model instead of "use
   Whisper and wait."

Also unlocked by the 0.15.x upgrade even without Nemotron:

- Parakeet Unified 0.6B backend (v0.15.3): chunked-attention streaming
  **and** offline batch from one model — a cleaner long-term replacement
  for our batch path.
- Newer diarization backends (LS-EEND streaming, Pyannote Community-1
  with VBx clustering) — out of scope here, noted as follow-up.

## Protecting current users (hard requirements)

- **Default does not change.** `TranscriptionModelPreferences.defaultModel`
  stays `.parakeetTDTv3` for this entire plan. A default switch is a
  separate, data-backed decision later.
- **Preference storage is already forward/backward safe.**
  `preferredModel()` falls back to the default on unknown raw values, so
  a downgrade after selecting Nemotron degrades gracefully to Parakeet.
  Keep that guard intact.
- **No surprise downloads.** The ~600 MB Nemotron download happens only
  when a user selects the model. `ExistingInstallModelPrefetchPolicy`
  must not prefetch non-selected models after an update.
- **Parakeet path stays untouched in the feature phases.** The only
  Parakeet-affecting change is the FluidAudio version bump, which ships
  alone (phase 1) with full regression coverage before any new engine
  code lands.
- **Beta gate first.** New model appears behind a beta opt-in (same
  pattern as `LocalMeetingSummaryPreferences`) before it becomes a
  general Settings choice.
- **Reversible at every step.** Model choice is a Settings dropdown;
  switching back re-initializes via the existing
  `.transcriptionModelPreferenceDidChange` flow. No data migration, no
  storage-format changes.
- **Privacy posture unchanged.** New analytics events carry engine
  identifiers only (extend `transcriptionEngineIdentifier`), never
  transcript text. Any payload-shape change updates
  `SentryPayloadSanitizer.swift` / `AnalyticsPayloadSanitizer.swift` in
  the same PR, per repo policy.

## Sequencing with in-flight speaker-identity work

This plan covers the *transcription* axis (what was said). Two open PRs
cover the *speaker identity* axis (who said it), and they collide with
phase 1 in one specific place, so ordering matters:

- **#1330 — reversible speaker merges (provenance + un-merge).** Safety
  net for wrong auto-merges. Self-contained on the concrete
  `SpeakerDatabase`; no overlap with this plan. Its own description says
  it should land before ERes2Net goes GA. **Land it first.**
- **#1175 — optional ERes2Net voiceprint.** Swaps the identity/matcher
  embedding (WeSpeaker 256-d → ERes2Net 192-d) for cross-call speaker
  matching; much more robust on compressed Zoom/phone audio. It injects
  a `SpeakerSegmentEmbedder` seam into
  `DiarizationService.diarizeOffline` — the same file phase 1's
  FluidAudio bump has to touch. It is currently conflicted against main
  and still needs threshold recalibration plus a model download path.

Order: **#1330 → #1175 (rebased) → phase 1 here.** Whichever of #1175
and phase 1 lands second eats a rebase in `DiarizationService`; doing
the dep bump last means the ERes2Net seam is already in place and the
bump validates against it (its golden-parity test gates regressions).
Do not run both in flight at once.

One more reason not to reorder: FluidAudio 0.15.x ships newer
diarization backends (Pyannote Community-1 with VBx, LS-EEND
streaming). Those may loosen the "WeSpeaker is baked into the diarizer
binary" constraint #1175 works around — worth a quick re-check during
phase 1, but it does not block #1175 landing on today's terms since the
embedder seam is dimension-agnostic either way.

## Phases

### Phase 0 — baseline (no code changes)

Capture the numbers we'll compare against:

- `bash scripts/ops/transcripted-qa-bench.sh --mode corpus-compare` on
  the private meeting corpus → word recall / content-word recall /
  speaker counts with Parakeet v3 at FluidAudio 0.7.9.
- Re-run the dictation latency autoevals (start, stop-speed, recovery —
  see `docs/autoeval-dictation-*.md`) for a perceived-latency baseline.
- Record model cache disk usage via `ModelCacheInventory` for the
  storage-settings story.

### Phase 1 — FluidAudio 0.7.9 → 0.15.x, behavior-neutral

The riskiest step, so it ships alone.

- Bump `FLUID_AUDIO_VERSION` in `scripts/entrypoints/build-deps.sh`;
  rebuild deps (`bash build-deps.sh --force`).
- Fix API breaks in `ParakeetEngine` / `DiarizationService` /
  `MeetingSTTAdapter`. Expect changes around `AsrManager` init, model
  download entry points, and diarizer config types. Keep the EOU stub in
  `ParakeetAudioEngineSupport.swift` for now — deleting it belongs to
  phase 3.
- Confirm model cache layout under
  `~/Library/Application Support/Transcripted/FluidAudio/Models/` is
  unchanged, or add a migration shim in `ModelCacheInventory` +
  `TranscriptedStoragePaths` so existing users don't re-download
  Parakeet v3. **This is a release blocker if it regresses.**
- Exit gate: corpus-compare within noise of phase 0 baseline; full
  verification union (below) green; wake-recovery integration smoke
  green (Parakeet recording lifecycle is entangled with
  `Sources/Reliability/`).

### Phase 2 — NemotronEngine, beta-gated

- New `Sources/Speech/NemotronEngine.swift` mirroring the
  `ParakeetEngine` shape (init states, download progress publishing,
  bundle-first then HuggingFace download, `TRANSCRIPTED_DISABLE_FILE_LOGGER`
  honored in tests). Batch entry point uses the streaming manager's
  final-pass output so `transcribeSegment(samples:source:)` keeps its
  contract for meetings/imported audio.
- Add `case nemotron35Streaming = "nemotron-3.5-streaming"` to
  `TranscriptionModelChoice` with title/summary/size/engine-identifier
  metadata; extend the `STTRouter` switch statements
  (`isModelLoaded()`, `initialize()`, `transcribeSegment()`).
- Gate visibility: new `Sources/Support/` beta preference (copy the
  `LocalMeetingSummaryPreferences` pattern); the Settings model picker
  (`Sources/UI/Settings/TranscriptedSettingsRows.swift`) only lists
  Nemotron when the beta toggle is on. `isRuntimeAvailable` returns
  false when gated so `effectiveModel()` self-heals if the flag is
  turned off after selection.
- `MeetingSTTAdapter.prepare(model:)` learns the new case so queued
  meeting transcription can warm it up.
- Register new model dir in `ModelCacheInventory` so the storage
  settings can report/clean it.
- Tests: extend `Tests/TranscriptionModelPreferencesTests.swift`, add
  router-routing fast test, register any new root test file in
  `Tests/FastTests.manifest` (the runner does not auto-discover).

### Phase 3 — live streaming display

- Replace the `StreamingEouAsrManager` stub with the real FluidAudio
  0.15.x streaming manager; delete the 0.7.9 workaround comment block.
- Wire partial-hypothesis callbacks into the dictation overlay
  (`Sources/UI/Overlay/DictationSessionController.swift`): show gray
  provisional text, replace with the final pass on EoU. Flip
  `liveDisplayEnabled` into a computed property: on when the selected
  model streams, off for batch models — Parakeet/Whisper users see
  exactly today's behavior.
- Meeting drawer: feed rolling partials into the existing live transcript
  drawer. Keep CoreAudio threading rules — partials hop off the capture
  queue via deep-copied buffers before touching `@MainActor` UI state.
- Sub-100ms EoU lets us tighten the dictation stop→paste timeout
  (`TranscriptedConstants`) for streaming models only; leave batch
  timings alone.

### Phase 4 — language preference (small)

- Optional "Spoken language" preference in Settings: default
  auto-detect, explicit locale list fed to Nemotron's language-ID
  conditioning for users whose language gets misdetected. New
  `Sources/Support/` preference file + row; ignored by engines that
  don't support hints.

### Phase 5 — measure, then widen

- Beta cohort via `bash build-beta.sh` builds; watch the existing
  engine-identifier analytics (opt-in rates, failure events,
  fallback-to-default rates).
- Corpus-compare with Nemotron selected; English dictation A/B against
  the phase 0 latency autoevals.
- Exit gate to general availability (visible without beta flag, still
  not default): corpus recall within agreed floor of Parakeet v3
  (`corpus-min-recall 0.45` / `corpus-min-content-recall 0.35` as
  absolute floors, phase 0 numbers as the real bar), no elevated crash
  or model-init failure signal from the beta cohort.
- A future default flip gets its own proposal with this data attached.

## Risks

| Risk | Mitigation |
| --- | --- |
| FluidAudio 0.7.9→0.15.x API churn breaks Parakeet/diarization | Phase 1 ships alone, corpus-compare + integration smoke gate it |
| Model cache path changes force a silent ~600 MB re-download for existing users | Explicit phase 1 check; migration shim if layout moved; release blocker otherwise |
| Nemotron English accuracy below Parakeet v3 for the dictation-heavy user base | It stays opt-in; corpus + autoeval comparison before GA; default unchanged |
| Streaming partials on the wrong thread violate CoreAudio real-time rules | Deep-copy buffers, dispatch off capture queue; existing repo threading rules apply, integration smoke covers wake/recovery |
| Two 600 MB models cached for users who try both | Already surfaced/cleanable via `ModelCacheInventory` storage settings |
| Downgrade after selecting new model | Enum fallback already lands users on Parakeet default; verified by preference tests |

## Verification (per `.agents/test-matrix.yml`, union)

Touching `Sources/Speech/**`, `Sources/Support/**`, `Sources/Meeting/**`,
`Sources/UI/**`, `build-deps.sh`, and tests means:

```bash
bash build-deps.sh --force
bash build.sh --no-open
bash run-tests.sh
bash run-integration-smoke.sh
swift test                       # TranscriptedCore seam
bash run-e2e-smoke.sh            # artifact contract
```

Plus per-phase: corpus-compare (phases 0/1/5), live-capture smoke on real
hardware before any beta build that changes the recording path, and
`SKIP_NOTARIZATION=1 bash build-beta.sh '' <user>` before phase 5 beta
distribution.

## Explicit non-goals

- Changing the default model.
- Removing Parakeet v3 or the Whisper choices.
- Diarization backend swap (LS-EEND / Pyannote Community-1) — separate
  follow-up once phase 1's FluidAudio bump makes them reachable.
- Speaker-identity embedding changes — that axis is owned by #1175
  (ERes2Net) and #1330 (reversible merges); see sequencing above.
- TTS/read-back features (FluidAudio 0.15.x ships Kokoro/PocketTTS; the
  app is transcription-only and stays that way for now).
