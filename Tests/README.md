# Tests Guide

## Test Surfaces

This repo has four distinct verification layers:

1. `bash run-tests.sh`
   Curated fast test runner built with raw `swiftc`
2. `bash run-integration-smoke.sh`
   App-to-core linkage smoke test
3. `swift test`
   Swift Package tests for the standalone `TranscriptedCore` package surface
4. `bash build.sh`
   Authoritative app build for the menubar target

## Fast Test Runner

`run-tests.sh` compiles the root fast tests listed in
`Tests/FastTests.manifest` into `build/tests` and generates a temporary runner
at build time.

Important implications:

- adding a root `Tests/*Tests.swift` file is not enough by itself
- new fast tests must be registered in:
  - `Tests/FastTests.manifest`
- moving a source file compiled by `run-tests.sh` also requires updating the script
- `run-tests.sh` now fails if the manifest and the actual root test files drift

The current compiled fast test set lives in `Tests/FastTests.manifest`.

## Core Package Tests

`swift test` currently exercises the standalone package seam under
`Tests/TranscriptedCoreTests/`, including storage paths, audio startup,
meeting-input selection, file logging, failed-transcription persistence,
recording archiving, stats, speaker reconciliation, transcript frontmatter, and
transcript metadata.

Use this when changing:

- `Package.swift`
- `Sources/TranscriptedCore/`
- public core seams used by embedders

## Integration Smoke

`bash run-integration-smoke.sh` verifies that the app-side dependency bundle
still exposes the `TranscriptedCore` types that `Sources/Meeting/` depends on.
It also runs the wake-recovery smoke binary and currently finishes with
`swift test --filter MicRecordingFileMergerTests`.

The smoke sources now live under `Tests/Integration/` so the repo’s verification
surface stays under one top-level `Tests/` umbrella.

Fast tests and smoke runs set `TRANSCRIPTED_DISABLE_FILE_LOGGER=1` so they do
not append test-only entries into the real `~/Library/Application Support/Transcripted/logs/app.jsonl`.

Run it whenever you touch:

- `Sources/Meeting/`
- `Sources/TranscriptedCore/`
- dependency wiring in `build-deps.sh`
