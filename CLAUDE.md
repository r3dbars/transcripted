# Transcripted in `r3dbars/transcripted`

## What this repo is

`main` is the current Transcripted app, derived from the earlier Draft codebase. The active product on `main` is a macOS menubar app for:

- dictation
- meeting capture and local transcription

The old standalone Transcripted app is preserved on:

- `legacy/transcripted-standalone`
- `pre-draft-takeover-2026-04-06`

The older draft / ghostwriting flow does not live on `main` anymore. `DictationSessionController` still exposes compatibility stubs for removed draft-mode entry points.

## First reads

Read these before making assumptions about the codebase:

1. `README.md`
2. `AGENTS.md`
3. `docs/agent-onboarding.md`
4. `Sources/CLAUDE.md`
5. `Sources/Dictation/CLAUDE.md`
6. `Sources/Meeting/CLAUDE.md`
7. `Sources/TranscriptedCore/CLAUDE.md`
8. `Tests/README.md`
9. `docs/storage-paths.md`

## Build and test

```bash
bash build-deps.sh
bash build.sh
bash run-tests.sh
bash run-integration-smoke.sh
swift test
```

Rules:

1. After changing Swift source, run `bash build.sh` and `bash run-tests.sh`.
2. If you change `Sources/Meeting/` or `Sources/TranscriptedCore/`, also run `bash run-integration-smoke.sh`.
3. If you change `Package.swift` or the public `TranscriptedCore` seam, also run `swift test`.
4. `Sources/TranscriptedCore/` is a library boundary. Do not compile it directly into the app target.

## Current architecture

- `Sources/TranscriptedApp.swift` wires the menubar app, popover, dictation overlay, and meeting overlay.
- `Sources/TranscriptedAppState.swift` owns app-wide services: `STTRouter`, `ContextCaptureEngine`, and the lazily built `MeetingSessionController`.
- `Sources/UI/DictationSessionController.swift` now handles dictation only. Removed draft-mode entry points surface a fixed error message.
- `Sources/Meeting/` adapts app-owned pieces like `ParakeetEngine` into `TranscriptedCore`.
- `Sources/TranscriptedCore/` contains the reusable meeting transcription library.
- Root `Package.swift` exists so `TranscriptedCore` can be tested as a standalone package surface.

## Documentation status

Most repo-level docs have now been resynced to the current dictation +
meetings codebase. Historical context now lives mainly under `docs/archive/`,
with the old beta worker archived under `archive/backend-beta-worker/`, plus
the old `.claude` QA skill.
