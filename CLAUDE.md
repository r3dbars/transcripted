# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

For day-to-day agent work, start with `AGENT_START.md` and treat `AGENTS.md` as the canonical workflow contract. This file is the Claude-oriented orientation layer on top of those.

## What this repo is

`main` is the current Transcripted app, derived from the earlier Draft codebase. It is a macOS menubar app (macOS 26+, Apple Silicon only) for:

- dictation capture with paste-back into the focused editor
- meeting capture (local mic + system audio) with local transcription
- imported-audio transcription
- optional local-speaker review for people sharing the room mic
- agent-readable Markdown output saved to disk

The old standalone Transcripted app is preserved on branch `legacy/transcripted-standalone` and tag `pre-draft-takeover-2026-04-06`. The older drafting/ghostwriting flow is not active on `main`; `DictationSessionController.cancelSession()` is the only remaining compatibility hook from that removed routing.

## First reads

Before making assumptions about the codebase:

1. `AGENT_START.md` — short safe-start path
2. `README.md` — public product overview
3. `AGENTS.md` — canonical workflow contract (build/test rules, voice, observability)
4. `docs/repo-layout.md` — live directory map and command surface
5. `docs/agent-onboarding.md` — doc trust order
6. `Sources/CLAUDE.md` — app target orientation
7. the nearest local `CLAUDE.md` for the area you are changing (see "Subsystem docs" below)

When docs disagree, prefer: current repo-level docs → current source → local `CLAUDE.md` whose file lists still match the tree → `docs/archive/` only as context.

## Build and test

Common commands (thin root wrappers; implementations live under `scripts/entrypoints/`):

```bash
bash build-deps.sh                 # build/refresh prebuilt deps under deps-libs/, deps-frameworks/, deps-modules/
bash build.sh                      # authoritative app build (raw swiftc, NOT swift build)
bash run-tests.sh                  # curated fast tests (manifest-driven)
bash run-integration-smoke.sh      # app/core linkage + wake recovery + MicRecordingFileMerger
bash run-e2e-smoke.sh              # deterministic release-critical artifact smoke (no mic/TCC)
bash run-live-capture-smoke.sh     # local hardware/TCC smoke (needs mic + System Audio Recording perms)
swift test                         # Swift Package tests for TranscriptedCore seam only
bash build-beta.sh <token> <user>  # signed beta/distribution build; SKIP_NOTARIZATION=1 for packaging smoke
bash scripts/dev/agent-preflight.sh  # prints suggested verification map for the current branch diff
```

Verification rules (mirror `.agents/test-matrix.yml`; if a change matches multiple rules, run the union):

- Touched `Sources/**/*.swift`, root `Tests/*.swift`, or `Tests/FastTests.manifest` → `bash build.sh` + `bash run-tests.sh`
- Touched `Sources/Meeting/**`, `Sources/TranscriptedCore/**`, or `Tests/Integration/**` → `bash build.sh` + `bash run-tests.sh` + `bash run-integration-smoke.sh`
- Touched `Tests/E2E/**`, `run-e2e-smoke.sh`, or `scripts/entrypoints/run-e2e-smoke.sh` → `bash run-e2e-smoke.sh`
- Touched QA bench/corpus files (`scripts/ops/transcripted-qa-bench.sh`, `scripts/ops/validate-meeting-corpus.py`, `scripts/ops/compare-meeting-corpus.py`, `docs/qa-test-bench.md`) → quick QA bench + Python compile checks
- Touched live-capture smoke paths (`Tests/TranscriptedCoreTests/LiveCaptureSmokeTests.swift`, `run-live-capture-smoke.sh`, `scripts/entrypoints/run-live-capture-smoke.sh`) → `bash run-live-capture-smoke.sh --skip-build`
- Touched `Package.swift`, `Sources/TranscriptedCore/**`, or `Tests/TranscriptedCoreTests/**` → `bash build.sh` + `bash run-tests.sh` + `bash run-integration-smoke.sh` + `swift test`
- Touched `Sources/Observability/**`, `Info.plist`, `docs/sparkle-updates.md`, or `docs/appcast.xml` → `bash build.sh` + `bash run-tests.sh`
- Touched release path (`build-beta.sh`, `scripts/entrypoints/build-beta.sh`, `scripts/release/**`, `docs/release-packaging.md`, `docs/sparkle-updates.md`, `Casks/**`, `docs/appcast.xml`) → `bash build.sh` + `bash run-tests.sh` + `SKIP_NOTARIZATION=1 bash build-beta.sh <token> <user-name>`
- Touched `Tools/TranscriptedCLI/**` → `swift test --package-path Tools/TranscriptedCLI`
- Touched `Tools/TranscriptedMCP/**` → `swift test --package-path Tools/TranscriptedMCP`
- Touched `Tools/TranscriptedQA/**` → `swift test --package-path Tools/TranscriptedQA`
- Touched docs/agent files (`README.md`, `AGENT_START.md`, `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`, `docs/**`, `.agents/**`) → `scripts/dev/agent-preflight.sh`

