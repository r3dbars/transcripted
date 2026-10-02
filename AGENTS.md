# Transcripted agent guide

The one set of rules for every coding agent (Claude, Codex, or other). Agent docs are `AGENTS.md` only, here and in each folder; Claude Code reads them natively (v2.1.277+), so there's no `CLAUDE.md`. Don't add a `CLAUDE.md` or `CLAUDE.local.md` in the repo: by default Claude Code then reads it instead of `AGENTS.md`. `check-known-traps.py` fails on any `CLAUDE.md` that isn't a bare `@AGENTS.md` stub.

Transcripted is a macOS 26+, Apple Silicon menubar app: dictation with paste-back, meeting capture (mic + system audio) with local transcription, imported audio and video, and Writing. Everything it captures is saved as agent-readable Markdown on disk.

## Start here

1. `python3 scripts/dev/agent-context.py <changed paths>` prints the owner docs, the rules to keep true, and the checks for your change. Add `--symptom "short description"` when you don't know where a bug lives.
2. Read the nearest `AGENTS.md` in the folder you're changing (`Sources/<area>/AGENTS.md`, `Tools/<package>/AGENTS.md`). That's where subsystem detail lives. `python3 scripts/dev/check-module-boundaries.py --explain <file>` names the file's module, what it may depend on, and its doc.
3. `docs/repo-layout.md` is the map: folders, commands, docs, and hotspot files.
4. Before you hand off: `bash check.sh`.

When sources disagree: current code wins for runtime behavior, this file and `.agents/test-matrix.yml` win for workflow.

## Rules that always apply

