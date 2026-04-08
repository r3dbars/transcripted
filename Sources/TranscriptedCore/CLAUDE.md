# TranscriptedCore

## What this directory does

`Sources/TranscriptedCore/` is the reusable meeting transcription library embedded in this repo. It is consumed by the app through `Sources/Meeting/`, and it can also be tested as a standalone Swift package through the root `Package.swift`.

## Subsystems (59 Swift files)

- `Audio/` (9 files) — mic + system audio capture, device recovery, resampling, level metering, process tap, buffer writer
- `Logging/` (2 files) — shared app logger and JSONL file logger
- `Models/` (4 files) — public data types: `TranscriptionResult`, `DisplayStatus`, `FailedTranscription`, metadata builders
- `Pipeline/` (4 files) — transcription orchestration, pipeline runner, and task queue
- `Protocols/` (7 files) — host-injected seams: `SpeechToTextEngine`, `DiarizationEngine`, `SpeakerStore`, `TranscriptNotifier`, `AudioCaptureEngine`, `StatsStore`, `TranscriptStorage`
- `Services/` (7 files) — DI container (`AppServices`), model download, path indirection, recording validation, diarization, failed transcription manager
- `Speaker/` (10 files) — speaker DB, embedding matching/clustering, clip extraction, naming policy/coordinator, profile merging, retroactive updater
- `Stats/` (4 files) — recording stats database, models, queries, and service
- `Storage/` (4 files) — transcript save, scanner, formatter, JSON sidecar output
- `Utilities/` (4 files) — date helpers, permissions, transcript utility functions

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

- `~/Documents/Transcripted/` for transcripts, databases, clips, and failed queue
- `~/Library/Logs/Transcripted/` for logs

The app does **not** use those defaults for meetings. `Sources/Meeting/MeetingSessionController.swift` injects app-specific `CoreStoragePaths` rooted in the current Draft-named compatibility tree.

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

Current direct core coverage is thin and concentrated around the public seam:

- `Tests/TranscriptedCoreTests/CoreStoragePathsTests.swift`
- `SmokeTests/CoreIntegrationSmoke.swift`

That means many core changes still depend heavily on build + smoke validation.
