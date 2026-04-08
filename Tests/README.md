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

`run-tests.sh` compiles a hand-picked list of files into `build/tests` and runs
`Tests/TestRunner.swift`.

Important implications:

- adding a file under `Tests/` is not enough by itself
- new tests must also be wired into:
  - `run-tests.sh`
  - `Tests/TestRunner.swift`
- moving a source file compiled by `run-tests.sh` also requires updating the script

## Current Compiled Fast Tests

- `CapturedContextTests.swift`
- `DictationSoundsTests.swift`
- `DictationTranscriptWriterTests.swift`
- `DiffSummaryTests.swift`
- `RefusalDetectionTests.swift`
- `MeetingTranscriptStylerTests.swift`
- `SpeakerNamingPolicyTests.swift`
- `StyleUtilsTests.swift`

There are additional test files in `Tests/`, but only the ones wired into
`run-tests.sh` and `Tests/TestRunner.swift` currently execute in the fast lane.

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

Run it whenever you touch:

- `Sources/Meeting/`
- `Sources/TranscriptedCore/`
- dependency wiring in `build-deps.sh`
