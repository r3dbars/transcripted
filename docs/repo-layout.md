# Repo Layout

This is the canonical map of the live repo surface on `main`.

## Root Contract

The repo root should only expose:

- live product code and assets
- canonical build and verification entry points
- public project policy docs
- clearly marked historical/archive zones

If a file or folder does not fit one of those jobs, it should usually live
under `scripts/`, `Tools/`, or `docs/`.

When a root shell command is part of the public repo surface, prefer a thin
wrapper at the root and keep the implementation under `scripts/`.

## Main Commands

Use these as the active command surface:

```bash
bash check.sh
bash scripts/dev/agent-preflight.sh
bash build-deps.sh
bash build.sh --no-open
bash build-beta.sh '' <user>
bash run-tests.sh
bash run-integration-smoke.sh
bash run-e2e-smoke.sh
bash run-slow-pasteback-smoke.sh
bash run-live-capture-smoke.sh
bash run-daily-audio-reliability.sh
python3 scripts/ops/release-gate-report.py
bash scripts/ops/transcripted-qa-bench.sh --mode quick
bash scripts/ops/transcripted-qa-bench.sh --mode full
bash scripts/ops/transcripted-qa-bench.sh --mode ui
bash scripts/ops/transcripted-qa-bench.sh --mode sparkle-update
bash scripts/ops/transcripted-qa-bench.sh --mode packaged
bash scripts/ops/transcripted-qa-bench.sh --mode corpus
bash scripts/ops/transcripted-qa-bench.sh --mode corpus-compare
swift test
```

Command ownership:

- `scripts/dev/agent-preflight.sh` — agent preflight and suggested verification map for the current branch
- `check.sh` — thin root wrapper for the one-command check runner: the checks your diff needs by default, or the `quick`, `full`, and `hardware` tiers
- `build-deps.sh` — thin root wrapper for `scripts/entrypoints/build-deps.sh`, which builds `deps-libs/`, `deps-modules/`, `deps-frameworks/` and `deps-tools/`. A fresh worktree has none of these, so run it once first. Vendor pins live at the top of that script (`FLUID_AUDIO_VERSION` and friends).
- `build.sh` — thin root wrapper for the authoritative local app build; use `--no-open` for agent verification
- `build-beta.sh` — thin root wrapper for signed beta/distribution builds
- `run-tests.sh` — thin root wrapper for curated fast tests
- `run-integration-smoke.sh` — thin root wrapper for app/core smoke verification
- `run-e2e-smoke.sh` — thin root wrapper for deterministic release-critical artifact smoke
- `run-slow-pasteback-smoke.sh` — thin root wrapper for the deterministic fake slow Cmd+V pasteback target smoke
- `run-live-capture-smoke.sh` — thin root wrapper for local hardware/TCC capture smoke
- `run-daily-audio-reliability.sh` — thin root wrapper for the interactive and synthetic daily audio reliability check
- `scripts/models/parakeet-ultra/` — converts Moondream's Parakeet Ultra to Core ML with FluidInference/mobius and installs it as an experimental model (macOS only; see its README)
- `scripts/models/redimnet2/` — installs the ReDimNet2 b4 voiceprint model into the local model cache, from the bake-off's build, a given `.mlmodelc`/`.mlpackage`, or a fresh conversion; `build.sh` and `build-beta.sh` bundle it from there (macOS only; see its README)
- `scripts/ops/release-gate-report.py` — single pre-merge/release report covering QA bench, telemetry, release surfaces, and local log warnings
- `scripts/ops/transcripted-qa-bench.sh` — orchestrated QA tester pass with local report output, including `--mode ui` for the Accessibility-driven onboarding/menu bar/Home/Settings smoke, `--mode sparkle-update` for fake-state Sparkle update UI proof, and `--mode packaged` for no-publish package smoke
- `scripts/vm/transcripted-vm.sh` — clean macOS VM (Tart) for new-user and upgrade tests; see `docs/clean-vm-testing.md`
- `scripts/ci/mac-runner.sh` — set up, pause, or remove the owner's Mac as a self-hosted runner (a fresh Tart VM per job) for Swift CI's `checks` and `spm-tests`; `scripts/ci/pick-ci-runner.py` picks the Mac or hosted per run; see `docs/self-hosted-mac-runner.md`
- `scripts/ops/validate-meeting-corpus.py` — local-only meeting corpus validator for Downloads fixtures
- `scripts/ops/compare-meeting-corpus.py` — local-only Transcripted-vs-Zoom corpus comparator for Downloads fixtures
- `swift test` — `TranscriptedCore` package seam tests

