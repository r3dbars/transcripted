# TranscriptedCore

## What this directory does

`Sources/TranscriptedCore/` is the reusable meeting transcription library embedded in this repo. It is consumed by the app through `Sources/Meeting/`, and it can also be tested as a standalone Swift package through the root `Package.swift`.

## Subsystems (55 Swift files)

- `Audio/` (11 files) — mic + system audio capture, device recovery, resampling, level metering, process tap, buffer writing, and merge helpers
- `Logging/` (2 files) — shared app logger and JSONL file logger
- `Models/` (4 files) — public data types: `TranscriptionResult`, `DisplayStatus`, `FailedTranscription`, and transcript metadata builders
- `Pipeline/` (4 files) — transcription orchestration, pipeline runner, and task queue
- `Protocols/` (7 files) — host-injected seams: `SpeechToTextEngine`, `DiarizationEngine`, `SpeakerStore`, `TranscriptNotifier`, `AudioCaptureEngine`, `StatsStore`, `TranscriptStorage`
- `Services/` (7 files) — DI container (`AppServices`), model bundle / download management, path indirection, recording validation, diarization, and failed-transcription persistence
- `Speaker/` (10 files) — speaker DB, embedding matching / clustering, clip extraction, naming policy / coordinator, profile merging, retroactive transcript updates
- `Stats/` (4 files) — recording stats database, models, queries, and service
- `Storage/` (4 files) — transcript save, scanner, formatter, JSON sidecar output
- `Utilities/` (2 files) — date formatting and file permission helpers

## The seams embedders should know

- `CoreStoragePaths` — redirects all persisted output away from the standalone defaults
- `ModelBundleProvider` — lets hosts override where offline model bundles are resolved
- `AppServices` — DI container over protocol-typed STT / diarization / speaker-store dependencies
- `TranscriptionTaskManager` — host-facing queue and orchestration surface
- `TranscriptNotifier` — optional callback channel for transcript-saved / failure notifications

These seams exist specifically so the app can embed the library without adopting the old standalone Transcripted app assumptions.

## Threading model

- `Audio` and several `Audio/*` helpers are **not** `@MainActor`. They run on audio or background threads.
- `TranscriptionTaskManager`, `Transcription`, and many service surfaces are `@MainActor ObservableObject`.
- Heavy pipeline work is pushed off the main actor through `nonisolated` async helpers in the pipeline runner.
- Any callback that handles live audio buffers must stay real-time safe.

## Storage behavior

Standalone `TranscriptedCore.default` paths point to:

- `~/Library/Application Support/Transcripted/captures/meetings/` for meeting captures
- `~/Library/Application Support/Transcripted/state/` for databases and failed queue
- `~/Library/Application Support/Transcripted/tmp/recordings/` for clips and raw audio scratch
- `~/Library/Application Support/Transcripted/logs/` for logs

The app still injects app-specific `CoreStoragePaths` for meetings so the
capture folder follows the selected capture library rather than a hard-coded
default path.

`TranscriptSaver.saveTranscript(...)` also writes:

- a markdown transcript
- an agent JSON sidecar
- an index file

## Editing rules

- Keep app-shell UI types out of this directory.
- Prefer injected paths, injected providers, and protocol seams over `Bundle.main` or hard-coded home-directory assumptions.
- If a new dependency is needed by hosts, make it injectable at the core boundary rather than reaching out to app globals.
- If you change protocol signatures, `AppServices`, `Package.swift`, or public models, test both the app build and the standalone package boundary.

## Test and verification

Always run:

- `bash build.sh`
- `bash run-tests.sh`
- `bash run-integration-smoke.sh`

Also run when the package seam changes:

- `swift test`

Current direct core coverage includes:

- `Tests/TranscriptedCoreTests/CoreStoragePathsTests.swift`
- `Tests/TranscriptedCoreTests/EmbeddingClustererTests.swift`
- `Tests/TranscriptedCoreTests/MicRecordingFileMergerTests.swift`
- `Tests/TranscriptedCoreTests/RetroactiveSpeakerUpdaterTests.swift`
- `Tests/TranscriptedCoreTests/SpeakerMatchingServiceTests.swift`
- `Tests/TranscriptedCoreTests/SpeakerNamingCoordinatorTests.swift`
- `Tests/TranscriptedCoreTests/SpeakerProfileMergerTests.swift`
- `Tests/TranscriptedCoreTests/StatsDatabaseTests.swift`
- `Tests/TranscriptedCoreTests/TranscriptionPipelineHelpersTests.swift`
- `SmokeTests/AppCoreIntegrationSmoke.swift`

Core coverage is still selective, but it is no longer limited just to the package seam. Speaker reconciliation, file merging, stats, and storage-path behavior now have direct tests.
