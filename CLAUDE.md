# Transcripted in `r3dbars/transcripted`

## What this repo is

`main` is the current Transcripted app, derived from the earlier Draft codebase. The active product on `main` is a macOS menubar app for:

- dictation
- meeting capture and local transcription

The old standalone Transcripted app is preserved on:

- branch `legacy/transcripted-standalone`
- tag `pre-draft-takeover-2026-04-06`

The older drafting / ghostwriting flow does not live on `main` anymore. `DictationSessionController` still exposes compatibility stubs for removed draft-mode entry points.

## First reads

Read these before making assumptions about the codebase:

1. `README.md`
2. `AGENTS.md`
3. `docs/repo-layout.md`
4. `docs/agent-onboarding.md`
5. `Sources/CLAUDE.md`
6. `Sources/Dictation/CLAUDE.md`
7. `Sources/Meeting/CLAUDE.md`
8. `Sources/TranscriptedCore/CLAUDE.md`
9. `Tests/README.md`
10. `docs/storage-paths.md`

## Build and test

Use `docs/repo-layout.md`, `Tests/README.md`, and `scripts/README.md` as the
canonical command map.

Rules:

1. After changing Swift source, run `bash build.sh` and `bash run-tests.sh`.
2. If you change `Sources/Meeting/` or `Sources/TranscriptedCore/`, also run `bash run-integration-smoke.sh`.
3. If you change `Package.swift` or the public `TranscriptedCore` seam, also run `swift test`.
4. `Sources/TranscriptedCore/` is a library boundary. Do not compile it directly into the app target.

## Repo map

Use `docs/repo-layout.md` for the active directory map, doc hierarchy, and
historical-zone boundaries.
