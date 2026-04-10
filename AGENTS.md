# Transcripted in `r3dbars/transcripted`

## Repo Truth

This repo currently builds the **Transcripted** menubar app for:

- local dictation
- local meeting capture and transcription
- agent-friendly transcript artifacts

Many internal file and type names still use `Draft*` from the takeover period. Treat those as compatibility naming, not as evidence of a separate Draft product living on `main`.

The old standalone app is preserved on:

- branch: `legacy/transcripted-standalone`
- tag: `pre-draft-takeover-2026-04-06`

## Main Areas

- `Sources/` — app entry point, UI, dictation, meetings, shared app utilities
- `Sources/Meeting/` — Transcripted-specific bridge into `TranscriptedCore`
- `Sources/TranscriptedCore/` — shared transcription/diarization library boundary
- `Sources/Reliability/` — wake-recovery coordination used by the app and smoke coverage
- `Tests/` — fast pure-Swift test suite
- `SmokeTests/` — integration smoke coverage for `TranscriptedCore` and wake recovery
- `Tools/TranscriptedQA/` — QA CLI
- `Tools/TranscriptedMCP/` — standalone MCP server for transcript artifacts
- `backend/` — beta backend/proxy support

## Build And Test

```bash
bash build-deps.sh
bash build.sh
bash run-tests.sh
bash run-integration-smoke.sh
swift test
```

Rules:

1. After changing Swift source, run `bash build.sh` and `bash run-tests.sh`.
2. If you touch `Sources/Meeting/`, `Sources/TranscriptedCore/`, or `Sources/Reliability/`, also run `bash run-integration-smoke.sh`.
3. `build.sh` builds the Transcripted app target only.
4. `Package.swift` exists so `Sources/TranscriptedCore/` can still be built and tested as a library surface with `swift test`.
5. `build.sh` intentionally excludes `Sources/TranscriptedCore/` from the app compile step; `build-deps.sh` inlines it into the unified dependency archive.

## Storage Notes

- App support data lives under `~/Library/Application Support/Transcripted/` for fresh installs.
- If `~/Library/Application Support/Draft/` already exists, `DraftPaths.swift` keeps using it for compatibility.
- Meeting-mode artifacts live under `~/Library/Application Support/{Draft|Transcripted}/meetings/`.
- Dictation markdown exports live under `~/Library/Application Support/{Draft|Transcripted}/dictations/`.
- `TranscriptedCore` still defaults to `~/Documents/Transcripted/` when used standalone or by tools that do not pass custom storage paths.

## Migration Assumption

This repo still follows the manual migration path:

- existing installs do not auto-upgrade from the old standalone app
- current builds preserve compatibility with the legacy Draft-named Application Support folder when it already exists
- old standalone release/update plumbing is not the active path on `main`
