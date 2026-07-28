# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

For day-to-day agent work, start with `AGENT_START.md` and treat `AGENTS.md` as the canonical workflow contract. This file is the Claude-oriented orientation layer on top of those.

## What this repo is

`main` is the current Transcripted app, derived from the earlier Draft codebase. It is a macOS menubar app (macOS 26+, Apple Silicon only) for:

- dictation capture with paste-back into the focused editor
- meeting capture (local mic + system audio) with local transcription
- imported-audio and imported-video transcription (video imports extract the audio track; see `MeetingImportedAudioPreparer`)
- optional local-speaker review for people sharing the room mic
- agent-readable Markdown output saved to disk

The old standalone Transcripted app is preserved on branch `legacy/transcripted-standalone` and tag `pre-draft-takeover-2026-04-06`. The older drafting/ghostwriting flow is not active on `main` and no compatibility hooks from that routing remain in the source tree.

## First reads

Before making assumptions about the codebase:

1. `AGENT_START.md` — short safe-start path
2. `README.md` — public product overview
3. `AGENTS.md` — canonical workflow contract (build/test rules, voice, observability)
4. `docs/repo-layout.md` — live directory map and command surface
5. `docs/agent-onboarding.md` — doc trust order
6. `Sources/CLAUDE.md` — app target orientation
7. the nearest local `CLAUDE.md` for the area you are changing (see "Subsystem docs" below)

When docs disagree, split the decision: `AGENTS.md` and `.agents/test-matrix.yml` win for workflow contracts; current source wins for runtime behavior and file existence; local `CLAUDE.md` files explain subsystem intent when their file lists still match the tree.

## Build and test

Common commands (thin root wrappers; implementations live under `scripts/entrypoints/`):

```bash
bash build-deps.sh                 # build/refresh prebuilt deps under deps-libs/, deps-frameworks/, deps-modules/
bash build.sh --no-open            # authoritative app build for non-interactive verification
bash run-tests.sh                  # convention-discovered root fast tests
bash run-integration-smoke.sh      # app/core linkage + wake recovery + MicRecordingFileMerger
bash run-e2e-smoke.sh              # deterministic release-critical artifact smoke (no mic/TCC)
bash run-live-capture-smoke.sh     # local hardware/TCC smoke (needs mic + System Audio Recording perms)
bash run-slow-pasteback-smoke.sh   # paste-back timing smoke for the clipboard-restoring paster
bash run-daily-audio-reliability.sh  # daily audio-reliability check harness
swift test                         # Swift Package tests for TranscriptedCore seam only
bash build-beta.sh '' <user>       # signed beta/distribution build; first arg is compatibility-only
bash scripts/dev/agent-preflight.sh  # prints suggested verification map for the current branch diff
```

Verification rules (mirror `.agents/test-matrix.yml`; if a change matches multiple rules, run the union):

