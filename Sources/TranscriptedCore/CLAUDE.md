# TranscriptedCore

## What This Is

`Sources/TranscriptedCore/` is the shared meeting/transcription library kept
in-repo and linked into the app through the dependency bundle built by
`build-deps.sh`.

It is a library boundary, not part of the app target's direct `swiftc` source
list.

## Directory Map

- `Audio/` — mic/system capture, CoreAudio helpers, resampling, level monitoring
- `Logging/` — app/core logging infrastructure
- `Models/` — shared data models and metadata builders
- `Pipeline/` — transcription orchestration and task management
- `Protocols/` — app-facing protocol surface for STT, diarization, speaker
  store, transcript notifications, and storage
- `Services/` — DI container, storage-path injection, model download, failed
  transcription manager, diarization, validation
- `Speaker/` — speaker DB, matching, naming, clip extraction, retroactive update
- `Stats/` — stats database and service
- `Storage/` — transcript saving, formatting, scanning, agent sidecars
- `Utilities/` — date and file-permission helpers

## Core Rules

1. Keep app UI types and app-specific policy out of core
2. Use `CoreStoragePaths` instead of hard-coded Transcripted or Draft paths
3. Preserve the protocol seam so the app can inject its own STT and notifier
4. Treat audio capture types and pipeline types differently:
   - many pipeline/service types are `@MainActor`
   - audio capture helpers intentionally are not

## Build And Verification

```bash
bash build-deps.sh
bash run-integration-smoke.sh
swift test
```

The app build uses `build-deps.sh` to inline this library into the unified
dependency archive. `run-integration-smoke.sh` is the app-side check that the
core boundary still links cleanly.
