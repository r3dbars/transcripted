# TranscriptedCore

## What this directory does

`Sources/TranscriptedCore/` is the reusable meeting transcription library embedded in this repo. It is consumed by Draft through `Sources/Meeting/`, and it can also be tested as a standalone Swift package through the root `Package.swift`.

## Subsystems

- `Audio/` — mic + system audio capture, recovery, resampling, level metering
- `Logging/` — shared loggers and JSONL file logging
- `Models/` — public data types like `TranscriptionResult`, `DisplayStatus`, and metadata builders
- `Pipeline/` — transcription orchestration and task queue
- `Protocols/` — host-injected seams such as `SpeechToTextEngine`, `DiarizationEngine`, `SpeakerStore`, `TranscriptNotifier`
- `Services/` — DI container, model download, path indirection, recording validation, diarization
- `Speaker/` — speaker DB, matching, clip extraction, naming helpers
- `Stats/` — recording stats database and service
- `Storage/` — transcript save, scanner, formatter, JSON sidecars
- `Utilities/` — date helpers, permissions, transcript utility functions

## The seams embedders should know

- `CoreStoragePaths` — redirects all persisted output away from the standalone defaults
- `ModelBundleProvider` — lets hosts override where offline model bundles are resolved
- `AppServices` — DI container over protocol-typed STT / diarization / speaker-store dependencies
- `TranscriptionTaskManager` — host-facing queue and orchestration surface
- `TranscriptNotifier` — optional callback channel for transcript-saved / failure notifications

These seams exist specifically so Draft can embed the library without adopting the old standalone Transcripted app assumptions.

## Threading model

- `Audio` and several `Audio/*` helpers are **not** `@MainActor`. They run on audio or background threads.
- `TranscriptionTaskManager`, `Transcription`, and many service surfaces are `@MainActor ObservableObject`.
- Heavy pipeline work is pushed off the main actor through `nonisolated` async helpers in the pipeline runner.
- Any callback that handles live audio buffers must stay real-time safe.

## Storage behavior

Standalone `TranscriptedCore.default` paths point to:

- `~/Documents/Transcripted/` for transcripts, databases, clips, and failed queue
- `~/Library/Logs/Transcripted/` for logs

Draft does **not** use those defaults for meetings. `Sources/Meeting/MeetingSessionController.swift` injects Draft-specific `CoreStoragePaths`.

`TranscriptSaver.saveTranscript(...)` also writes:

- a markdown transcript
- an agent JSON sidecar
- an index file

## Editing rules

- Keep Draft UI and app-shell types out of this directory.
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
