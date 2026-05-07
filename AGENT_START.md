# Agent Start

This is the shortest safe path for Codex, Claude Code, or another coding agent
to work in this repo.

## What This Repo Is

Transcripted is the current macOS app for local dictation, meeting capture,
imported-audio transcription, and agent-readable Markdown output.

The old Draft / ghostwriting product is not active on `main`. Historical files
exist for migration and reference only.

## Read Order

1. `AGENTS.md` - canonical agent rules
2. `docs/repo-layout.md` - live directory map
3. `docs/agent-onboarding.md` - doc trust order
4. nearest `CLAUDE.md` for the area being edited
5. `.agents/test-matrix.yml` - path-to-verification map

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

## Verification

Use `scripts/dev/agent-preflight.sh` to inspect the branch and get suggested
checks for the files changed.

Default rules:

- Swift app change: `bash build.sh` and `bash run-tests.sh`
- `Sources/Meeting/` or `Sources/TranscriptedCore/`: also `bash run-integration-smoke.sh`
- `Package.swift` or public core seam: also `swift test`
- release/update path: read `docs/release-packaging.md` and `docs/sparkle-updates.md`

## Safety

- Keep Transcripted local-first and privacy-safe.
- Do not send transcript text, audio references, meeting titles, speaker names,
  emails, tokens, absolute file paths, or raw device names off-device.
- Treat `archive/` and `docs/archive/` as historical unless the task explicitly
  asks for archive work.
- Stage only files changed for the current task.
- Never force-push.
