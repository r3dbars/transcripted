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
- `build-deps.sh` — thin root wrapper for the dependency build entrypoint
- `build.sh` — thin root wrapper for the authoritative local app build; use `--no-open` for agent verification
- `build-beta.sh` — thin root wrapper for signed beta/distribution builds
- `run-tests.sh` — thin root wrapper for curated fast tests
- `run-integration-smoke.sh` — thin root wrapper for app/core smoke verification
- `run-e2e-smoke.sh` — thin root wrapper for deterministic release-critical artifact smoke
- `run-slow-pasteback-smoke.sh` — thin root wrapper for the deterministic fake slow Cmd+V pasteback target smoke
- `run-live-capture-smoke.sh` — thin root wrapper for local hardware/TCC capture smoke
- `run-daily-audio-reliability.sh` — thin root wrapper for the interactive and synthetic daily audio reliability check
- `scripts/ops/compare-parakeet-models.py` — runs Parakeet V3 and the experimental Parakeet Ultra through `transcripted-cli` on the same recordings and reports word error rate (with `<name>.txt` references) or where they disagree
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
- `Sources/TranscriptedWriting/` — Writing's autocomplete library, ported from Tilde: `Core/` (pure policy) and `Runtime/` (model, `llama-server` host, socket, Screen Memory); see `docs/writing-plan.md`
- `Sources/TranscriptedKeyboard/` — Writing's IMKit keyboard; built by `scripts/entrypoints/lib/bundle-input-method.sh` into `Contents/Library/Input Methods/`, never into the app binary
- `Sources/UI/` — app-facing UI grouped into `Overlay/`, `MenuBar/`, `Settings/`, and `Shared/`
- `Tests/` — fast tests, package tests, and integration smoke sources
- `Tools/` — standalone sibling packages; see `Tools/README.md`
- `docs/` — live project docs, indexed in `docs/README.md`
- `docs/qa/` — manual QA checklists
- `docs/archive/` — finished records (eval output and the like), listed in `docs/archive/README.md`
- `docs/marketing/`, `docs/launch-assets/`, `docs/assets/`, `docs/screenshots/` — launch and marketing material, not engineering docs
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
- `Package.swift` exists for the `TranscriptedCore` package tests and smoke coverage. It links `deps-libs/libExternalDeps.a` plus the binary frameworks under `deps-frameworks/` through `#filePath`-relative flags, so it works under `swift test` and Xcode alike.
- The app build keeps `libDraftDeps.a` (legacy name: FluidAudio, deps, and TranscriptedCore objects) separate from the package path's `libExternalDeps.a`.

## Hotspots

Files over 1,500 lines. Read the whole file and its folder's `AGENTS.md` before editing, and don't add another responsibility to any of them. Regenerate the list instead of trusting it:

```bash
find Sources Tools/*/Sources -name '*.swift' -not -path '*/.build/*' | xargs wc -l | awk '$1>1500 && $2!="total"' | sort -rn
```

As of 2026-10-01, largest first:

- `Sources/Meeting/MeetingSessionController.swift` — the meeting state machine. Failed-meeting and queue bookkeeping moved to `FailedMeetingStore.swift` and `TranscriptionQueueCoordinator.swift`; permission gating, capture start/stop, and transcript-save handoff are still here.
- `Sources/UI/Settings/TranscriptedSettingsView.swift` — settings shell, navigation, state, and page routing. Pages live under `Sources/UI/Settings/Pages/`; the shell keeps their bindings and every Home side effect. Partly pinned by source-text assertions in `Tests/UIAutomationSurfaceContractTests.swift`.
- `Sources/Speech/ParakeetEngine.swift` — the dictation STT engine and `@MainActor` home for recording state. Device recovery and model lifecycle moved to `ParakeetDeviceRecovery.swift` and `ParakeetModelLifecycle.swift`.
- `Sources/UI/Overlay/DictationSessionController.swift` — dictation session orchestration. The engine-facing half moved to `Sources/Speech/DictationSession.swift`; `stopDictationAndPaste` and `installSessionTimeout` stay, pinned by source-text tests.
- `Sources/TranscriptedCore/Audio/Audio.swift` — the riskiest file: mic and system capture, CoreAudio real-time callbacks, tap lifecycle, and the recording-session generation token. A real-time rule violation is a crash or silent corruption, and no hosted CI job exercises this path (`hardware-smokes` needs a self-hosted Apple Silicon runner). Most open PRs touch it at once, so expect semantic merge conflicts.
- `Sources/TranscriptedCore/Pipeline/TranscriptionTaskManager.swift` — the single-flight transcription queue and failed-queue retention. A transcription failure must archive audio into the failed queue before deleting scratch. Exceptions: the sub-2s live-capture gate (pinned by `testStartTranscriptionRejectsTooShortLiveAudioWithoutQueueingRetry`), the imported-audio gates (scratch is a copy), and an accidental start (`isAccidentalStart` plus `tracksHaveSpeechLikeSignal`: a healthy live session under 10 s ending in `noSpeechDetected` with no speech-like track).
- `Tools/TranscriptedQA/Sources/TranscriptedQA/Commands/PackagedAppSmoke.swift` — the packaged-app release smoke; a break here blocks shipping.
- `Sources/TranscriptedCore/Speaker/SpeakerNamingCoordinator.swift` — post-meeting speaker naming: auto-accept, review ownership, and saving name/merge/discard decisions to the speaker DB and transcript.
- `Sources/UI/Settings/SpeakerPeopleSettingsSection.swift` — the speakers settings surface.
- `Sources/TranscriptedApp.swift` — app entry, menubar wiring, popover/overlay setup, detected-meeting prompts, activation-policy switching.
- `Tools/TranscriptedMCP/Sources/TranscriptedMCP/TranscriptIndex.swift` — the MCP server's SQLite query and reconcile surface (schema in `TranscriptIndex+Schema.swift`).
- `Sources/Support/ClipboardRestoringTextPaster.swift` — dictation paste-back: borrows the clipboard, pastes, waits for it to land, restores. Edits also need `bash run-slow-pasteback-smoke.sh`.
- `Sources/Meeting/MeetingPromptDetector.swift` — decides when to offer "record this meeting?".
- `Sources/UI/Settings/HomeView.swift` — the Meetings page (page id `home`); small helpers live in sibling files.
- `Sources/UI/Overlay/MeetingOverlayController.swift` — the meeting panel lifecycle and recording-pill actions. The Notch island now draws meetings; follow-ups to PR #1946 delete the old pill code, so expect it to shrink.
- `Sources/TranscriptedCore/Audio/AudioFileManager.swift` — `extension Audio` for capture setup, WAV writing, and mic/system buffer writes, plus the system-audio start-attempt serializer. Same real-time rules as `Audio.swift`.
- `Sources/TranscriptedCore/Pipeline/TranscriptionPipeline.swift` — per-meeting work: resample, diarize system audio, Parakeet STT per segment, mic-channel handling, speaker matching, utterance merging. `TranscriptionPipelineRunner.swift` runs it and resolves partial-success channels before save.

## Historical Zones

The old beta backend (`archive/`) was removed on 2026-09-25. It's still in git history (last on `main` at
`73f4fa6`) if you need it.

`docs/archive/` holds finished records that no code, script, or test reads.

`.claude/` is live tooling, not a historical zone: `skills/` holds the `transcripted-qa` skill, `commands/` the `humanize`/`tests`/`push` slash commands, and `agents/` subagent definitions (`test-writer` and the `writing-*` agents used for the Tilde port).
