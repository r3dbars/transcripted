# TranscriptedCore

## What this directory owns

`Sources/TranscriptedCore/` is the reusable meeting transcription library
embedded in this repo. The app uses it through `Sources/Meeting/`, and the root
`Package.swift` exposes it for standalone package tests.

## Subsystems

- `Audio/` — mic + system audio capture, resampling, level metering, recovery, and scratch-file writing
- `Logging/` — shared app logger and JSONL file logger
- `Models/` — public data types such as `TranscriptionResult`, `DisplayStatus`, and failed-transcription metadata
- `Pipeline/` — transcription orchestration, pipeline runner, and task queue
- `Protocols/` — host-injected seams: `SpeechToTextEngine`, `DiarizationEngine`, `SpeakerStore`, `TranscriptNotifier`, `AudioCaptureEngine`, `StatsStore`, `TranscriptStorage`
- `Services/` — DI container, model download, path indirection, recording validation, diarization, and failed-transcription management
- `Speaker/` — speaker DB, embeddings, matching, naming, clip extraction, and retroactive updates
- `Stats/` — recording stats database and query services
- `Storage/` — transcript saving, markdown formatting, sidecar/index writing, and scanning
- `Utilities/` — date, permissions, and transcript helpers

## Host seams to know

- `CoreStoragePaths` — central filesystem layout for captures, DBs, failed queue, logs, and raw-audio scratch
- `ModelBundleProvider` — lets hosts override where offline model bundles resolve
- `AppServices` — DI container over protocol-typed STT / diarization / speaker-store dependencies
- `TranscriptionTaskManager` — host-facing queue and orchestration surface
- `TranscriptNotifier` — optional callback channel for transcript-saved / failure notifications

## Current default paths

`CoreStoragePaths.default` now uses the Transcripted Application Support layout:

- captures: `~/Library/Application Support/Transcripted/captures/meetings/`
- state: `~/Library/Application Support/Transcripted/state/`
- logs: `~/Library/Application Support/Transcripted/logs/`
- raw audio scratch: `~/Library/Application Support/Transcripted/tmp/recordings/`

The app still injects its own `CoreStoragePaths` so:

- meeting transcripts follow the selected capture library
- databases, failed queue, logs, and scratch stay under the app-owned Transcripted folders

## Threading model

- most audio capture types are not `@MainActor`
- `TranscriptionTaskManager`, `Transcription`, and many service surfaces are `@MainActor`
- heavy pipeline work is pushed off the main actor through async helpers
- any callback touching live audio buffers must remain real-time safe

## Editing rules

- keep app-shell UI types out of this directory
- prefer injected paths, providers, and protocol seams over global app assumptions
- if you change protocol signatures, `AppServices`, public models, or path semantics, verify both the app and package seams

## Verify

Always run:

- `bash build.sh`
- `bash run-tests.sh`
- `bash run-integration-smoke.sh`

Also run when the package seam changes:

- `swift test`

Direct coverage is still thin and centered on the public seam:

- `Tests/TranscriptedCoreTests/CoreStoragePathsTests.swift`
- `SmokeTests/CoreIntegrationSmoke.swift`
