# TranscriptedCore

## What this directory does

`Sources/TranscriptedCore/` is the reusable meeting transcription library embedded in this repo. It is consumed by the app through `Sources/Meeting/`, and it can also be tested as a standalone Swift package through the root `Package.swift`.

## Subsystems (90 Swift files)

- `Audio/` (22 files) — mic + system audio capture, imported-audio prep helpers, capture start-state gating, device recovery, Bluetooth-input avoidance for meetings, signal analysis and normalization helpers, real-time AGC, resampling, level metering, process tap, ScreenCaptureKit-backed system-audio capture, backend selection, buffer writing, merge helpers, and privacy-safe pipeline diagnostics snapshots
- `Logging/` (4 files) — shared app logger (`AppLogger`, subsystem-scoped, os.Logger + JSONL), JSONL file logger (`FileLogger`), log privacy sanitizer, and `LogTailTrimmer` (shared truncate-in-place rotation used by `FileLogger` and by the app target's `AppLogSink`); see `docs/observability.md` for the full sink map, including how this `AppLogger` differs from `Sources/Observability/AppLogSink.swift`
- `Models/` (5 files) — public data types: `TranscriptionResult`, `DisplayStatus`, `FailedTranscription`, `SpeakerMapping`, and recording-health metadata builders
- `Pipeline/` (4 files) — transcription orchestration, pipeline runner, and task queue
- `Protocols/` (7 files) — host-injected seams: `SpeechToTextEngine`, `DiarizationEngine`, `SpeakerStore`, `TranscriptNotifier`, `AudioCaptureEngine`, `StatsStore`, `TranscriptStorage`
- `Services/` (7 files) — DI container (`AppServices`), model bundle / download management, path indirection, recording validation, diarization, and failed-transcription persistence
- `Speaker/` (28 files) — speaker DB (`SpeakerDatabase`, instance-based, injected via `AppServices`; no `.shared` singleton), embedding matching / clustering, embedding thresholds and segment re-embedding, clip extraction, naming policy / coordinator, people-review policy, profile merging + provenance, simulation, retroactive transcript updates, negative-exemplar policy/store, write-path policy, and the recognition lifeline: match-outcome store, profile-health demotion, and review prioritization (see `docs/speaker-recognition-metrics.md`)
- `Stats/` (4 files) — recording stats database, models, queries, and service
- `Storage/` (7 files) — transcript save, scanner, formatter, format options, shared frontmatter parsing, retained-recording audio archiving, and `SQLiteHandle` (shared low-level SQLite open/prepare/step wrapper used by `SpeakerDatabase` and `StatsDatabase`)
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

`TranscriptSaver.saveTranscript(...)` writes a markdown transcript, including YAML speaker metadata and recording-health fields like `capture_quality`, `audio_gaps`, and `device_switches` when the host provides them. The written Markdown (frontmatter keys, `format_version` / `transcript_style` versioning, both body grammars, and the save → summary-injection → restyle lifecycle) is specified in `docs/capture-format.md` — keep that spec in sync with formatter changes, and keep new frontmatter keys flat (the shared parser skips indented lines).

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

Current direct core coverage includes (paths reflect the five per-subsystem
SPM test targets — `AudioTests`, `SpeakerTests`, `PipelineTests`,
`StorageTests`, `UtilitiesTests` — see root `CLAUDE.md` "Scoped test loops"):

- `Tests/TranscriptedCoreTests/AudioTests/AudioInitializationTests.swift`
- `Tests/TranscriptedCoreTests/AudioTests/AudioDiagnosticsSnapshotTests.swift`
- `Tests/TranscriptedCoreTests/AudioTests/AudioLevelMonitorSilenceTests.swift`
- `Tests/TranscriptedCoreTests/AudioTests/AudioLevelPublishGateTests.swift`
- `Tests/TranscriptedCoreTests/AudioTests/AudioPipelineDiagnosticsSnapshotShapeTests.swift`
- `Tests/TranscriptedCoreTests/AudioTests/AudioResamplerTests.swift`
- `Tests/TranscriptedCoreTests/AudioTests/AudioSignalRecoveryTests.swift`
- `Tests/TranscriptedCoreTests/AudioTests/BluetoothMeetingRouteContractTests.swift`
- `Tests/TranscriptedCoreTests/StorageTests/CoreStoragePathsTests.swift`
- `Tests/TranscriptedCoreTests/StorageTests/DatabaseFilePermissionsTests.swift`
- `Tests/TranscriptedCoreTests/SpeakerTests/EmbeddingClustererTests.swift`
- `Tests/TranscriptedCoreTests/PipelineTests/FailedTranscriptionManagerTests.swift`
- `Tests/TranscriptedCoreTests/UtilitiesTests/FileLoggerTests.swift`
- `Tests/TranscriptedCoreTests/AudioTests/MeetingInputDeviceSelectionPolicyTests.swift`
- `Tests/TranscriptedCoreTests/AudioTests/MeetingRecordingJournalTests.swift`
- `Tests/TranscriptedCoreTests/StorageTests/MeetingRouteArtifactFixtureTests.swift`
- `Tests/TranscriptedCoreTests/SpeakerTests/DiarizationSpeakerIdParsingTests.swift`
- `Tests/TranscriptedCoreTests/AudioTests/MicRecordingFileMergerTests.swift`
- `Tests/MicRecordingMergePlanTests.swift`
- `Tests/TranscriptedCoreTests/AudioTests/QuietMicAttenuationDetectorTests.swift`
- `Tests/TranscriptedCoreTests/AudioTests/RealtimeAGCTests.swift`
- `Tests/TranscriptedCoreTests/StorageTests/RecordingAudioArchiverTests.swift`
- `Tests/TranscriptedCoreTests/AudioTests/RecordingHealthInfoOverrideTests.swift`
- `Tests/TranscriptedCoreTests/SpeakerTests/RetroactiveSpeakerUpdaterTests.swift`
- `Tests/TranscriptedCoreTests/SpeakerTests/SpeakerMatchingServiceTests.swift`
- `Tests/TranscriptedCoreTests/SpeakerTests/SpeakerEmbeddingMatcherTests.swift`
- `Tests/TranscriptedCoreTests/SpeakerTests/SpeakerNamingCoordinatorTests.swift`
- `Tests/TranscriptedCoreTests/SpeakerTests/SpeakerNamingSimulationRunnerTests.swift`
- `Tests/SpeakerPeopleReviewPolicyTests.swift`
- `Tests/TranscriptedCoreTests/SpeakerTests/SpeakerProfileMergerTests.swift`
- `Tests/TranscriptedCoreTests/SpeakerTests/SpeakerProfileProvenanceTests.swift`
- `Tests/TranscriptedCoreTests/SpeakerTests/SpeakerProvenanceTests.swift`
- `Tests/TranscriptedCoreTests/StorageTests/StatsDatabaseTests.swift`
- `Tests/TranscriptedCoreTests/StorageTests/StatsDatabaseQueriesTests.swift`
- `Tests/TranscriptedCoreTests/StorageTests/StatsDatabaseModelsTests.swift`
- `Tests/TranscriptedCoreTests/StorageTests/StatsServiceTests.swift`
- `Tests/TranscriptedCoreTests/UtilitiesTests/LogPrivacySanitizerTests.swift`
- `Tests/TranscriptedCoreTests/StorageTests/TranscriptFormatVersionTests.swift`
- `Tests/TranscriptedCoreTests/StorageTests/TranscriptFrontmatterTests.swift`
- `Tests/TranscriptedCoreTests/AudioTests/TranscriptMetadataBuilderTests.swift`
- `Tests/TranscriptedCoreTests/PipelineTests/TranscriptionPipelineHelpersTests.swift`
- `Tests/TranscriptedCoreTests/PipelineTests/TranscriptionTaskManagerMetadataTests.swift`
- `Tests/Integration/AppCoreIntegrationSmoke.swift`

Core coverage spans the package seam, audio initialization, speaker reconciliation, transcript metadata, stats, storage-path behavior, file-permission enforcement, failed-transcription persistence, file logging, recording archiving, and task-manager metadata.