- Touched `Sources/**/*.swift` or root `Tests/*.swift` → `bash build.sh --no-open` + `bash run-tests.sh`
- Touched `Sources/Meeting/**`, `Sources/TranscriptedCore/**`, or `Tests/Integration/**` → `bash build-deps.sh --force` + `bash build.sh --no-open` + `bash run-tests.sh` + `bash run-integration-smoke.sh`
- Touched `Tests/E2E/**`, `run-e2e-smoke.sh`, or `scripts/entrypoints/run-e2e-smoke.sh` → `python3 scripts/dev/check-build-source-lists.py` + `bash run-e2e-smoke.sh`
- Touched the slow-pasteback smoke path (`Tests/E2E/SlowPastebackSmoke.swift`, `Sources/Support/ClipboardRestoringTextPaster.swift`, `Sources/Support/TranscriptedConstants.swift`, `run-slow-pasteback-smoke.sh`) → `python3 scripts/dev/check-build-source-lists.py` + `bash run-slow-pasteback-smoke.sh`
- Touched QA bench/corpus files (`scripts/ops/transcripted-qa-bench.sh`, `scripts/ops/validate-meeting-corpus.py`, `scripts/ops/compare-meeting-corpus.py`, `docs/qa-test-bench.md`) → quick QA bench + Python compile checks
- Touched live-capture smoke paths (`Tests/TranscriptedCoreTests/AudioTests/LiveCaptureSmokeTests.swift`, `run-live-capture-smoke.sh`, `scripts/entrypoints/run-live-capture-smoke.sh`) → `bash run-live-capture-smoke.sh --skip-build`
- Touched `Package.swift`, `Sources/TranscriptedCore/**`, or `Tests/TranscriptedCoreTests/**` → `bash build-deps.sh --force` + `bash build.sh --no-open` + `bash run-tests.sh` + `bash run-integration-smoke.sh` + `swift test`
- Touched `Sources/Observability/**`, `Info.plist`, `docs/sparkle-updates.md`, or `docs/appcast.xml` → `bash build.sh --no-open` + `bash run-tests.sh`
- Touched release path (`build-beta.sh`, `scripts/entrypoints/build-beta.sh`, `scripts/release/**`, `docs/release-packaging.md`, `docs/sparkle-updates.md`, `Casks/**`, `docs/appcast.xml`) → `bash build.sh --no-open` + `bash run-tests.sh` + `SKIP_NOTARIZATION=1 bash build-beta.sh '' <user-name>`
- Touched `Tools/TranscriptedCaptureKit/**` → `swift test --package-path Tools/TranscriptedCaptureKit` + `swift test --package-path Tools/TranscriptedCLI` + `swift test --package-path Tools/TranscriptedMCP` + `bash run-e2e-smoke.sh`
- Touched `Tools/TranscriptedCLI/**` → `swift test --package-path Tools/TranscriptedCLI`
- Touched `Tools/TranscriptedMCP/**` → `swift test --package-path Tools/TranscriptedMCP` + `bash run-e2e-smoke.sh`
- Touched `Tools/TranscriptedQA/**` → `swift test --package-path Tools/TranscriptedQA`
- Touched `Tools/SpeakerEvalHarness/**` or its `scripts/*speaker*`/`scripts/download_ami.sh` helpers → `bash build-deps.sh --force` + `swift build --package-path Tools/SpeakerEvalHarness` + the harness's compile/syntax checks (see `.agents/test-matrix.yml`)
- Touched docs/agent files (`README.md`, `AGENT_START.md`, `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`, `WORKFLOW.md`, `docs/**`, `.agents/**`, `.github/**`) → `scripts/dev/agent-preflight.sh`

### Fast-test gotchas

`run-tests.sh` is a custom `swiftc` runner, not XCTest:

- Root fast tests are discovered automatically by convention: `Tests/FooTests.swift` must expose exactly one top-level `testFoo()` entry function.
- Moving a source file that the runner compiles directly requires updating the script.
- The runner fails before compilation when the convention entry function is missing or duplicated.
- `Tests/TranscriptedCoreTests/` is a separate SPM target — run via `swift test`, not `run-tests.sh`.
- `bash run-tests.sh --coverage` writes LLVM coverage under `build/coverage/fast-tests/`.

### Running a single test

Fast tests are top-level functions, not XCTest cases. To run one in isolation, use `bash run-tests.sh --filter <entryFn|File>` (e.g. `bash run-tests.sh --filter testPayloadSanitizationCore`); the selector matches an entry function, a file name, or a case-insensitive substring of either, and `bash run-tests.sh --list` prints the known entry functions. For the SPM target use `swift test --filter <TestName>` (e.g. `swift test --filter MicRecordingFileMergerTests`).

### Scoped test loops (`Tests/TranscriptedCoreTests/`)

`Tests/TranscriptedCoreTests/` is split into five per-subsystem SPM test targets — `AudioTests`, `SpeakerTests`, `PipelineTests`, `StorageTests`, `UtilitiesTests` — mirroring `Sources/TranscriptedCore/{Audio,Speaker,Pipeline,Storage,Logging,Utilities,...}`, instead of one monolithic `TranscriptedCoreTests` target. When iterating on one subsystem, scope the run with `swift test --filter '^<Target>Tests\.'` (e.g. `swift test --filter '^SpeakerTests\.'`) — SwiftPM's `--filter` matches `<test-target>.<test-case>`, so this runs only that target's tests. Plain `swift test` with no filter still runs every target and is what CI and the verification-rules table above use, so nothing about full-suite behavior changed. `swift test --filter <ClassName>` still works for a single class too, including for `TranscriptionTaskManagerMetadataTests`, whose 64 tests live in `PipelineTests` split across several files that extend one class.

## Build-system shape

- `build.sh` is the **authoritative app build**, using raw `swiftc`. It must not compile `Sources/TranscriptedCore/` directly into the app target — Core enters the app via the prebuilt static archive from `build-deps.sh`.
- `Package.swift` exists only for `TranscriptedCore` package tests and smoke coverage. The linker pulls `deps-libs/libExternalDeps.a` (external-only) plus binary frameworks under `deps-frameworks/` (FluidAudio, ESpeakNG, MLX et al.) via `#filePath`-relative `-I`/`-L`/`-F` flags so it works under `swift test` and Xcode SPM alike.
- The app-build path keeps `libDraftDeps.a` (legacy-named archive containing FluidAudio + MLX + deps + TranscriptedCore objects) separate from the SPM path's `libExternalDeps.a`.