- **Keep the product surface.** Simplification must not delete, hide, or bury: automatic meeting detection and its record / dismiss / remind flow; the Speakers directory with review, rename, merge, and delete; per-app dictation Auto Enter; model-cache inspection and cleanup; right-clicking the status item (it opens the same popover as a left-click — the separate right-click menu was removed at the owner's request, 2026-09-28); retained meeting-audio playback (clicking a row's time plays from there; rows don't follow the playhead). Changing any of these needs the owner's approval.
- **Local-first and private.** Never send or log raw transcript text, audio references, meeting titles, speaker names, emails, tokens, absolute paths, or raw device names off the device.
- **`Sources/TranscriptedCore/` is a library.** `build.sh` links it from the prebuilt archive, never compiling it into the app target. `Sources/Meeting/` is the only module that may use all of it; other modules may name only the Core types their tier in `.agents/modules.json` grants (`core-vocab`: logging, frontmatter, language and speaker value types; Speech also gets `mic-primitives`). `Sources/Speech/` owns dictation STT; meetings reuse it through `Sources/Meeting/MeetingSTTAdapter.swift`.
- **CoreAudio real-time callbacks:** no I/O, locks, allocations, or ObjC calls inside them. Deep-copy buffers before any async hop. Session controllers and UI state are `@MainActor`; capture internals use `DispatchQueue` + `NSLock`.
- **AirPods.** A fresh `AVAudioEngine`'s `inputNode` binds the macOS default input before you can pin a device; if that's AirPods, they flip into call mode and the audio garbles. Every AirPods garble bug so far came from this. Any code that builds an engine or touches `inputNode` must say what happens with a Bluetooth headset as the default input. Read `Sources/Speech/AGENTS.md` first.
- **Harnesses never touch real user state.** Automated launches go through `AutomatedLaunchEnvironment`. Scripts, labs, and tests don't write to the real capture library or prefs. Anything that deletes checks the path is under the root it owns first. Use `TRANSCRIPTED_DISABLE_FILE_LOGGER=1` when running binaries directly.
- **Owner's commit credit.** When an agent commits work for Justin, use `r3dbars <r3dbars@users.noreply.github.com>` as the Git author and committer. Do not add AI `Co-authored-by` trailers. Keep independent human contributors' credit intact. If a platform forces bot authorship, report that limitation instead of claiming the commit will show as `r3dbars`.

## Build and test

```bash
bash check.sh             # the checks your diff needs, from .agents/test-matrix.yml
bash check.sh quick       # Linux-safe checks, no Swift build (about a minute)
bash check.sh full        # what Swift CI runs on a PR
bash check.sh hardware    # real mic, system audio, and paste-back smokes on this Mac
```

The pieces, when you need one directly: `bash build-deps.sh` (prebuilt audio libraries; `--force` after touching `Sources/TranscriptedCore/` or `Sources/Meeting/`), `bash build.sh --no-open` (the real app build), `bash run-tests.sh` (fast tests; `--filter <name>` for one), `swift test` (Core package tests), `bash run-integration-smoke.sh`, `bash run-e2e-smoke.sh`. More in `Tests/README.md`.

- **Writing a test:** follow "Test rules" in `Tests/README.md`. A test checks a named promise through inputs and outputs. It never reads `Sources/` as text and never asserts on wall-clock time. `scripts/dev/check-test-shape.py` blocks new ones.
- **Flaky test:** fix it or bench it in `Tests/quarantine.txt` the same day. Never retry until green.
- **No Swift toolchain** (Linux, cloud): run `bash scripts/dev/linux-checks.sh`, and never say a Swift change was built or tested until CI ran on that exact head. Claude sessions can't re-run Actions jobs; don't push empty commits to retrigger.
- **PR review level:** docs-only needs `bash check.sh`. Meaningful code also needs an independent review of the full diff against the real base (`codex review`, a separate deep-review thread, or `/code-review`); record the verdict in the PR. Broad, risky, or release-impacting work also needs `bash scripts/ops/transcripted-qa-bench.sh --mode full`. Release notes, appcast, cask, QA-gate, and download docs count as release-impacting even when only Markdown changed.

## Known traps

Each of these has cost a red CI run or a wrong merge. The ones with a check fail loudly now; the rest you have to remember.

- **Tests that read source as text.** 39 grandfathered test files still assert on exact code fragments, so a rename or a reflow can turn CI red. Before editing a file, run `python3 scripts/dev/check-source-pins.py --changed-only`. Most-pinned: `TranscriptedApp.swift`, `TranscriptedSettingsView.swift`, `MeetingSessionController.swift`, `ParakeetEngine.swift` and its extension files (read together through `readParakeetEngineSource()`), `ParakeetDeviceRecovery.swift`, `MeetingOverlayController.swift`. `Tests/OverlayScreenSharePrivacyTests.swift` scans all of `Sources/UI`. New ones are blocked by `check-test-shape.py`.
- **Module edges.** The app is one Swift target, so the compiler lets any file name any type; `check-module-boundaries.py` doesn't. Every `Sources/` file belongs to a module in `.agents/modules.json`, and naming a type from a module yours may not depend on fails the check. A new `Sources/` folder needs a module entry and an `AGENTS.md`. Fix a crossing by moving the type down or passing plain values; growing `.agents/module-boundary-baseline.json` is a reviewed human edit.
- **Telemetry keys are dropped by substring.** The sanitizers silently drop any key whose name contains `audio`, `error`, `file`, `name`, `path`, `speaker`, `text`, `title`, `token`, `url` and more, so `start_profile` never arrives ("profile" contains "file"). `python3 scripts/dev/check-telemetry-keys.py` catches it. Adding an analytics event is a lockstep edit; see `Sources/Observability/AGENTS.md`.
- **Hand-kept source lists.** `run-tests.sh` and some smokes compile a listed subset of `Sources/`. A new file a test needs must be added there; the compile error now names the file and the list.
- **A clean text merge isn't a working merge.** Git won't flag a new enum case missing from another PR's `switch`, two PRs bumping the same literal count, or a renamed helper another PR's test calls. When two PRs touch the same file, let CI build the merged result. Assert against explicit lists, not counts.
- **"Dirty" on GitHub** is often a criss-cross history, not a real conflict: merge current `main` into the PR (a merge commit; never force-push). Before opening any repair or reland branch, run `python3 scripts/dev/check-superseded.py --pr <number>`; exit 3 means it already merged under another PR.
- **Naming:** `Sources/Support/CaptureLibrary*.swift` is the relocatable capture *library* (saved Markdown and audio), not `Sources/Capture/` (hotkeys and triggers). `Sources/Support/ModelCacheInventory.swift` inventories `Sources/Speech/` model caches.
- **New Tools package** needs a CI job and a test-matrix rule; `scripts/dev/check-known-traps.py` fails without them.

**Hotspots.** Four files are still over 1,500 lines: `TranscriptedSettingsView.swift` (3,897), `SpeakerPeopleSettingsSection.swift` (2,431), `TranscriptedApp.swift` (1,927) and `MeetingOverlayController.swift` (1,617). The riskiest code is meeting capture's stop ordering and the AirPods-sensitive engine touch, in `Sources/TranscriptedCore/Audio/Audio+CaptureLifecycle.swift` and `Audio+MeetingInputGraph.swift`. Read the whole file and its folder's `AGENTS.md` before editing any of these, and don't add another responsibility to them. No new Swift file may go over 800 lines, and the 45 that already are can only shrink (`scripts/dev/check-file-size.py`; a reviewed baseline bump is the exception). What each owns: `docs/repo-layout.md`.

## Releases

Read `docs/release-packaging.md` and `docs/sparkle-updates.md` before changing release flow. Use `build-beta.sh`, not `build.sh`, for builds that go to other machines. A release isn't done when the DMG exists: publish the signed archive, update `docs/appcast.xml`, and push it to the branch behind the live feed so installs see it; then `bash scripts/release/update-cask.sh <version>` and commit `Casks/transcripted.rb` for Homebrew. If you skip either, say so plainly. Keep `SUFeedURL` and `SUPublicEDKey` in `Info.plist` matching the real feed. For a Release Candidate workflow build, tag the workflow's `source_ref`, not the run's head SHA.

## Observability

Sentry and PostHog are bounded integrations, not log sinks. Off-device events pass allowlists in `Sources/Observability/SentryEventPolicy.swift` and `AnalyticsEventPolicy.swift`; if payload shape changes, update `SentryPayloadSanitizer.swift` and `AnalyticsPayloadSanitizer.swift` in the same change. Keep the crash-reporting and analytics toggles in Settings and "Send diagnostics" in About. Config keys, env overrides, and sinks: `Sources/Observability/AGENTS.md` and `docs/observability.md`.

## Storage

App state lives under `~/Library/Application Support/Transcripted/`, with saved meetings and dictations in `captures/`. Users can move the capture library (`transcriptSaveLocation`); state, cache, logs, and temp files stay put. Full map, including old `Draft` fallbacks: `docs/storage-paths.md`.

## Handoff and orchestration

For substantive work (research, audits, cross-cutting changes, design, reviews), default to a workflow that fans out parallel agents and cross-checks their findings instead of working solo; keep solo work for small mechanical edits and conversation. Workers inherit this default. Correctness and coverage matter more than token cost.

A worker reporting back to the Transcripted coordinator ends with one line:

`COORD_DONE: GREEN/BRIEF/RED | PR URL if any | changes made | GitHub cleanup recommendations | decisions needed | tests/checks run | lanes used: Codex=...; Claude=...; Local=...; Windows=... | smallest next action`

Cloud Claude sessions fill `lanes used` with `n/a (cloud session)`. Lane routing for the local Codex runner (`maestro-delegate`, proof paths) and the status meanings: `docs/agent-closeout.md`.

## Voice

Write like a real person texting a friend, not a presentation. Short, direct sentences; vary the rhythm. Casual connectors ("so", "anyway", "also") are fine. Say plainly when something is unclear. No marketing speak, no "dive into" or "let's explore", no piles of adjectives. Normal capitalization. Relaxed but clear.
