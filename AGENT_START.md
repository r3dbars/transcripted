# Agent Start

This is the shortest safe path for Codex, Claude Code, or another coding agent
to work in this repo.

## What This Repo Is

Transcripted is the current macOS app for local dictation, meeting capture,
imported-audio transcription, and agent-readable Markdown output.

The old Draft / ghostwriting product is not active on `main`. Historical files
exist for migration and reference only.

## Current Priorities

- Activation first: saved Markdown -> useful agent answer -> return later.
- Keep dictation reliable: start, stop, pasteback, clipboard restore, and saved
  dictation Markdown should stay boring.
- Keep meetings trustworthy: saved transcripts, retained audio, retry visibility,
  Zoom/Meet prompts, Bluetooth/AirPods behavior, and quiet-mic regressions matter.
- Keep agents oriented: classify the lane, read the local doc, run the mapped
  checks, and hand off with `COORD_DONE` when delegated.

## Read Order

1. `README.md` - public product overview and repo truth
2. `AGENTS.md` - canonical agent rules
3. `docs/repo-layout.md` - live directory map
4. `docs/agent-onboarding.md` - doc trust order
5. `CLAUDE.md` - Claude-oriented repo orientation
6. `Sources/CLAUDE.md` - app target orientation
7. nearest `CLAUDE.md` for the area being edited
8. `.agents/test-matrix.yml` - path-to-verification map

For activation or agent-handoff work, also read `docs/activation-lane.md`.
For delegated or coordinator work, use `docs/agent-closeout.md`.

## Edit Map

- `Sources/` - macOS app target
- `Sources/Accessibility/` - focused-editor AX metadata and overlay placement
- `Sources/Capture/` - global hotkeys and physical dictation trigger routing
- `Sources/Dictation/` - dictation transcript persistence and timeout helpers
- `Sources/Speech/` - dictation STT, audio recovery, device handling
- `Sources/Meeting/` - app-side meeting flow and bridge into core
- `Sources/TranscriptedCore/` - reusable meeting transcription library
- `Sources/UI/` - overlay, menu bar, settings, onboarding, agent connect
- `Sources/Support/` - preferences, permissions, paths, paste, launch behavior
- `Sources/Observability/` - logs, diagnostics, Sentry, PostHog, Sparkle
- `Sources/Reliability/` - wake / sleep recovery
- `Sources/Beta/` - beta-build configuration
- `Tests/` - fast tests and core package tests
- `Tools/` - standalone CLI, MCP, and QA packages

Common routing shortcuts:

- Activation/artifacts/agent payoff - `docs/activation-lane.md`
- Bluetooth/AirPods dictation - `Sources/Speech/CLAUDE.md` and `docs/audio-reliability-daily-check.md`
- Zoom/Meet prompts or quiet meeting audio - `Sources/Meeting/CLAUDE.md` and `docs/qa-issue-500-meeting-audio.md`
- Pasteback/clipboard/Auto Enter - `Sources/Support/CLAUDE.md`, `Sources/Accessibility/CLAUDE.md`, and `Sources/Dictation/CLAUDE.md`

## Verification

Use `scripts/dev/agent-preflight.sh` to inspect the branch and get suggested
checks for the files changed.

Default rules:

- Swift app change: `bash build.sh --no-open` and `bash run-tests.sh`
- `Sources/Meeting/` or `Sources/TranscriptedCore/`: also `bash run-integration-smoke.sh`
- `Package.swift` or public core seam: also `swift test`
- release/update path: read `docs/release-packaging.md` and `docs/sparkle-updates.md`

## Handoff

For worker-lane closeout, use the `AGENTS.md` coordinator closeout shape:
`Status`, `Changed`, `Verified`, `Risk`, `Next`.

## Safety

- Keep Transcripted local-first and privacy-safe.
- Do not send transcript text, audio references, meeting titles, speaker names,
  emails, tokens, absolute file paths, or raw device names off-device.
- Treat `archive/` and `docs/archive/` as historical unless the task explicitly
  asks for archive work.
- Stage only files changed for the current task.
- Never force-push.
