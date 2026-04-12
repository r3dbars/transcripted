# Transcripted Agent Guide

## Current repo truth

- `main` is the current Transcripted product, derived from the earlier Draft codebase.
- The current app on `main` supports **dictation** and **meetings**.
- The older draft / ghostwriting flow is not active on `main`. `DictationSessionController` keeps compatibility stubs for removed draft-mode entry points.
- `Sources/TranscriptedCore/` is an in-repo library consumed through `Sources/Meeting/`. Keep it as a library boundary.
- `build.sh` builds the app target. The root `Package.swift` exists for `TranscriptedCore` package tests and smoke coverage, not as the main app build.

## Read this first

1. `README.md`
2. `AGENTS.md`
3. `docs/agent-onboarding.md`
4. `Sources/CLAUDE.md`
5. `Sources/Dictation/CLAUDE.md` when touching dictation persistence
6. `Sources/Meeting/CLAUDE.md` when touching meeting capture or meeting UI
7. `Sources/TranscriptedCore/CLAUDE.md` when touching the shared library
8. `Tests/README.md`
9. `docs/storage-paths.md`

## Directory map

- `Sources/` — app shell, hotkeys, speech, dictation UI, meeting bridge, shared app paths
- `Sources/Dictation/` — markdown persistence for completed dictations
- `Sources/Meeting/` — app-side bridge into `TranscriptedCore`
- `Sources/Reliability/` — wake / sleep recovery coordination for active recording flows
- `Sources/TranscriptedCore/` — reusable meeting transcription library
- `Tests/` — fast custom Swift test runner plus `TranscriptedCore` package tests
- `SmokeTests/` — integration smoke for the bundled core library seam, plus a wake-recovery smoke check
- `Tools/TranscriptedCLI/` — standalone CLI for local context queries and offline diarization
- `Tools/TranscriptedMCP/` — read-only MCP server for saved meeting and dictation artifacts
- `Tools/TranscriptedQA/` — artifact validation CLI
- `archive/backend-beta-worker/` — archived beta proxy / telemetry backend

## Documentation status

The repo has both current docs and historical docs from the earlier drafting-focused codebase.

Current source-of-truth docs:

- `AGENTS.md`
- `CLAUDE.md`
- `docs/agent-onboarding.md`
- `Sources/CLAUDE.md`
- `Sources/Dictation/CLAUDE.md`
- `Sources/Meeting/CLAUDE.md`
- `Sources/TranscriptedCore/CLAUDE.md`
- `Tests/README.md`
- `docs/storage-paths.md`
- `Tools/TranscriptedCLI/CLAUDE.md`
- `Tools/TranscriptedMCP/CLAUDE.md`
- `Tools/TranscriptedQA/CLAUDE.md`

Beta/distribution-only docs:

- `archive/backend-beta-worker/README.md`

Historical or planning-heavy docs:

- `docs/archive/`
- `.claude/skills/transcripted-qa/SKILL.md`

The remaining `Sources/*/CLAUDE.md` files describe either live subsystems or
small retained utility areas. The historical merge/todo docs now live under
`docs/archive/`, and the old placeholder-only source docs were removed.

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
4. `build.sh` must not compile `Sources/TranscriptedCore/` directly into the app target.

## Testing gotchas

- `run-tests.sh` is a custom `swiftc` runner, not XCTest.
- Adding a root `Tests/*Tests.swift` file is not enough by itself; it must be registered in `Tests/FastTests.manifest`.
- `Tests/TranscriptedCoreTests/` is a separate Swift Package target, run via `swift test` rather than `run-tests.sh`.

## Storage

Current persisted data on `main` defaults to Transcripted-named roots:

- app support root: `~/Library/Application Support/Transcripted/`
- default capture library: `~/Library/Application Support/Transcripted/captures/`
- dictations: `<capture-library>/dictations/`
- meetings: `<capture-library>/meetings/`
- app-owned state: `~/Library/Application Support/Transcripted/state/`
- logs: `~/Library/Application Support/Transcripted/logs/`
- temporary recordings: `~/Library/Application Support/Transcripted/tmp/recordings/`

The capture library can be moved in Settings. Legacy `Draft` paths remain only
for migration/cleanup flows and some standalone-tool fallback logic.

See `docs/storage-paths.md` for the full map, including `TranscriptedCore` standalone defaults.
