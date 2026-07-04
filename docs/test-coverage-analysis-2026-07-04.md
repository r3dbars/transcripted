# Test Coverage Analysis — 2026-07-04

Point-in-time audit of where automated test coverage is thin. Use with
`docs/test-automation-strategy.md` (last updated 2026-06-06, strategy-level
gap list) and `.agents/test-matrix.yml` (path-to-check map). This doc is
file-level: which source files have zero test references today, and why that
matters.

## Method

Compared source files under `Sources/` and `Tools/` against everything under
`Tests/` (root fast tests, `Tests/TranscriptedCoreTests/`, `Tests/Integration/`,
`Tests/E2E/`) by grepping for each type/file name across the whole `Tests/`
tree — not just matching filenames, so indirect coverage (a helper tested
through a caller) still counts. A "0 refs" result below means the symbol name
does not appear anywhere in `Tests/`, i.e. no fast test, package test, or smoke
test exercises that file at all, directly or transitively (as far as name
references go).

## Current inventory (counts)

- `Sources/`: 312 Swift files across 12 subsystems (UI 85, TranscriptedCore 81,
  Support 42, Meeting 39, Observability 32, Speech 16, Timeline 6, Dictation 6,
  Capture 2, Reliability 1, Accessibility 1, Beta 1).
- `Tests/`: 227 Swift files (162 root fast tests registered in
  `Tests/FastTests.manifest`, plus `TranscriptedCoreTests/`, `Integration/`,
  `E2E/`).
- `Tools/`: TranscriptedQA 30 src / 8 test, TranscriptedMCP 14/11,
  TranscriptedCLI 13/4, TranscriptedCaptureKit 6/3, SpeakerEvalHarness 2/0.
- CI (`swift-ci.yml`) runs fast tests + `swift test` + integration smoke + E2E
  smoke + all Tools package tests on every PR. No coverage number is measured
  or gated in CI — `run-tests.sh --coverage` exists but nothing consumes its
  output as a threshold or trend.
- UI automation (`--mode ui`, Accessibility-driven) and hardware smokes
  (live-capture, slow-pasteback) are real but local-only / `workflow_dispatch`-
  only; they never run on a normal PR.

## Concrete gaps found (zero test references)

### 1. STT engines — the actual transcription logic is untested