### Fast-test gotchas

`run-tests.sh` is a custom `swiftc` runner, not XCTest:

- A new root `Tests/*Tests.swift` file is **not** picked up automatically — it must be registered in `Tests/FastTests.manifest` as `<TestFile.swift>:<top-level entry function>`.
- Moving a source file that the runner compiles directly requires updating the script.
- The runner fails if the manifest and actual root test files drift.
- `Tests/TranscriptedCoreTests/` is a separate SPM target — run via `swift test`, not `run-tests.sh`.
- `bash run-tests.sh --coverage` writes LLVM coverage under `build/coverage/fast-tests/`.

### Running a single test

Fast tests are top-level functions, not XCTest cases. To run one in isolation, temporarily reduce the manifest to that one entry and run `bash run-tests.sh`, or invoke the compiled runner under `build/tests/` directly. For the SPM target use `swift test --filter <TestName>` (e.g. `swift test --filter MicRecordingFileMergerTests`).

## Build-system shape

- `build.sh` is the **authoritative app build**, using raw `swiftc`. It must not compile `Sources/TranscriptedCore/` directly into the app target — Core enters the app via the prebuilt static archive from `build-deps.sh`.
- `Package.swift` exists only for `TranscriptedCore` package tests and smoke coverage. The linker pulls `deps-libs/libExternalDeps.a` (external-only) plus binary frameworks under `deps-frameworks/` (FluidAudio, ESpeakNG, MLX et al.) via `#filePath`-relative `-I`/`-L`/`-F` flags so it works under `swift test` and Xcode SPM alike.
- The app-build path keeps `libDraftDeps.a` (legacy-named archive containing FluidAudio + MLX + deps + TranscriptedCore objects) separate from the SPM path's `libExternalDeps.a`.

## High-level architecture

Top-level entry points (see `Sources/CLAUDE.md` for the full list):

- `TranscriptedApp.swift` — app entry, menubar wiring, popover/overlay setup, detected-meeting prompts, activation-policy switching so active recordings stay visible in the force-quit dialog
- `TranscriptedAppState.swift` — owns `ContextCaptureEngine`, `STTRouter`, wake-recovery coordination, and the lazy `MeetingSessionController`

Subsystem boundaries (each has a local `CLAUDE.md`):

| Path | Owns |
|------|------|
| `Sources/Accessibility/` | focused-editor AX metadata, overlay placement, paste-back context |
| `Sources/Beta/` | beta-build configuration |
| `Sources/Capture/` | physical dictation trigger capture, meeting hotkey routing, `ContextCaptureEngine` |
| `Sources/Dictation/` | dictation transcript persistence, daily Markdown files, timeout helpers |
| `Sources/Meeting/` | app-side bridge into `TranscriptedCore`; live capture, imported-audio, queued meeting transcription, `MeetingSTTAdapter` |
| `Sources/Observability/` | events, debug log, Sentry, anonymous PostHog analytics, Sparkle updater, crash reporting |
| `Sources/Reliability/` | wake/sleep recovery for hotkeys and active capture |
| `Sources/Speech/` | local STT engines (`ParakeetEngine`), `STTRouter`, recorded-audio buffering, dictation audio recovery |
| `Sources/Support/` | app paths, permissions metadata, hotkey/trigger preferences, paste, dictionary, launch-at-login |
| `Sources/TranscriptedCore/` | reusable meeting transcription library — strict library boundary, consumed only through `Sources/Meeting/` |
| `Sources/UI/` | `Overlay/`, `MenuBar/`, `Settings/`, `AgentConnect/`, `Shared/` |
| `Tools/TranscriptedCLI` | standalone local-context and offline diarization CLI |
| `Tools/TranscriptedMCP` | read-only MCP server for saved meetings/dictations |
| `Tools/TranscriptedQA` | standalone artifact validation and QA CLI |

Keep `Sources/TranscriptedCore/` a library boundary — meetings reuse the app's STT path through `Sources/Meeting/MeetingSTTAdapter.swift`. Sources/Speech/ owns dictation STT.

## Storage layout

App-owned state lives under `~/Library/Application Support/Transcripted/`:

- `captures/meetings/` — saved meeting Markdown + audio
- `captures/dictations/` — daily dictation Markdown
- `logs/app.jsonl`, `logs/events.jsonl`, `logs/debug.log`

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
- `docs/archive/`
- `.claude/` (older planning)
- references to `Sources/Text/` or `Sources/Style/` in older docs

## Response voice

Per `AGENTS.md`: write like a real person texting a friend, not like a presentation. Short, punchy, direct. Vary rhythm. Casual connectors ("so", "anyway", "plus", "also") are fine. Be honest when something is unclear or unknown. Avoid marketing speak and AI tells like "dive into", "delve into", "let's explore". Normal capitalization. Real, not sloppy.
