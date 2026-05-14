# Transcripted in `r3dbars/transcripted`

For day-to-day agent work, start with `AGENT_START.md` and treat `AGENTS.md` as
the canonical workflow contract. This file is only the Claude-oriented repo
orientation layer.

## What this repo is

`main` is the current Transcripted app, derived from the earlier Draft codebase. The active product on `main` is a macOS menubar app for:

- dictation
- meeting capture and local transcription
- optional local-speaker review for people sharing the room mic during meetings

The old standalone Transcripted app is preserved on:

- branch `legacy/transcripted-standalone`
- tag `pre-draft-takeover-2026-04-06`

The older drafting / ghostwriting flow does not live on `main` anymore. `DictationSessionController` still exposes compatibility stubs for removed draft-mode entry points.

## First reads

Read these before making assumptions about the codebase:

1. `AGENT_START.md`
2. `README.md`
3. `AGENTS.md`
4. `docs/repo-layout.md`
5. `docs/agent-onboarding.md`
6. `Sources/CLAUDE.md`
7. the nearest local `CLAUDE.md` for the area you are changing

## Build and test

Use `.agents/test-matrix.yml` or `scripts/dev/agent-preflight.sh` for the quick
path-to-checks map. If anything conflicts, follow `AGENTS.md`.

## Repo map

Use `docs/repo-layout.md` for the active directory map, doc hierarchy, and
historical-zone boundaries.
