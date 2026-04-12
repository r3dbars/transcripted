# Tests Guide

## Test Surfaces

This repo has three distinct verification layers:

1. `bash run-tests.sh`
   Curated fast test runner built with raw `swiftc`
2. `swift test`
   Swift Package tests for the standalone `TranscriptedCore` package surface
3. `bash run-integration-smoke.sh`
   App-to-core linkage smoke test

`bash build.sh` is also part of normal verification because the app build is
not driven by Xcode or package test discovery.

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

`swift test` currently exercises the standalone package seam, including:

- `Tests/TranscriptedCoreTests/CoreStoragePathsTests.swift`

Use this when changing:

- `Package.swift`
- `Sources/TranscriptedCore/`
- public core seams used by embedders

## Integration Smoke

`bash run-integration-smoke.sh` verifies that the app-side dependency bundle
still exposes the `TranscriptedCore` types that `Sources/Meeting/` depends on.

The smoke sources now live under `Tests/Integration/` so the repo’s verification
surface stays under one top-level `Tests/` umbrella.

Run it whenever you touch:

- `Sources/Meeting/`
- `Sources/TranscriptedCore/`
- dependency wiring in `build-deps.sh`
