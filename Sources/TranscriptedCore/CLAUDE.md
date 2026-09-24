# TranscriptedCore

## What this directory does

`Sources/TranscriptedCore/` is the reusable meeting transcription library embedded in this repo. It is consumed by the app through `Sources/Meeting/`, and it can also be tested as a standalone Swift package through the root `Package.swift`.

## Subsystems

Folder summaries first, then every file by role. Counts are left out on purpose; run `find Sources/TranscriptedCore -name '*.swift'` for the live list.

- `Audio/` — mic + system audio capture, imported-audio prep helpers, capture start-state gating, device recovery, Bluetooth-input avoidance for meetings, signal analysis and normalization helpers, bounded retry-availability signal probing, real-time AGC, resampling, level metering, Core Audio process-tap and legacy ScreenCaptureKit system-audio capture, backend selection, bounded buffer writing, merge helpers, and privacy-safe pipeline diagnostics snapshots
  - `Audio.swift` — the `Audio` capture class plus its stop-cleanup, lifecycle-cue (`CaptureLifecycleCue`), `SystemAudioStatus`, and recording-format policy types
  - `AudioFileManager.swift` — `extension Audio` for capture setup, WAV writing, and mic/system buffer writes, plus the system-audio start-attempt serializer and generation-scoped attempt ownership
  - `AudioCaptureStartState.swift` — start-state readiness policy, start-failure stage marker, and voice-processing start fallback policy
  - `AudioDeviceRecovery.swift` — `AudioRecoveryTuning` (shared mic/system recovery constants) and the mic recovery, retry, device-switch counting, tap-format, and watchdog policies
  - `AudioLevelMonitor.swift` — `extension Audio` for level metering, silence detection, and rolling buffers (audio-callback threads)
  - `AudioPipelineDiagnosticsSnapshot.swift` — privacy-safe route/buffer-health snapshot for analytics and Sentry
  - `AudioResampler.swift` — pure-Swift Float32 mono resampling to 16 kHz
  - `AudioSignalRecovery.swift` — peak / RMS / active-ratio analysis and gain-normalized recovery
  - `CoreAudioSystemAudioCapture.swift` — Core Audio private process-tap system-audio backend (System Audio Recording Only)
  - `CoreAudioTapBufferRing.swift` — preallocated single-producer / single-consumer ring between the tap IOProc and its serial queue
  - `CoreAudioUtils.swift` — `AudioObjectID` / property-address helpers
  - `SCKAudioCapture.swift` — legacy ScreenCaptureKit system-audio backend with its one bounded recovery
  - `SystemAudioCaptureEngine.swift` — backend protocol plus `SystemAudioRecoveryEvent`
  - `SystemAudioTapFailure.swift` — last failed HAL step + OSStatus codes and per-recording tap diagnostics counts
  - `FailedRecordingSignalProbe.swift` — bounded three-valued "is there still audio worth retrying" check
  - `MeetingInputDeviceSelectionPolicy.swift` — meeting mic selection mode/policy (Bluetooth avoidance, explicit binds)
  - `MeetingRecordingJournal.swift` — on-disk in-progress recording journal and its session-token-scoped store
  - `MicRecordingFileMerger.swift` — merges mic segment WAVs into one 16 kHz file, salvaging/padding bad segments
  - `MicRecordingSegment.swift` — segment value type and `MicRecordingMergePlan` gap-silence math
  - `MicrophoneDownmix.swift` — keeps the strongest mic channel instead of averaging
  - `PCMBufferBackpressureGate.swift` — hard byte-admission limit for retained PCM buffers, stop admission, and bounded fan-out
  - `QuietMicAttenuationDetector.swift` — one-shot detector for a mic held in foreign voice-processing mode (issue #500)
  - `RealtimeAGC.swift` — real-time meeting-mic AGC
  - `WAVHeaderRepair.swift` — recomputes RIFF/data sizes for WAVs whose writer never finalized
- `Logging/` — shared app logger (`AppLogger`, subsystem-scoped, os.Logger + JSONL), JSONL file logger (`FileLogger`), generic privacy text redactor, Core log metadata sanitizer, and `LogTailTrimmer` (shared truncate-in-place rotation used by `FileLogger` and by the app target's `AppLogSink`); see `docs/observability.md` for the full sink map, including how this `AppLogger` differs from `Sources/Observability/AppLogSink.swift`
  - `AppLogger.swift`, `FileLogger.swift`, `LogTailTrimmer.swift` — as above
  - `PrivacyTextRedactor.swift` — generic free-form diagnostic text redaction
  - `LogPrivacySanitizer.swift` — Core log metadata sanitizer (sensitive-key redaction)
- `Models/` — public data types
  - `TranscriptionTypes.swift` — `TranscriptionUtterance`, `TranscriptionResult`, `PipelineError`, and speaker-naming request/entry types
  - `DisplayStatus.swift` — UI progress phases and `TranscriptionTask`
  - `FailedTranscription.swift` — `PipelineErrorKind` classification and the persisted `FailedTranscription`
  - `SpeakerMapping.swift` — speaker label → identified name mapping
  - `RecordingHealthInfo.swift` — recording-health metadata for transcript frontmatter
  - `TranscriptionLanguage.swift` — `TranscriptionLanguageSelection` / `TranscriptionLanguageContext`
- `Pipeline/` — transcription orchestration, pipeline runner, task queue, and per-flow failure display copy keyed by `PipelineErrorKind`
  - `TranscriptionTaskManager.swift` — the host-facing single-flight queue/orchestrator
  - `TranscriptionPipelineRunner.swift` — `extension TranscriptionTaskManager` that runs the pipeline off the main actor (multichannel, mic-only, imported audio) with speaker identification, plus the rollback registry
  - `Transcription.swift` — the `Transcription` service object
  - `TranscriptionPipeline.swift` — `extension Transcription` for local multichannel / mic-only transcription, mic-channel diarization, and speech-segment detection
  - `TranscriptionLanguageSampling.swift` — picks bounded voiced samples for language detection
  - `PipelineFailureDisplayCopy.swift` — per-flow failure copy table
- `Protocols/` — host-injected seams: `SpeechToTextEngine`, `DiarizationEngine`, `SpeakerStore`, `TranscriptNotifier`, `StatsStore`, and the typed `ImportedTranscriptionRecoverySession` ownership handoff (one file per protocol, same names)
- `Services/` — DI container (`AppServices`), model bundle / download management, path indirection, capture-library path safety checks, recording validation, diarization, and failed-transcription persistence
  - `AppServices.swift`, `CoreStoragePaths.swift`, `ModelBundleProvider.swift` — the seams listed below
  - `ModelDownloadService.swift` — model download with mirror fallback, retry, and error classification
  - `DiarizationService.swift` — FluidAudio offline diarization (`DiarizationEngine` conformer)
  - `RecordingValidator.swift` — pre-recording system checks
  - `FailedTranscriptionManager.swift` — persistent failed-transcription queue
  - `CaptureLibraryPathSafety.swift` — synced copy of the capture-library path checks (also in `Sources/Support/` and `Tools/TranscriptedCaptureKit/`)
- `Speaker/` — speaker DB (`SpeakerDatabase`, instance-based, injected via `AppServices`; no `.shared` singleton), an ERes2Net on-device embedding model wrapper, embedding matching / clustering, embedding thresholds and segment re-embedding, multi-exemplar voiceprint policy and store, clip extraction, naming policy / coordinator, people-review policy, profile merging + provenance, retroactive transcript updates, negative-exemplar policy/store, write-path policy, a single-write-path identity mutation service for name/merge changes across the DB and saved transcripts, and the recognition lifeline: match-outcome store, profile-health demotion, and review prioritization (see `docs/speaker-recognition-metrics.md`)
  - Database and its extensions: `SpeakerDatabase.swift` (SQLite voice-fingerprint store), `SpeakerProfile.swift` (profile + match-result types), `SpeakerEmbeddingMatcher.swift` (`matchSpeaker`), `SpeakerProfileMerger.swift` (profile management/merging), `SpeakerProfileProvenance.swift` (provenance audit tables + un-merge), `SpeakerConfirmationStore.swift` (explicit user-confirmation ledger), `SpeakerExemplarStore.swift`, `SpeakerNegativeExemplarStore.swift`, `SpeakerMatchOutcomeStore.swift`
  - Embeddings and matching: `SpeakerSegmentEmbedder.swift` (host-injected re-embedding seam), `ERes2NetEmbedder.swift` (CoreML ERes2Net conformer), `SpeakerEmbeddingThresholds.swift` (per-model cosine thresholds), `SpeakerVectorMath.swift`, `EmbeddingClusterer.swift` (diarization segment post-processing), `SpeakerMatchingService.swift` (`extension Transcription`, in-memory matching against profiles)
  - Policies: `SpeakerNamingPolicy.swift` (auto-accept ladder, initial mapping), `SpeakerExemplarPolicy.swift`, `SpeakerNegativeExemplarPolicy.swift`, `SpeakerWritePathPolicy.swift` (voiceprint write-back gates), `SpeakerPeopleReviewPolicy.swift`, `SpeakerReviewPrioritizer.swift`
  - Lifeline: `SpeakerMatchOutcome.swift` (outcome kinds + `SpeakerProfileHealth` demotion)
  - Failures: `SpeakerFinalizationFailure.swift` (coarse, off-device-safe reason codes for why a speaker review could not be saved)
  - Naming and transcript rewrites: `SpeakerNamingCoordinator.swift` (`extension TranscriptionTaskManager` + review-ownership registry), `SpeakerIdentityMutationService.swift`, `SpeakerClipExtractor.swift`, `RetroactiveSpeakerUpdater.swift` plus `RetroactiveSpeakerUpdater+Scanning.swift`, `RetroactiveSpeakerUpdater+TranscriptRewrite.swift`, and `RetroactiveSpeakerUpdater+BreakdownRewrite.swift` (all `extension TranscriptSaver`)
- `Stats/` — recording stats database (`StatsDatabase.swift`), models (`StatsDatabaseModels.swift`), and queries (`StatsDatabaseQueries.swift`)
- `Storage/` — transcript save (`TranscriptSaver.swift`), formatter (`TranscriptFormatter.swift`), format options (`TranscriptFormatOptions.swift`), shared frontmatter parsing (`TranscriptFrontmatter.swift`), retained-recording audio archiving (`RecordingAudioArchiver.swift`), and `SQLiteHandle` (shared low-level SQLite open/permission/pragma bootstrap used by `SpeakerDatabase` and `StatsDatabase`)
- `Utilities/` — date formatting (`DateFormattingHelper.swift`), file permission helpers (`FilePermissions.swift`), and `SupersessionEpoch` (a generation/epoch counter for superseded async work)

## The seams embedders should know

- `CoreStoragePaths` — redirects all persisted output away from the standalone defaults
- `ModelBundleProvider` — lets hosts override where offline model bundles are resolved
- `AppServices` — DI container over protocol-typed STT / diarization / speaker-store dependencies
- `Transcription.transcribeAudioFile(at:languageSelection:onProgress:)` — file-only diarization, transcription, and speaker matching for standalone hosts. Reuses the meeting pipeline and returns `TranscriptionResult` without capturing, saving, archiving, or deleting input audio. Calls on one instance must be serialized. Its injected engines control model downloads, and its injected `SpeakerStore` may be mutated; use an isolated snapshot store when the original speaker database must stay unchanged.
- `TranscriptionTaskManager` — host-facing queue and orchestration surface, including imported-audio jobs and optional local-speaker mic diarization when the app asks for it
- `ImportedTranscriptionRecoverySession` — keeps app-owned imported-audio recovery alive across Core transcript commit and deferred speaker-review scratch cleanup. Core must durably prepare cleanup before deleting scratch, and reports completion only after deletion, without an untyped terminal callback or parallel ownership map
- `TranscriptNotifier` — optional callback channel for transcript-saved / failure notifications

These seams exist specifically so the app can embed the library without adopting the old standalone Transcripted app assumptions.

## Audio backend notes

- `Audio` resolves its system-audio backend through `SystemAudioCaptureEngine`; `CoreAudioSystemAudioCapture` uses Core Audio process taps for System Audio Recording Only permission. Tests inject stubs through the same seam. The legacy `SCKAudioCapture` implementation remains for its regression tests, not as an automatic permission-expanding fallback. `CoreAudioSystemAudioCapture` records the last HAL step that refused and its OSStatus as a `SystemAudioTapFailure`; `AudioPipelineDiagnosticsSnapshot` reports it as `system_tap_step`/`system_tap_status` so start failures and lost reconnects are diagnosable off-device. Keep both values codes, never error text. `SystemAudioSilenceWatch` is the tap's digital-silence watch: armed at start, after a wake, after a stall or format rebuild, and when the default output changes, it rebuilds the tap a bounded number of times only while another process is running audio output, then sets `CoreAudioSystemAudioCapture.isNotHearingPlayback` (read lock-free through `Audio.isSystemAudioNotHearingPlayback`) so the host can warn during the meeting. Zeros on a quiet Mac never trigger it. A wake gets one silent-tap rebuild, not more: a call app keeps its output running while the far end is quiet, so extra rebuilds only cut real audio. If signal later returns on the same tap, the report was a quiet call and is cleared; only signal that needed a non-wake rebuild or an output move sets `didLosePlayback` (`Audio.systemAudioDidLosePlayback`), which is what keeps a saved meeting degraded. A sleep ends an open report (the wake watch reports again if the new tap is still deaf), and a watch never expires while a report is open.
- `AudioCaptureStartState` is the canonical readiness policy for live meeting capture. Meeting capture should not report success until mic recording is running and the system-audio file exists. The one exception is a mic-only recording: a host that sets `Audio.capturesSystemAudio = false` before `start()` (the user picked "Record Just My Mic") gets no system-audio tap at all, readiness waits on the mic alone (`requiresSystemAudio: false`), and sleep/wake, health grading, late tap errors and recovery events, and diagnostics ignore the previous meeting's tap (read the tap through `recordingSystemAudioCapture`, never `systemAudioCapture` directly). The crash journal records the choice (`micOnlyByChoice`). At stop the host writes `MicOnlySilentSystemTrack` (a sparse silent WAV at the mic's sample rate, as long as the mic) so the meeting keeps the two-track shape the rest of the pipeline expects, and marks the health `markingSystemAudioSkippedByChoice()`: the formatter writes `mic_only: true`, and `markingSystemAudioMissing()` becomes a no-op so a deliberate choice is never saved as degraded. Failed rows carry `micOnlyByChoice`; `retryFailedTranscription` writes a missing silent track and `retryHealthInfo(for:)` keeps the marker.
- Wake recovery snapshots the recording generation and exact system-audio backend when the wake notification arrives. Both settle delays and the handoff after native microphone recovery must reject a stopped/replaced session, so an old wake cannot restart a newer meeting or consume its sleep marker.
- `MeetingInputDeviceSelectionPolicy` defaults to avoiding Bluetooth headset input for meeting capture when a built-in mic fallback is available, so WebRTC-style playback downgrades do not get worse. Hosts may explicitly set `Audio.meetingInputDeviceSelectionMode = .preserveDefault` before `start()` to use the macOS microphone, including a headset. The mode is captured for the recording and survives graph retries; later setting changes apply at the next meeting. A rejected explicit device bind fails the graph attempt and uses the existing bounded retry instead of recording from the previous microphone. The selected input remains pinned through normal recovery. If the pinned mic fails to start, or a recovery attempt fails (or the mic never delivered a frame), the graph falls back to the best built-in mic (`builtInFallbackAfterFailure`), at start and in recovery alike. With a MacBook's lid closed (`MacLidState`), its own mic (`isLidMicrophone`, not the headphone-jack mic) is left out of every built-in pick, since it records silence without failing. Neither mode changes the macOS input or output setting.
- Mic recovery: an `AVAudioEngineConfigurationChange` observer (`MicEngineConfigurationChangePolicy`) restarts a stopped meeting mic ~0.25s after a route change instead of waiting for the watchdog, within the watchdog's attempt limit. A device-change recovery first restarts the existing engine in place when it is still bound to the pinned, non-Bluetooth mic (`MicInPlaceRestartPolicy`), because a fresh `AVAudioEngine` input node touches the macOS default input and can flip AirPods into call mode. A failed recovery is not terminal: the meeting keeps recording and the watchdog retries, stopping only after `maxRecoveryAttempts` in a row. Recovery segments are registered before their first frame so Stop keeps them, and a header-only segment merges as empty.
- `CoreAudioSystemAudioCapture` reconnects after a ring overflow (up to 3 per recording) instead of ending system audio, padding the dropped span (`lostFrames`) and reporting `.fellBehind`, which holds writes like a reconnect but is not counted as a device switch.
- `AudioSignalRecovery` is the shared low-level signal-analysis helper used when recorded audio needs peak / RMS / active-ratio checks or gain-normalized recovery clips before later transcription work. `hasSpeechLikeModulation` and `normalizeForSpeech(ignoringSpikes:)` serve the pipeline's last-chance pass, which silence-splits diarizer-dependent tracks (the call side when a meeting came out empty, and a split-mode mic with no words) before "No speech found"; the normal pass keeps plain-peak gain and drops sub-second system segments until a corpus A/B says otherwise.
- `FailedRecordingSignalProbe` wraps that check for the failed-meeting retry decision, streaming an artifact in bounded windows instead of loading it whole. Its result is intentionally three-valued: `.absent` is reported **only** after the entire artifact has been examined, and anything unreadable or longer than the scan budget is `.inconclusive`. Hosts must never suppress a retry affordance on `.inconclusive` — a wrong silence verdict hides recoverable audio, which is exactly the failure this probe was added to prevent.
- `RealtimeAGC` is the default meeting-mic cleanup path for attenuated shared-device input. It avoids the playback-ducking side effects of Apple voice processing while still boosting quiet WebRTC-contended captures and gating idle USB-mic noise. App hosts can disable it for raw/off meeting mic capture when the user has tuned hardware gain.
- `MeetingRecordingJournalStore` persists in-progress recording journals for launch recovery. Journal mutations are scoped to the session token returned by `begin(...)` so late stop-path writes cannot corrupt a newer recording's journal.
- Audio-only output does not by itself prove the narrower permission works: `SCKAudioCapture` still enumerates shareable screen content. The standalone experiment under `experiments/audio-only-probe` records the live Core Audio permission proof and its limitations.
- `SCKAudioCapture` owns one bounded mid-recording restart for a stopped stream or missing-buffer watchdog failure. It publishes `reconnecting` before that attempt and terminal `failed` only when recovery is unavailable or fails; do not trigger restarts from amplitude silence alone. Recovery carries a lock-owned epoch token through cleanup, prepare, and start. Stream identity, generation, and the prepared/starting/capturing/stopping phase share that ownership lock so public `stop`/`stopSync` either win before a start request or own the exact requested stream until its stop callback, including after a timeout.
- `AudioPipelineDiagnosticsSnapshot` is the privacy-safe route and buffer-health summary used for analytics and Sentry context. Keep it limited to bucketed device classes, rates, channel counts, and recovery state, never raw device names, transcript text, titles, file paths, or audio.
- Hosts embedding `TranscriptedCore` should keep app-specific permission UX outside this directory, but they should understand that system-audio capture backend behavior now depends on OS availability.
- Imported meeting audio is funneled through the same pipeline primitives as live captures so transcript formatting, stats, speaker naming, and retry behavior stay aligned.

## Threading model

- `Audio` and several `Audio/*` helpers are **not** `@MainActor`. They run on audio or background threads.
- `TranscriptionTaskManager`, `Transcription`, and many service surfaces are `@MainActor ObservableObject`.
- Heavy pipeline work is pushed off the main actor through `nonisolated` async helpers in the pipeline runner.
- Any callback that handles live audio buffers must stay real-time safe.
- PCM write admission uses lock-free atomics on capture callbacks. Host fan-out and file writes use separate bounded queues, so a slow disk cannot delay borrowed-mic dictation. Stop drains both admitted tails before the app clears the host consumer, and detaches exact-generation writers only from their serial queue barriers. The mic tap keeps delivering until its background teardown, so `stop()` holds mic admission in `finishing` from before the generation advances until `closeMicrophone`; `MicStopTailHandoffTests` pins that order.

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
- `Tests/TranscriptedCoreTests/AudioTests/FailedRecordingSignalProbeTests.swift`
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
- `Tests/TranscriptedCoreTests/SpeakerTests/SpeakerNameSaveReliabilityTests.swift`
- `Tests/TranscriptedCoreTests/SpeakerTests/SpeakerNamingSimulationRunnerTests.swift`
- `Tests/SpeakerPeopleReviewPolicyTests.swift`
- `Tests/TranscriptedCoreTests/SpeakerTests/SpeakerProfileMergerTests.swift`
- `Tests/TranscriptedCoreTests/SpeakerTests/SpeakerProfileProvenanceTests.swift`
- `Tests/TranscriptedCoreTests/SpeakerTests/SpeakerProvenanceTests.swift`
- `Tests/TranscriptedCoreTests/StorageTests/StatsDatabaseTests.swift`
- `Tests/TranscriptedCoreTests/StorageTests/StatsDatabaseQueriesTests.swift`
- `Tests/TranscriptedCoreTests/StorageTests/StatsDatabaseModelsTests.swift`
- `Tests/TranscriptedCoreTests/StorageTests/RecordingMetadataFactoryTests.swift`
- `Tests/TranscriptedCoreTests/UtilitiesTests/LogPrivacySanitizerTests.swift`
- `Tests/TranscriptedCoreTests/StorageTests/TranscriptFormatVersionTests.swift`
- `Tests/TranscriptedCoreTests/StorageTests/TranscriptFrontmatterTests.swift`
- `Tests/TranscriptedCoreTests/AudioTests/TranscriptMetadataBuilderTests.swift`
- `Tests/TranscriptedCoreTests/PipelineTests/TranscriptionPipelineHelpersTests.swift`
- `Tests/TranscriptedCoreTests/PipelineTests/TranscriptionAudioFileTests.swift`
- `Tests/TranscriptedCoreTests/PipelineTests/TranscriptionTaskManagerMetadataTests.swift`
- `Tests/Integration/AppCoreIntegrationSmoke.swift`

Core coverage spans the package seam, audio initialization, speaker reconciliation, transcript metadata, stats, storage-path behavior, file-permission enforcement, failed-transcription persistence, file logging, recording archiving, and task-manager metadata.