## High-level architecture

Top-level entry points (see `Sources/CLAUDE.md` for the full list):

- `TranscriptedApp.swift` — app entry, menubar wiring, popover/overlay setup, detected-meeting prompts, activation-policy switching so active recordings stay visible in the force-quit dialog
- `TranscriptedAppState.swift` — owns `ContextCaptureEngine`, `STTRouter`, wake-recovery coordination, and the lazy `MeetingSessionController`
- `TranscriptedMenuCommands.swift` — menubar/menu command wiring

Subsystem boundaries (each has a local `CLAUDE.md`):

| Path | Owns |
|------|------|
| `Sources/Accessibility/` | focused-editor AX metadata, overlay placement, paste-back context |
| `Sources/Capture/` | physical dictation trigger capture, meeting hotkey routing, `ContextCaptureEngine` |
| `Sources/Dictation/` | dictation transcript persistence, daily Markdown files, timeout helpers |
| `Sources/Meeting/` | app-side bridge into `TranscriptedCore`; live capture, imported-audio/video prep, queued meeting transcription, `MeetingSTTAdapter` |
| `Sources/Observability/` | events, debug log, Sentry, anonymous PostHog analytics, Sparkle updater, crash reporting |
| `Sources/Reliability/` | wake/sleep recovery for hotkeys and active capture |
| `Sources/Speech/` | local STT engines (`ParakeetEngine`), `STTRouter`, recorded-audio buffering, dictation audio recovery |
| `Sources/Support/` | app paths, permissions metadata, hotkey/trigger preferences, paste, dictionary, launch-at-login |
| `Sources/TranscriptedCore/` | reusable meeting transcription library — strict library boundary, consumed only through `Sources/Meeting/` |
| `Sources/UI/` | `Overlay/`, `MenuBar/`, `Settings/`, `Shared/` |
| `Tools/TranscriptedCaptureKit` | shared capture-library resolution + capture-Markdown parsing library for the CLI and MCP tools |
| `Tools/TranscriptedCLI` | standalone local-context, offline transcription, and offline diarization CLI |
| `Tools/TranscriptedMCP` | read-only MCP server for saved meetings/dictations, including cross-meeting rollup tools (`list_action_items`/`list_decisions`/`digest`) |
| `Tools/TranscriptedQA` | standalone artifact validation and QA CLI |
| `Tools/SpeakerEvalHarness` | headless AMI speaker-naming eval harness (diarization, embedding, clustering, cross-meeting match sweeps) |

Keep `Sources/TranscriptedCore/` a library boundary — meetings reuse the app's STT path through `Sources/Meeting/MeetingSTTAdapter.swift`. Sources/Speech/ owns dictation STT.

Naming traps (confirmed by the 2026-07-08 audit):

- `Sources/Support/CaptureLibrary*.swift` is capture-**library** migration/relocation logic (the user-relocatable folder of saved meeting/dictation Markdown and audio) — it is not `Sources/Capture/`, which is screen/audio capture triggering. See `Sources/Support/CLAUDE.md`.
- `Sources/Support/ModelCacheInventory.swift` inventories `Sources/Speech/` STT model caches even though it lives in `Support/`.

## Storage layout

App-owned state lives under `~/Library/Application Support/Transcripted/`:

- `captures/meetings/` — saved meeting Markdown + audio
- `captures/dictations/` — daily dictation Markdown
- `logs/app.jsonl`, `logs/events.jsonl`, `logs/debug.log` (see `docs/observability.md` for the full sink map)

Users can relocate the capture library via `transcriptSaveLocation` in Settings; app state/cache/logs/tmp stay under Application Support. Historic `Draft`-named paths still exist for migration and standalone-tool fallback. Canonical map: `docs/storage-paths.md`.

## Threading rules (CoreAudio)

Strict because CoreAudio I/O callbacks run on real-time threads:

- Session controllers + UI state are `@MainActor`.
- Audio capture internals use `DispatchQueue` + `NSLock`.
- **Never do I/O, locks, allocations, or ObjC calls inside CoreAudio real-time callbacks.** Deep-copy buffers before any async dispatch.

## Observability and privacy

Sentry and PostHog are bounded integrations, not generic log sinks. Off-device forwarding is gated by allowlists in `Sources/Observability/SentryEventPolicy.swift` and `AnalyticsEventPolicy.swift`. Both Sentry and analytics have user-facing toggles (`CrashReportingPreferences`, `AnalyticsPreferences`), default on, and read runtime config from `Info.plist` (`TranscriptedSentryDSN`, `TranscriptedPostHogAPIKey`, etc.) with `SENTRY_*` / `POSTHOG_*` env-var overrides for local testing.

