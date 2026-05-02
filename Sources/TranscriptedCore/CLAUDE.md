# TranscriptedCore

## What this directory does

`Sources/TranscriptedCore/` is the reusable meeting transcription library embedded in this repo. It is consumed by the app through `Sources/Meeting/`, and it can also be tested as a standalone Swift package through the root `Package.swift`.

## Subsystems (62 Swift files)

- `Audio/` (17 files) — mic + system audio capture, imported-audio prep helpers, capture start-state gating, device recovery, signal analysis and normalization helpers, real-time AGC, resampling, level metering, process tap, ScreenCaptureKit-backed system-audio capture, backend selection, buffer writing, merge helpers, and privacy-safe pipeline diagnostics snapshots
- `Logging/` (2 files) — shared app logger and JSONL file logger
- `Models/` (5 files) — public data types: `TranscriptionResult`, `DisplayStatus`, `FailedTranscription`, `SpeakerMapping`, and recording-health metadata builders
- `Pipeline/` (4 files) — transcription orchestration, pipeline runner, and task queue
- `Protocols/` (7 files) — host-injected seams: `SpeechToTextEngine`, `DiarizationEngine`, `SpeakerStore`, `TranscriptNotifier`, `AudioCaptureEngine`, `StatsStore`, `TranscriptStorage`
- `Services/` (7 files) — DI container (`AppServices`), model bundle / download management, path indirection, recording validation, diarization, and failed-transcription persistence
- `Speaker/` (10 files) — speaker DB, embedding matching / clustering, clip extraction, naming policy / coordinator, profile merging, retroactive transcript updates
- `Stats/` (4 files) — recording stats database, models, queries, and service
- `Storage/` (4 files) — transcript save, scanner, formatter, and retained-recording audio archiving
- `Utilities/` (2 files) — date formatting and file permission helpers

## The seams embedders should know

- `CoreStoragePaths` — redirects all persisted output away from the standalone defaults
- `ModelBundleProvider` — lets hosts override where offline model bundles are resolved
- `AppServices` — DI container over protocol-typed STT / diarization / speaker-store dependencies
- `TranscriptionTaskManager` — host-facing queue and orchestration surface, including imported-audio jobs and optional local-speaker mic diarization when the app asks for it
- `TranscriptNotifier` — optional callback channel for transcript-saved / failure notifications

These seams exist specifically so the app can embed the library without adopting the old standalone Transcripted app assumptions.

## Audio backend notes

- `Audio` can switch between the legacy CoreAudio path and the newer ScreenCaptureKit system-audio path through `SystemAudioCaptureEngine`.
- `AudioCaptureStartState` is the canonical readiness policy for live meeting capture. Meeting capture should not report success until mic recording is running and the system-audio file exists.
- `AudioSignalRecovery` is the shared low-level signal-analysis helper used when recorded audio needs peak / RMS / active-ratio checks or gain-normalized recovery clips before later transcription work.
- `RealtimeAGC` is the default meeting-mic cleanup path for attenuated shared-device input. It avoids the playback-ducking side effects of Apple voice processing while still boosting quiet WebRTC-contended captures.
- `SCKAudioCapture` is the macOS 26+ backend for audio-only ScreenCaptureKit capture, which keeps system-audio recording on the lighter permission tier and avoids full screen-pixel capture.
- Hosts embedding `TranscriptedCore` should keep app-specific permission UX outside this directory, but they should understand that system-audio capture backend behavior now depends on OS availability.
- Imported meeting audio is funneled through the same pipeline primitives as live captures so transcript formatting, stats, speaker naming, and retry behavior stay aligned.

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

`TranscriptSaver.saveTranscript(...)` writes a markdown transcript, including YAML speaker metadata and recording-health fields like `capture_quality`, `audio_gaps`, and `device_switches` when the host provides them.

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

- `Tests/TranscriptedCoreTests/AudioInitializationTests.swift`
- `Tests/TranscriptedCoreTests/CoreStoragePathsTests.swift`
- `Tests/TranscriptedCoreTests/DatabaseFilePermissionsTests.swift`
- `Tests/TranscriptedCoreTests/EmbeddingClustererTests.swift`
- `Tests/TranscriptedCoreTests/FailedTranscriptionManagerTests.swift`
- `Tests/TranscriptedCoreTests/FileLoggerTests.swift`
- `Tests/TranscriptedCoreTests/MicRecordingFileMergerTests.swift`
- `Tests/TranscriptedCoreTests/RealtimeAGCTests.swift`
- `Tests/TranscriptedCoreTests/RecordingAudioArchiverTests.swift`
- `Tests/TranscriptedCoreTests/RecordingHealthInfoOverrideTests.swift`
- `Tests/TranscriptedCoreTests/RetroactiveSpeakerUpdaterTests.swift`
- `Tests/TranscriptedCoreTests/SpeakerMatchingServiceTests.swift`
- `Tests/TranscriptedCoreTests/SpeakerNamingCoordinatorTests.swift`
- `Tests/TranscriptedCoreTests/SpeakerProfileMergerTests.swift`
- `Tests/TranscriptedCoreTests/StatsDatabaseTests.swift`
- `Tests/TranscriptedCoreTests/TranscriptMetadataBuilderTests.swift`
- `Tests/TranscriptedCoreTests/TranscriptionPipelineHelpersTests.swift`
- `Tests/TranscriptedCoreTests/TranscriptionTaskManagerMetadataTests.swift`
- `Tests/Integration/AppCoreIntegrationSmoke.swift`

Core coverage spans the package seam, audio initialization, speaker reconciliation, transcript metadata, stats, storage-path behavior, file-permission enforcement, failed-transcription persistence, file logging, recording archiving, and task-manager metadata.
