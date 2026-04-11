# Transcripted Agent Guide

## Current repo truth

- `main` is the current Transcripted product.
- The active app supports **dictation** and **meetings**.
- The older draft / ghostwriting flow is not an active product path on `main`.
- `Sources/TranscriptedCore/` is an in-repo library boundary used by the app through `Sources/Meeting/`.
- `build.sh` builds the app target. The root `Package.swift` exists for `TranscriptedCore` package tests and smoke coverage.

## Read this first

1. `README.md`
2. `AGENTS.md`
3. `CLAUDE.md`
4. `docs/agent-onboarding.md`
5. `docs/storage-paths.md`
6. `Sources/CLAUDE.md`
7. `Sources/Dictation/CLAUDE.md` when touching dictation persistence
8. `Sources/Meeting/CLAUDE.md` when touching meeting capture, storage, or UI
9. `Sources/TranscriptedCore/CLAUDE.md` when touching the shared library
10. `Sources/Reliability/CLAUDE.md` when touching wake / hotkey recovery
11. `Tests/README.md`

## Directory map

- `Sources/` — app target, menu bar shell, capture routing, speech, storage, and UI
- `Sources/Dictation/` — dictation export persistence
- `Sources/Meeting/` — app-side meeting adapter layer over `TranscriptedCore`
- `Sources/TranscriptedCore/` — reusable meeting transcription library
- `Sources/Reliability/` — wake / hotkey recovery coordination
- `Tests/` — curated fast tests plus the `TranscriptedCore` package tests
- `SmokeTests/` — app/core integration smoke coverage
- `Tools/TranscriptedCLI/` — standalone CLI for context search and offline diarization
- `Tools/TranscriptedMCP/` — read-only MCP server over saved captures
- `Tools/TranscriptedQA/` — standalone artifact validation CLI
- `archive/backend-beta-worker/` — archived beta proxy / telemetry backend

## Documentation status

Current source-of-truth docs:

- `README.md`
- `AGENTS.md`
- `CLAUDE.md`
- `docs/agent-onboarding.md`
- `docs/storage-paths.md`
- `docs/agent-connect.md`
- `Sources/CLAUDE.md`
- `Sources/Dictation/CLAUDE.md`
- `Sources/Meeting/CLAUDE.md`
- `Sources/TranscriptedCore/CLAUDE.md`
- `Sources/Reliability/CLAUDE.md`
- `Tests/README.md`
- `Tools/TranscriptedCLI/CLAUDE.md`
- `Tools/TranscriptedMCP/CLAUDE.md`
- `Tools/TranscriptedQA/CLAUDE.md`

Historical or archived context:

- `docs/archive/`
- `archive/backend-beta-worker/`

## Storage reality

The current app separates captures from app-owned state.

Default app root:

- `~/Library/Application Support/Transcripted/`

Default capture library:

- `~/Library/Application Support/Transcripted/captures/`

Default capture folders:

- meetings: `~/Library/Application Support/Transcripted/captures/meetings/`
- dictations: `~/Library/Application Support/Transcripted/captures/dictations/`

App-owned folders:

- state: `~/Library/Application Support/Transcripted/state/`
- cache: `~/Library/Application Support/Transcripted/cache/`
- logs: `~/Library/Application Support/Transcripted/logs/`
- tmp recordings: `~/Library/Application Support/Transcripted/tmp/recordings/`

The capture library can be relocated in Settings via `transcriptSaveLocation`.
Legacy Draft and `~/Documents/Transcripted` layouts still appear in compatibility
paths for some tools, but they are no longer the default app storage model.

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
2. If you touch `Sources/Meeting/` or `Sources/TranscriptedCore/`, also run `bash run-integration-smoke.sh`.
3. If you touch `Package.swift`, `Sources/TranscriptedCore/`, or the public core seam, also run `swift test`.
4. Keep `Sources/TranscriptedCore/` as a library boundary. Do not compile it directly into the app target.

## Testing gotchas

- `run-tests.sh` is a custom `swiftc` runner, not XCTest discovery.
- Adding a root `Tests/*Tests.swift` file is not enough by itself; it must be registered in `Tests/FastTests.manifest`.
- `Tests/TranscriptedCoreTests/` is a separate Swift Package target, run via `swift test`.

## Doc update triggers

Update docs in the same change whenever you modify:

- capture-library or storage-path behavior
- build or test commands
- tool defaults or env overrides
- ownership boundaries between app code and `TranscriptedCore`
- wake-recovery or hotkey lifecycle assumptions
- agent-facing output schemas or folder conventions