- `Sources/Speech/WhisperEngine.swift` (267 lines) — `Tests/WhisperCustomDictionaryTests.swift` says outright: *"WhisperEngine can't be instantiated in the fast runner (it pulls in [the real model])"*, and instead greps the source text for a specific string. That's a text-contract test, not a behavior test — retry logic, error handling, and transcript post-processing in the engine itself run untested.
- `Sources/Speech/NemotronEngine.swift` (259 lines) — zero references anywhere in `Tests/`. No test of any kind.
- `Sources/Speech/ParakeetAudioDeviceLookup.swift` and `ParakeetAudioEngineSupport.swift` — zero references (ParakeetEngine itself has 7 refs, so the main engine has some coverage; these two support files don't).

Why it matters: these are the core value-prop paths (accuracy, fallback,
device selection). A regression in fallback-on-failure or device-lookup logic
would only surface via slow-pasteback/live-capture smokes (local, hardware-
gated) or a user report — nothing in CI would catch it.

**Recommendation**: extract the parts of these engines that don't need the
real model weights (input validation, retry/fallback decision logic, error
mapping, device selection) behind a seam that can be unit tested with a fake
transcriber, the same way `MeetingSTTAdapter` already gets partial coverage
by testing the adapter layer rather than the underlying model.

### 2. Core audio capture primitives — untested despite being the top reliability risk

- `Sources/TranscriptedCore/Audio/SystemAudioBufferWriter.swift` (253 lines) — 0 refs
- `Sources/TranscriptedCore/Audio/SystemAudioProcessTap.swift` (238 lines) — 0 refs
- `Sources/TranscriptedCore/Audio/AudioDeviceRecovery.swift` (340 lines) — 0 refs
- `Sources/TranscriptedCore/Audio/CoreAudioUtils.swift` (237 lines) — 0 refs

`docs/test-automation-strategy.md` already flags audio as the area needing
the most synthetic-fixture work, and synthetic fixtures do exist for
route-churn / ducking / stop-timeout scenarios — but those fixtures appear to
exercise higher-level session/controller code, not these four low-level
primitives directly. 1,068 lines of CoreAudio-adjacent logic (buffer writing,
process-tap setup, device-recovery state machines) with no direct test
reference is a meaningful blind spot given the project's own threading rules
call this the most dangerous code in the app (real-time callbacks, no
locks/allocations allowed inline).

**Recommendation**: add targeted fast/package tests for the pure decision
logic in `AudioDeviceRecovery` (state transitions, retry counts) independent
of real CoreAudio calls, and a package test for `SystemAudioBufferWriter`'s
buffering/flush behavior using synthetic PCM buffers.

### 3. Speaker matching/naming persistence — untested despite a dedicated eval harness

- `Sources/TranscriptedCore/Speaker/SpeakerMatchOutcomeStore.swift` (231 lines) — 0 refs
- `Sources/TranscriptedCore/Speaker/SpeakerProfileProvenance.swift` (749 lines!) — 0 refs

`Tools/SpeakerEvalHarness` evaluates naming/clustering *quality* against AMI
fixtures, but that's a different concern from correctness of the persistence
layer these two files implement (how match outcomes and profile provenance
get stored/read back). A 749-line file with zero test coverage is the single
largest untested file found in this audit.

**Recommendation**: add package tests for `SpeakerProfileProvenance` (round-
trip persistence, provenance merge/conflict rules) and
`SpeakerMatchOutcomeStore` (outcome recording, read-back) independent of the
eval harness's quality metrics.

### 4. Stats subsystem — completely untested

- `Sources/TranscriptedCore/Stats/StatsService.swift` (368 lines) — 0 refs
- `Sources/TranscriptedCore/Stats/StatsDatabaseModels.swift` (100 lines) — 0 refs
- `Sources/TranscriptedCore/Stats/StatsDatabaseQueries.swift` (271 lines) — 0 refs

`Tests/README.md` claims `swift test` covers "stats" among the Core package
test surfaces, but no test file references any of these three types by name.
Either the stats tests were removed/renamed and the doc is stale, or this
was never covered — either way it's worth reconciling. 739 lines of database
query/model logic with no test is a gap regardless of which explanation is
right.

**Recommendation**: add `StatsDatabaseQueries`/`StatsService` package tests
(query correctness against a seeded in-memory/temp SQLite fixture), and
correct `Tests/README.md` if it's currently overclaiming coverage.

### 5. Privacy sanitization — inconsistent coverage between app and core layers

- `Sources/Observability/SentryPayloadSanitizer.swift` — 5 refs (well tested)
- `Sources/Observability/AnalyticsPayloadSanitizer.swift` — 6 refs (well tested)
- `Sources/Observability/LocalObservabilityPayloadSanitizer.swift` — 1 ref
- `Sources/Observability/PayloadSanitizationCore.swift` — 0 refs
- `Sources/TranscriptedCore/Logging/LogPrivacySanitizer.swift` (348 lines) — 0 refs

`CLAUDE.md`/`AGENTS.md` are explicit that privacy sanitizers must ship with
tests when payload shape changes, and that discipline clearly holds for the
two app-side sanitizers. It does not hold for the shared
`PayloadSanitizationCore` logic those two build on, or for the Core-package
`LogPrivacySanitizer` (which is presumably what keeps raw transcript text out
of `TranscriptedCore`'s own logs, per the "never send raw transcript text"
rule). Given how much weight this repo puts on privacy-safe telemetry, the
Core-side sanitizer being untested is the most policy-relevant gap in this
audit.

**Recommendation**: bring `LogPrivacySanitizer` and `PayloadSanitizationCore`
up to the same test standard as the two app-side sanitizers — same redaction
categories (titles, paths, emails, URLs, device names) asserted directly
against these types, not just against their callers.

### 6. User-facing preference/controller singletons with no dedicated test

Zero-ref, logic-bearing (non-SwiftUI-view) files:

- `Sources/Support/LaunchAtLoginController.swift`
- `Sources/Support/SpeakerEmbedderFactory.swift`
- `Sources/Support/MissedCallNudgePreferences.swift`
- `Sources/UI/AccessibilityDisplayPolicy.swift`
- `Sources/UI/WaveformLayer.swift`
- `Sources/UI/HotkeyRecorderAppKitView.swift` (AppKit wrapper — lower priority, mostly glue)
- `Sources/Timeline/InputIdleSnapshot.swift` (23 lines — low priority, trivial)

`AnalyticsPreferences` and `CrashReportingPreferences` (both default-on,
user-facing, privacy-relevant per `AGENTS.md` section 172) have only 3 and 1
references respectively — thin given they gate whether telemetry leaves the
device at all.

**Recommendation**: prioritize `LaunchAtLoginController` and
`SpeakerEmbedderFactory` (real branching logic, not just glue) and shore up
`AnalyticsPreferences`/`CrashReportingPreferences` default-state and
toggle-persistence tests, since both are named explicitly in `AGENTS.md` as
requiring the preference toggle to keep working.

### 7. Timeline capture engine

- `Sources/Timeline/ScreenCaptureEngine.swift` (498 lines) — 0 refs.

This is the largest file in the Timeline subsystem (Dayflow-style screenshot
capture) and the only one of the six Timeline files with no test reference at
all — `TimelineDatabase`, `ActiveDisplayTracker`, `ForegroundAppSampler`, and
`TimelineRetentionManager` all have at least one. Given Timeline already ships
retention/compression logic that touches user disk space and screenshots
directly, the capture engine driving all of it being untested is worth
closing before extending Timeline further.

## Lower-priority / expected gaps (not flagged as action items)

- Most of `Sources/UI/` (SwiftUI views, menu bar rows, settings pages) has no
  matching unit test — expected, since this repo's stated strategy is to
  cover UI through Accessibility-driven `--mode ui` smoke rather than
  view-level unit tests. The real gap here (already tracked in
  `docs/test-automation-strategy.md`) is that `--mode ui` doesn't run in CI,
  so a UI regression only surfaces on a local machine with Accessibility
  permission granted.
- `ContextCaptureEngine.swift` (779 lines, `Sources/Capture/`) has some
  coverage (4 refs) but is large relative to its test surface; worth a
  closer line-by-line look in a follow-up rather than flagging as fully
  uncovered here.
- Hardware-dependent smokes (live capture, slow pasteback) are real tests but
  structurally can't run in hosted CI — already documented as a known,
  intentional limitation in `swift-ci.yml`.

## Summary of recommended next actions, in priority order

1. Add direct tests for `LogPrivacySanitizer` and `PayloadSanitizationCore` —
   closes the biggest privacy-policy inconsistency.
2. Add package tests for `SpeakerProfileProvenance` and
   `SpeakerMatchOutcomeStore` — closes the single largest untested file (749
   lines) in a feature area (speaker naming) that already gets significant
   product attention elsewhere.
3. Add a decision-logic seam + tests for `NemotronEngine`/`WhisperEngine`
   fallback and retry behavior, decoupled from real model weights.
4. Add `StatsService`/`StatsDatabaseQueries` tests and reconcile
   `Tests/README.md`'s claim that stats is already covered.
5. Add tests for the four untested Core audio primitives
   (`SystemAudioBufferWriter`, `SystemAudioProcessTap`, `AudioDeviceRecovery`,
   `CoreAudioUtils`), focused on pure logic (state machines, buffering math)
   rather than requiring real CoreAudio hardware.
6. Add a `ScreenCaptureEngine` test for its non-hardware-dependent logic
   (frame scheduling/dedup decisions), matching the coverage level of its
   Timeline siblings.
7. Wire `run-tests.sh --coverage` into a periodic (nightly, not per-PR)
   report so coverage drift is visible over time instead of only being
   knowable by running the flag locally.