For helper and legacy scripts, see `scripts/README.md`.

## Directory Map

- `.agents/` — machine-readable agent maps for path verification and QA gates
- `.agent-review/` — sanitized review evidence for agent PRs, not current UI truth
- `.github/` — issue templates, PR template, and repository workflows
- `Sources/` — macOS app target
- `Sources/App/` — app-shell helpers: the lab control channel and Email Support / Send diagnostics
- `Sources/Accessibility/` — AX helpers for overlay positioning
- `Sources/Capture/` — physical dictation trigger capture and meeting hotkey routing
- `Sources/Dictation/` — dictation persistence
- `Sources/Meeting/` — app-side meeting bridge into `TranscriptedCore`
- `Sources/Observability/` — analytics, crash reporting, debug logging, and Sparkle updater
- `Sources/Reliability/` — wake/sleep recovery
- `Sources/Speech/` — local STT engines, router, and audio recovery
- `Sources/Support/` — shared app utilities such as paths, permissions, hotkeys, and constants
- `Sources/TranscriptedCore/` — reusable meeting transcription library
- `Sources/Writing/` — Writing's app bridge: `WritingController` hosts the runtime, Save my writing day files, the Writing tab's model, count-only analytics
- `Sources/TranscriptedWriting/` — Writing's autocomplete library, ported from Tilde: `Core/` (pure policy, built as the `TranscriptedWritingCore` module) and `Runtime/` (model, `llama-server` host, socket, Screen Memory); see `docs/writing-plan.md`
- `Sources/TranscriptedKeyboard/` — Writing's IMKit keyboard; built by `scripts/entrypoints/lib/bundle-input-method.sh` into `Contents/Library/Input Methods/`, never into the app binary
- `Sources/UI/` — app-facing UI grouped into `Overlay/`, `MenuBar/`, `Settings/`, and `Shared/`
- `Tests/` — fast tests, package tests, and integration smoke sources
- `Tools/` — standalone sibling packages; see `Tools/README.md`
- `docs/` — live project docs, indexed in `docs/README.md`
- `docs/qa/` — manual QA checklists
- `docs/archive/` — finished records (eval output and the like), listed in `docs/archive/README.md`
- `docs/marketing/`, `docs/launch-assets/`, `docs/assets/`, `docs/screenshots/` — launch and marketing material, not engineering docs. A video or other code project goes in `docs/marketing/<name>/` with its own `.gitignore` for `node_modules/` and output.
- The transcripted.app website is not in this repo: it's `r3dbars/transcripted-webapp` (Astro on Cloudflare Pages, clone at `~/transcripted-webapp`, with its own `AGENTS.md`). Build site changes there, not as standalone HTML.
- `experiments/` — standalone probes (e.g. `audio-only-probe/`), not part of the app build
- `config/` — app config artifacts including entitlements and nightly security manifests
- `Casks/` — committed Homebrew cask release surface
- `Resources/` — bundled app assets
- `scripts/entrypoints/` — implementations behind the thin root command wrappers

Dated audit and autoeval docs in `docs/` are point-in-time evidence. Use the
current command map, local `AGENTS.md`, and `.agents/test-matrix.yml` for live
instructions unless a dated doc is explicitly the target of the task.

## Docs Map

`scripts/dev/check-doc-paths.py` (in `linux-checks.sh`) fails when a doc names a
path that doesn't exist, and keeps the root `AGENTS.md` inside its
line budget. When you move or delete a file, fix the docs that name it.

Use these docs for these jobs:

