# TranscriptedCore

## What this directory does

`Sources/TranscriptedCore/` is the reusable meeting transcription library embedded in this repo. It is consumed by the app through `Sources/Meeting/`, and it can also be tested as a standalone Swift package through the root `Package.swift`.

## Subsystems (71 Swift files)

- `Audio/` (21 files) — mic + system audio capture, imported-audio prep helpers, capture start-state gating, device recovery, Bluetooth-input avoidance for meetings, signal analysis and normalization helpers, real-time AGC, resampling, level metering, process tap, ScreenCaptureKit-backed system-audio capture, backend selection, buffer writing, merge helpers, and privacy-safe pipeline diagnostics snapshots
- `Logging/` (3 files) — shared app logger, JSONL file logger, and log privacy sanitizer
- `Models/` (5 files) — public data types: `TranscriptionResult`, `DisplayStatus`, `FailedTranscription`, `SpeakerMapping`, and recording-health metadata builders
- `Pipeline/` (4 files) — transcription orchestration, pipeline runner, and task queue
- `Protocols/` (7 files) — host-injected seams: `SpeechToTextEngine`, `DiarizationEngine`, `SpeakerStore`, `TranscriptNotifier`, `AudioCaptureEngine`, `StatsStore`, `TranscriptStorage`
- `Services/` (7 files) — DI container (`AppServices`), model bundle / download management, path indirection, recording validation, diarization, and failed-transcription persistence
- `Speaker/` (12 files) — speaker DB, embedding matching / clustering, clip extraction, naming policy / coordinator, people-review policy, profile merging, simulation, and retroactive transcript updates
- `Stats/` (4 files) — recording stats database, models, queries, and service
- `Storage/` (6 files) — transcript save, scanner, formatter, format options, shared frontmatter parsing, and retained-recording audio archiving
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
- `MeetingInputDeviceSelectionPolicy` avoids using Bluetooth headset input for meeting capture when a built-in mic fallback is available, so WebRTC-style playback downgrades do not get worse.
- `AudioSignalRecovery` is the shared low-level signal-analysis helper used when recorded audio needs peak / RMS / active-ratio checks or gain-normalized recovery clips before later transcription work.
- `RealtimeAGC` is the default meeting-mic cleanup path for attenuated shared-device input. It avoids the playback-ducking side effects of Apple voice processing while still boosting quiet WebRTC-contended captures and gating idle USB-mic noise. App hosts can disable it for raw/off meeting mic capture when the user has tuned hardware gain.
- `MeetingRecordingJournalStore` persists in-progress recording journals for launch recovery. Journal mutations are scoped to the session token returned by `begin(...)` so late stop-path writes cannot corrupt a newer recording's journal.
- `SCKAudioCapture` is the macOS 26+ backend for audio-only ScreenCaptureKit capture, which keeps system-audio recording on the lighter permission tier and avoids full screen-pixel capture.
- `AudioPipelineDiagnosticsSnapshot` is the privacy-safe route and buffer-health summary used for analytics and Sentry context. Keep it limited to bucketed device classes, rates, channel counts, and recovery state, never raw device names, transcript text, titles, file paths, or audio.
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

The standalone CLI/MCP tools parse this same Markdown format through a dependency-free mirror in `Tools/TranscriptedCaptureKit` (it intentionally does not link Core). If `TranscriptFormatter` or `TranscriptFrontmatter` changes the written format, update the kit's parsers and tests in the same change.

## Editing rules

- Keep app-shell UI types out of this directory.
- Prefer injected paths, injected providers, and protocol seams over `Bundle.main` or hard-coded home-directory assumptions.
- If a new dependency is needed by hosts, make it injectable at the core boundary rather than reaching out to app globals.
- If you change protocol signatures, `AppServices`, `Package.swift`, or public models, test both the app build and the standalone package boundary.

## Test and verification

Always run:

- `bash build-deps.sh --force`
- `bash build.sh --no-open`
- `bash run-tests.sh`
- `bash run-integration-smoke.sh`

Also run when the package seam changes:

- `swift test`

Current direct core coverage includes:

- `Tests/TranscriptedCoreTests/AudioInitializationTests.swift`
- `Tests/TranscriptedCoreTests/AudioDiagnosticsSnapshotTests.swift`
- `Tests/TranscriptedCoreTests/AudioLevelMonitorSilenceTests.swift`
- `Tests/TranscriptedCoreTests/AudioPipelineDiagnosticsSnapshotShapeTests.swift`
- `Tests/TranscriptedCoreTests/AudioResamplerTests.swift`
- `Tests/TranscriptedCoreTests/BluetoothMeetingRouteContractTests.swift`
- `Tests/TranscriptedCoreTests/CoreStoragePathsTests.swift`
- `Tests/TranscriptedCoreTests/DatabaseFilePermissionsTests.swift`
- `Tests/TranscriptedCoreTests/EmbeddingClustererTests.swift`
- `Tests/TranscriptedCoreTests/FailedTranscriptionManagerTests.swift`
- `Tests/TranscriptedCoreTests/FileLoggerTests.swift`
- `Tests/TranscriptedCoreTests/MeetingInputDeviceSelectionPolicyTests.swift`
- `Tests/TranscriptedCoreTests/MeetingRecordingJournalTests.swift`
- `Tests/TranscriptedCoreTests/MeetingRouteArtifactFixtureTests.swift`
- `Tests/TranscriptedCoreTests/DiarizationSpeakerIdParsingTests.swift`
- `Tests/TranscriptedCoreTests/MicRecordingFileMergerTests.swift`
- `Tests/MicRecordingMergePlanTests.swift`
- `Tests/TranscriptedCoreTests/QuietMicAttenuationDetectorTests.swift`
- `Tests/TranscriptedCoreTests/RealtimeAGCTests.swift`
- `Tests/TranscriptedCoreTests/RecordingAudioArchiverTests.swift`
- `Tests/TranscriptedCoreTests/RecordingHealthInfoOverrideTests.swift`
- `Tests/TranscriptedCoreTests/RetroactiveSpeakerUpdaterTests.swift`
- `Tests/TranscriptedCoreTests/SpeakerMatchingServiceTests.swift`
- `Tests/TranscriptedCoreTests/SpeakerEmbeddingMatcherTests.swift`
- `Tests/TranscriptedCoreTests/SpeakerNamingCoordinatorTests.swift`
- `Tests/TranscriptedCoreTests/SpeakerNamingSimulationRunnerTests.swift`
- `Tests/SpeakerPeopleReviewPolicyTests.swift`
- `Tests/TranscriptedCoreTests/SpeakerProfileMergerTests.swift`
- `Tests/TranscriptedCoreTests/StatsDatabaseTests.swift`
- `Tests/TranscriptedCoreTests/TranscriptFrontmatterTests.swift`
- `Tests/TranscriptedCoreTests/TranscriptMetadataBuilderTests.swift`
- `Tests/TranscriptedCoreTests/TranscriptionPipelineHelpersTests.swift`
- `Tests/TranscriptedCoreTests/TranscriptionTaskManagerMetadataTests.swift`
- `Tests/Integration/AppCoreIntegrationSmoke.swift`

Core coverage spans the package seam, audio initialization, speaker reconciliation, transcript metadata, stats, storage-path behavior, file-permission enforcement, failed-transcription persistence, file logging, recording archiving, and task-manager metadata.