Keep off-device payloads privacy-safe. **Never send** raw transcript text, audio references, meeting titles, speaker names, emails, tokens, absolute file paths, or raw device names. If payload shape changes, update `SentryPayloadSanitizer.swift` and `AnalyticsPayloadSanitizer.swift` in the same change.

Use `TRANSCRIPTED_DISABLE_FILE_LOGGER=1` when invoking binaries directly in tests/smoke runs so they don't append to the real production log.

## Releases

A release is not complete just because a DMG exists. For in-app Sparkle updates to land, the flow must also publish the signed archive, update `docs/appcast.xml`, and push that update to the branch backing the live feed. For Homebrew users, run `bash scripts/release/update-cask.sh <version>` after the GitHub release and commit `Casks/transcripted.rb`. If either step is skipped, say so explicitly. Read `docs/release-packaging.md` and `docs/sparkle-updates.md` before changing release flow. Use `build-beta.sh` (not `build.sh`) for builds that target other machines.

## Historical / archive zones

Treat as reference, not current runtime truth:

- `archive/` (including `archive/backend-beta-worker/`, `archive/evals/`)
- `.claude/` (older planning)
- references to `Sources/Text/` or `Sources/Style/` in older docs

## Hotspots

Files still over 1500 lines after the 2026-07 god-file splits (measured with `wc -l`). These are dense, high-blast-radius files — read the whole file and the relevant subsystem `CLAUDE.md` before editing; do not casually append another responsibility to any of them:

- `Sources/UI/Settings/TranscriptedSettingsView.swift` (~4.8k) — settings shell, navigation, state, and page routing for every settings surface; General, Storage, and Beta presentation now live under `Sources/UI/Settings/Pages/`, while the shell keeps their bindings and runtime work
- `Sources/Meeting/MeetingSessionController.swift` (~3.1k) — the meeting state machine; failed-meeting and queue bookkeeping were split into `FailedMeetingStore.swift`/`TranscriptionQueueCoordinator.swift`, but permission gating, capture start/stop, and transcript-save handoff still live here
- `Sources/Speech/ParakeetEngine.swift` (~2.8k) — the dictation STT engine; device recovery and model lifecycle already moved to `ParakeetDeviceRecovery.swift`/`ParakeetModelLifecycle.swift`, this file is still the public-API owner and `@MainActor` home for recording state
- `Sources/UI/Overlay/MeetingOverlayController.swift` (~2.7k) — the non-activating meeting-prompt/recording panel controller; touches capture state, live-transcript drawer, and prompt UI all at once
- `Sources/UI/Settings/PermissionsOnboardingView.swift` (~2.4k) — first-run onboarding walkthrough; sequences several distinct permission/setup stages in one view
- `Sources/UI/Settings/HomeView.swift` (~2.4k) — the Home canvas (greeting, stats, capture lists, preview/feedback sheets); most small formatting/policy helpers already live in sibling files (`HomePresentation.swift`, `HomeCanvasGreeting.swift`, etc.), this is the view assembly itself
- `Sources/UI/Overlay/DictationSessionController.swift` (~2.2k) — dictation session orchestration
- `Sources/Meeting/LocalMeetingSummarizer.swift` (~1.9k) — opt-in local AI meeting-summary runners for both providers (Gemma MLX, Apple Foundation Models)
- `Tools/TranscriptedMCP/Sources/TranscriptedMCP/TranscriptIndex.swift` (~1.7k) — the MCP server's SQLite index; schema DDL already split into `TranscriptIndex+Schema.swift`, this file is still the query/reconcile surface
- `Tests/TranscriptedCoreTests/SpeakerTests/Support/SpeakerNamingSimulationRunner.swift` (~1.7k) — test-only offline speaker-naming simulation harness
- `Sources/TranscriptedCore/Pipeline/TranscriptionTaskManager.swift` (~1.7k) — the single-flight transcription queue/orchestrator
- `Sources/UI/Settings/SpeakerPeopleSettingsSection.swift` (~1.6k) — the speakers settings surface (voice-to-name queue, duplicate suggestions, searchable list)

## Response voice

Per `AGENTS.md`: write like a real person texting a friend, not like a presentation. Short, punchy, direct. Vary rhythm. Casual connectors ("so", "anyway", "plus", "also") are fine. Be honest when something is unclear or unknown. Avoid marketing speak and AI tells like "dive into", "delve into", "let's explore". Normal capitalization. Real, not sloppy.