- `README.md` — public product overview and quick start
- `CONTRIBUTING.md` — contributor setup and contribution norms
- `AGENTS.md` — the one guide for every coding agent (Claude, Codex, or other): rules, commands, traps. Claude Code reads it natively; there is no `CLAUDE.md`
- `WORKFLOW.md` - local GitHub Issues to Codex agent workflow contract
- `.github/` — GitHub issue templates, PR checklist, and workflow automation
- `docs/README.md` — index of every live doc under `docs/`, grouped by job (product and formats, Writing, releases, testing and QA, labs, observability, operations)
- `Tests/README.md` — verification surfaces and fast-test runner behavior
- `.agents/test-matrix.yml` — quick path-to-verification map for agents
- `.agents/qa-gates.yml` — product-risk-to-proof gate map for agents
- `Sources/*/AGENTS.md` (and nested ones such as `Sources/UI/Settings/AGENTS.md`) — subsystem-local ownership and verification notes
- `Tools/README.md` and `Tools/*/AGENTS.md` — the standalone packages
- `scripts/README.md` — what each repo script does and how to run it

Point-in-time docs (history, not instructions; don't route agents here for current behavior):

- `docs/speaker-eval-exemplar-delta-2026-07.md` — dated speaker-eval result; stays in `docs/` because code comments and `scripts/hillclimb/benches/speaker_autoeval.py` cite it
- `docs/writing-plan.md` — Writing's design record (shipped in 1.1.67); code comments cite its sections
- `docs/archive/` — everything else that's finished

## Build system

- `build.sh` is the authoritative app build, using raw `swiftc`. Core enters the app through the prebuilt static archive from `build-deps.sh`, never compiled into the app target.
- `scripts/entrypoints/lib/swiftc-app-args.sh` (shared by `build.sh`, `build-beta.sh` and the typecheck scripts) first compiles `Sources/TranscriptedWriting/Core/` as its own static Swift module, `TranscriptedWritingCore`, into `build/modules/`, then links it into the app. App files that use its types import it under `#if canImport(TranscriptedWritingCore)`, so the fast tests and smokes can still compile the few Core files they need straight in.
- `Package.swift` exists for the `TranscriptedCore` package tests and smoke coverage. It links `deps-libs/libExternalDeps.a` plus the binary frameworks under `deps-frameworks/` through `#filePath`-relative flags, so it works under `swift test` and Xcode alike.
- The app build keeps `libDraftDeps.a` (legacy name: FluidAudio, deps, and TranscriptedCore objects) separate from the package path's `libExternalDeps.a`.

## Modules

The app compiles as one Swift target (plus the `TranscriptedWritingCore` module), so for the rest, folders are the only module lines. `.agents/modules.json` maps every `Sources/**/*.swift` file to a module and says what each may depend on; `scripts/dev/check-module-boundaries.py` fails when a file names a type from a module its own may not depend on. Crossings that predate the check are in `.agents/module-boundary-baseline.json` and can only shrink. `--explain <file>` prints a file's module, deps and doc; `--graph` prints edge counts.

| Module | Folders | May depend on |
| --- | --- | --- |
| Core | `Sources/TranscriptedCore/` (separate library) | nothing in the app |
| WritingCore | `Sources/TranscriptedWriting/Core/` (its own Swift module) | nothing |
| WritingRuntime | `Sources/TranscriptedWriting/Runtime/` | WritingCore |
| Keyboard | `Sources/TranscriptedKeyboard/` (separate bundle) | WritingCore |
| Support | `Sources/Support/`, `Sources/Accessibility/`, `Sources/Reliability/` | Core `core-vocab` |
| Observability | `Sources/Observability/` | Support, Core `core-vocab` |
| Speech | `Sources/Speech/` | Support, Observability, Core `core-vocab` + `mic-primitives` |
| Dictation | `Sources/Dictation/` | Speech, Support, Observability, Core `core-vocab` |
| Meeting | `Sources/Meeting/` | Dictation, Speech, Support, Observability, all of Core |
| WritingBridge | `Sources/Writing/` | WritingCore, WritingRuntime, Support, Observability |
| Capture | `Sources/Capture/` | UIOverlay, Dictation, Speech, Support, Observability |
| UIShared | `Sources/UI/Shared/` | Meeting, Dictation, Speech, WritingBridge, Support, Observability, Core `core-vocab` |
| UIOverlay | `Sources/UI/Overlay/` | UIShared, AppState, Meeting, Dictation, Speech, Support, Observability, Core `core-vocab` |
| UIMenuBar | `Sources/UI/MenuBar/` | UIShared, UIOverlay, UISettings, AppState, Capture, and everything below |
| UISettings | `Sources/UI/Settings/` | UIShared, UIOverlay, AppState, Capture, WritingBridge, WritingCore, WritingRuntime, and everything below |
| AppState | `Sources/TranscriptedAppState.swift` | Capture, WritingBridge, Meeting, Dictation, Speech, UIShared, Support, Observability, Core `core-vocab` |
| AppShell | `Sources/App/`, `Sources/TranscriptedApp.swift`, `Sources/TranscriptedAppDelegate+*.swift`, `Sources/TranscriptedMenuCommands.swift` | anything; nothing depends on it |

Each module's `AGENTS.md` (named in the manifest) says what it owns, its public surface, its entry points and its tests. A new `Sources/` folder needs a manifest entry and an `AGENTS.md`, or the check fails.

## Hotspots

Two ratchets keep files from growing back: `scripts/dev/check-file-size.py` fails on a new Swift file over 800 lines and on a baselined one that grows (`.agents/file-size-baseline.json`, 42 files today). Read the whole file and its folder's `AGENTS.md` before editing a big one, and don't add another responsibility to it. Regenerate the list instead of trusting it:

```bash
python3 scripts/dev/check-file-size.py --hotspots
```

Over 1,500 lines as of 2026-10-02, largest first:

- None. `MeetingOverlayController.swift` was the last one; it dropped under 1,500 when the old meeting pill code went.

Split hotspots. These were over 1,500 lines until 2026-10; each is now a core file plus `+*.swift` extensions or sibling files. The risk didn't move out with the lines, so read the whole set:

- Meeting capture in Core: `Audio.swift` is the class shell. The riskiest code is the stop ordering in `Audio+CaptureLifecycle.swift` and the AirPods-sensitive engine touch in `Audio+MeetingInputGraph.swift`. `AudioFileManager.swift`, `Audio+MicBufferWrite.swift`, `Audio+SystemAudioWrite.swift`, `Audio+BufferUtilities.swift` and `SystemAudioCaptureStartAttempt.swift` run on or next to the CoreAudio real-time path. A real-time rule violation is a crash or silent corruption, and no hosted CI job exercises this path (`hardware-smokes` needs a self-hosted Apple Silicon runner).
- `Sources/TranscriptedCore/Pipeline/TranscriptionTaskManager.swift` plus `+Start`, `+FailedAudioRetention`, `+FailureClassification`, `+OrphanedRecordingRecovery`, `+Retry`, `+CleanupPaths` — the single-flight transcription queue and failed-queue retention. A transcription failure must archive audio into the failed queue before deleting scratch. Exceptions: the sub-2s live-capture gate (pinned by `testStartTranscriptionRejectsTooShortLiveAudioWithoutQueueingRetry`), the imported-audio gates (scratch is a copy), and an accidental start (`isAccidentalStart` plus `tracksHaveSpeechLikeSignal`: a healthy live session under 10 s ending in `noSpeechDetected` with no speech-like track). The starts and the gate are in `+Start.swift`, the archiving in `+FailedAudioRetention.swift`.
- `Sources/TranscriptedCore/Pipeline/TranscriptionPipeline.swift` (orchestrator) plus `+MicrophoneOnly`, `+MicDiarization`, `+Stages`, `+LastChanceSweep`, `+SystemSpeakerIdentity` — per-meeting work: resample, diarize system audio, Parakeet STT per segment, mic-channel handling, speaker matching (in `+SystemSpeakerIdentity`), utterance merging. `TranscriptionPipelineRunner.swift` runs it and resolves partial-success channels before save.
- `Sources/TranscriptedCore/Speaker/SpeakerNamingCoordinator.swift` plus `+Planning`, `+Apply`, `+RequestQueue`, `+Finish`, and the two lock registries `SpeakerNamingRequestOwnership.swift` and `SpeakerReviewProfileProtection.swift` — post-meeting speaker naming: auto-accept, review ownership, and saving name/merge/discard decisions.
- `Sources/Meeting/MeetingSessionController.swift` (the recording lifecycle) plus `+State.swift` (declares the class) and its other `+*.swift` extensions — the meeting state machine.
- `Sources/TranscriptedApp.swift` (app entry, the delegate's stored state, launch wiring, detected-meeting prompts, Quit, status item) plus `TranscriptedAppDelegate+LaunchReports`, `+Lifecycle`, `+MenuBar`, `+SettingsActions`. The most source-pinned file: its pins still read `TranscriptedApp.swift` only, so pinned code stays there.
- `Sources/Meeting/MeetingPromptDetector.swift` plus `+Backoff`, `+CalendarRuntime`, `+AdHocCalls`, `+BrowserEvidence` and `MeetingPromptCalendarReader.swift` — decides when to offer "record this meeting?".
- `Sources/Speech/ParakeetEngine.swift` (core state, native AVAudioEngine calls; the graph itself, with rebuild/retire, is `ParakeetAudioGraph`) plus `ParakeetInputReadiness`, `ParakeetInputRoute`, `ParakeetAudioTap`, `ParakeetRecordingStart`, `ParakeetRecordingTeardown`, `ParakeetDictationTranscription`, `ParakeetASRInference` — the dictation STT engine and `@MainActor` home for recording state. Engine and `inputNode` code here is AirPods-sensitive; read `Sources/Speech/AGENTS.md` first.
- `Sources/UI/Overlay/DictationSessionController.swift` plus `+RecordingStart`, `+Stop`, `+PasteBack`, `+Persistence`, `+Recovery`, `+Presses`, `+SessionCap`, `+Telemetry` and `DictationSessionDeliveryTypes.swift` — dictation session orchestration. `stopDictationAndPaste` is in `+Stop`, `installSessionTimeout` in `+SessionCap`.
- `Sources/Support/ClipboardRestoringTextPaster.swift` plus `+Pasteboard`, `+SavedClipboard`, `ClipboardPasteOutcome.swift`, `ClipboardPasteTarget.swift` and `FocusedTextPasteConfirmation.swift` — dictation paste-back: borrows the clipboard, pastes, waits for it to land, restores. Edits to any of the six also need `bash run-slow-pasteback-smoke.sh`.
- `Sources/UI/Settings/TranscriptedSettingsView.swift` (stored state, `init`, `body`, Home row actions) plus `+Pages`, `+HomeMeetingActions`, `+GeneralEditors`, `+Refresh`, `+Preferences` — the Settings window shell, page routing, and every Home side effect. Pages live under `Sources/UI/Settings/Pages/`; the shell keeps their bindings. The Home row actions in the core file are still pinned by source-text assertions in `Tests/UIAutomationSurfaceContractTests.swift`.
- `Sources/UI/Settings/HomeView.swift` plus `HomeViewModel.swift`, `HomeModels.swift`, `HomeFeedbackModels.swift`, `HomeScanWarningCard.swift`, `HomeCaptureList.swift` — the Meetings page (page id `home`).
- `Sources/UI/Settings/SpeakerPeopleSettingsSection.swift` (the section view, empty state, shared play/link/icon controls) plus `SpeakerPeopleRows.swift` (the voice-to-name and person rows), `SpeakerPeopleSettingsViewModel.swift` (state, rename/merge/delete) and `SpeakerPeopleSettingsViewModel+Duplicates.swift` (duplicate detection and clip files) — the Speakers directory (review, rename, merge, delete). Most of the grandfathered Core-engine crossings live in the view model.
- `Tools/TranscriptedQA/Sources/TranscriptedQA/Commands/PackagedAppSmoke.swift` plus `PackagedAppSmokeRunner.swift`, the `FirstRunReliability*.swift` files and `PrivacyLogScanner.swift` — the packaged-app release smoke; a break here blocks shipping.
- `Tools/TranscriptedMCP/Sources/TranscriptedMCP/TranscriptIndex.swift` (connection, schema gate, reconcile, indexing) plus `+MeetingQueries`, `+DictationQueries`, `+Context`, `+SummaryRollups`, `+Schema`, `+Writing` — the MCP server's SQLite surface.

## Historical Zones

The old beta backend (`archive/`) was removed on 2026-09-25. It's still in git history (last on `main` at
`73f4fa6`) if you need it.

`docs/archive/` holds finished records that no code, script, or test reads.

`.claude/` is live tooling, not a historical zone: `skills/` holds the `transcripted-qa` skill, `commands/` the `humanize`/`tests`/`push` slash commands, and `agents/` subagent definitions (`test-writer` and the `writing-*` agents used for the Tilde port).
