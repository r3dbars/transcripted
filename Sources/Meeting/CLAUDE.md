# Meeting bridge

## What this directory does

`Sources/Meeting/` is the app-side adapter layer for the meeting feature. It keeps app-specific UI, storage, and selected STT ownership outside `TranscriptedCore` while reusing the core transcription pipeline.

## Files

- `FailedMeetingPresentation.swift` — maps `FailedTranscription` into `FailedMeetingItem` view-models with human-readable titles, retained-audio URLs, and retry metadata
- `MeetingAudioStorageManager.swift` — compresses retained meeting WAVs to M4A, compresses queue-tracked failed-meeting WAVs without deleting untracked orphans, applies audio-retention cleanup, and backfills existing retained audio after launch or Settings changes
- `MeetingAudioInactivityDetector.swift` — detects prolonged audio silence during meetings and emits warning/cleared events so the UI can prompt the user to confirm the recording is still needed
- `MeetingCaptureBridge.swift` — `@MainActor` wrapper around core `Audio` that converts start/stop into async flows, waits for both live capture and system-audio-file readiness, and mirrors live levels for the UI
- `MeetingCaptureBridge+LivePreview.swift` — bridge extension for recording health snapshots plus mic/system live-preview buffer forwarding
- `MeetingCaptureSupport.swift` — small support types for meeting capture stop results and pending async-attempt bookkeeping
- `MeetingFailureCopy.swift` — normalizes `MeetingFailureKind` values into user-facing titles and recovery copy
- `MeetingFailureExplanation.swift` — maps meeting outcomes into retryability, artifact-retention, user-visible state, and privacy-safe telemetry fields
- `MeetingFailureKind.swift` — canonical failure taxonomy that classifies raw meeting errors into stable machine-readable kinds
- `MeetingImportedAudioPreparer.swift` — copies imported recordings into app-managed scratch paths, derives titles, and prepares single-file meeting transcription jobs
- `LiveMeetingCodexSession.swift` — app-owned sidecar writer for the opt-in live-meeting workspace used by Codex and Claude Cowork; it must not replace or mutate the normal saved meeting transcript pipeline
- `LiveMeetingPreviewServer.swift` — loopback HTTP server that serves the live sidecar preview on a tokenized URL so the page updates in place without full-page refreshes while Transcripted is running
- `LiveMeetingStreamingUpdatePolicy.swift` — tiny throttling/deduplication policy for provisional live ASR updates before they are appended to the sidecar
- `LiveMeetingTranscriber.swift` — opt-in streaming ASR bridge that feeds mic/system live PCM copies into FluidAudio's local streaming Parakeet manager and appends provisional sidecar text, mirroring accepted updates into `LiveMeetingTranscriptFeed`
- `LiveMeetingTranscriptFeed.swift` — main-actor in-memory live transcript store behind the meeting overlay's embedded drawer; finals capped, newest partial per source replaces itself
- `LocalMeetingSummarizer.swift` — opt-in local meeting-summary runners (Gemma MLX and Apple Foundation Models), transcript chunking, provider metadata, runtime env sanitizing, and stale-transcript write protection; blocking model runs execute on a dedicated queue so they never occupy Swift-concurrency cooperative threads
- `MeetingMicBoostPromptPolicy.swift` — dependency-free gate for the in-meeting Boost Mic consent prompt and stale prompt actions
- `MeetingModelDownloader.swift` — loads the selected STT and diarization models together
- `MeetingPromptDetector.swift` — polls upcoming Calendar events, watches supported meeting apps, ingests mic-activity from `MicActivityMonitor`, and asks the overlay to offer recording prompts with provider-aware remind/dismiss backoff
- `MeetingPromptHeuristics.swift` — shared scoring, prompt reasons, browser-family + mic-input provider mapping, and provider-aware remind/dismiss backoff rules for calendar-, runtime-, and mic-activity-based prompt candidates
- `MicActivityMonitor.swift` — Core Audio process-object watcher for ad-hoc call detection. Emits the set of non-self bundle IDs currently holding the mic input so the detector can prompt when a call *starts* (including a spontaneous Google Meet with no calendar invite). Metadata-only, no TCC permission; CoreAudio confined to one serial queue. See `docs/auto-call-detection-spec.md`
- `MeetingRecordingCleanup.swift` — removes scratch audio when a live meeting recording is explicitly discarded instead of saved
- `MeetingRecordingStartGate.swift` — permission preflight for meeting recording, including missing-permission reasons and user-facing error messages
- `MeetingSTTAdapter.swift` — adapts the app's shared `STTRouter` to `TranscriptedCore.SpeechToTextEngine`
- `MeetingSessionController.swift` — top-level meeting state machine, permission gating, model warmup, capture start/stop, imported-audio handoff, queued transcription handoff, local-speaker-split handoff, failed-meeting actions, and transcript restyling
- `MeetingSessionUIPolicy.swift` — centralizes when queued or active transcription work should keep the meeting overlay in its transcribing/saving state
- `MeetingStartFailureClassifier.swift` — stable analytics classifier for meeting-recording start failures
- `MeetingStoragePaths.swift` — current split meeting storage layout across the capture library, app state, logs, and temp folders
- `MeetingSystemAudioStatusCopy.swift` — Foundation-pure system-audio status copy mapping for fast tests
- `MeetingSystemAudioStatusCopy+SystemAudioStatus.swift` — app-build bridge from `TranscriptedCore.SystemAudioStatus` into the copy mapping
- `MeetingTranscriptStyler.swift` — restyles saved transcripts and renames files after save
- `MeetingArtifactRenamer.swift` — shared rename mechanics for a saved meeting's Markdown, retained `audio/<stem>_audio/` directory, and `<stem>.summary.md` sidecar; builds the canonical `YYYY-MM-dd <title>` stem. Used by both the post-save restyle and the Home title-edit flow so naming and sidecar bookkeeping cannot drift
- `MeetingWarmupStatusPolicy.swift` — centralizes the user-facing warmup progress, copy, visibility, and ready/failure state for dictation + meeting model startup across overlay, menubar, and settings surfaces

## End-to-end flow

1. `Sources/TranscriptedApp.swift` wires `MeetingSessionController` into `MeetingOverlayController`, the menubar, the `⌥M` hotkey, and the detected-meeting prompt flow.
2. `MeetingPromptDetector` polls upcoming Calendar events, observes supported runtime apps, scores candidate prompts, and asks `MeetingOverlayController` to present a short-lived prompt when the app is idle.
3. Dismissed prompts feed back into `MeetingPromptDetector.snooze(...)`, which uses `MeetingPromptHeuristics` to choose shorter runtime reminders, calendar-aware resume windows, and longer Teams-specific suppression when appropriate.
4. `Sources/TranscriptedAppState.swift` warms dictation at launch; heavier meeting diarization stays lazy until meeting start or audio import.
5. `MeetingWarmupStatusPolicy` turns dictation + meeting warmup state into shared progress/copy consumed by the meeting overlay, menubar header, and settings home activity surfaces.
6. `MeetingSessionController.startRecording(...)` first runs `MeetingRecordingStartGate` so missing microphone or System Audio Recording permission failures are blocked before capture starts, then uses `MeetingCaptureBridge` to start core audio capture into app-owned scratch paths.
7. During recording, `MeetingAudioInactivityDetector` monitors mic and system audio levels and emits a warning event after sustained silence so the overlay can prompt the user to confirm the recording is still needed.
8. `MeetingSessionController.stopRecording(...)` awaits mic/system audio files from the bridge, then either starts transcription immediately or queues it behind the active job.
9. `MeetingSessionController.cancelRecording(...)` is only for explicit confirmed discard flows; it stops capture, removes scratch audio, and does not enqueue transcription.
10. `MeetingSessionController.importAudioFile(...)` routes standalone recordings through `MeetingImportedAudioPreparer` and into the same save / naming / restyling pipeline used by live captures.
11. `TranscriptionTaskManager` runs one diarize → transcribe → save pipeline at a time. When `LocalSpeakerPreferences` is enabled, queued meeting work also asks the core pipeline to diarize the local mic channel instead of treating it as a single "You" speaker.
12. A subscription on `taskManager.$lastSavedTranscriptURL` runs `MeetingTranscriptStyler.restyleTranscript(...)` on a serialized background task (the restyle reads/rewrites the whole transcript and can rename artifacts, so it must stay off the main actor) and hops back to the main actor to update the recent-meetings UI state. The restyle fails closed when a transcript body has text the entry parser cannot understand instead of replacing it with the empty placeholder.
13. After a transcript is saved, `MeetingAudioStorageManager` compresses retained WAV audio to M4A and applies the user's retention setting. Launch and Settings changes also run a backfill pass over existing Transcripted meeting transcripts, and queue-tracked failed-meeting audio can be compressed only after the failed queue is updated to point at the converted files.
14. If the speaker review sheet shows multiple local speakers, the user can either name them individually or collapse them back to a single "You" track via the UI's "Keep as You" path.
15. Failed meetings can be played, revealed, retried, deleted, or dismissed from Home, with `MeetingFailureKind` providing stable failure categories, `MeetingFailureExplanation` preserving retry/artifact state, and `MeetingFailureCopy` keeping error copy consistent across retryable and non-retryable states.

## Key invariants

- `TranscriptedCore` owns the reusable pipeline. App code in this directory should prefer adapters and protocol seams over direct core edits.
- `MeetingSTTAdapter.cleanup()` only clears the prepared meeting model. `TranscriptedAppState` owns STT engine lifecycle for the whole app.
- Meeting captures should follow the current capture library, while databases, logs, and temp recordings stay under the app-owned Transcripted Application Support folders.
- Imported meeting audio should be copied into app-controlled scratch space before transcription so later cleanup and metadata writes stay consistent with live captures.
- Background work that moves saved meeting artifacts — the restyle rename and the WAV→M4A recompression / retention pruning driven from `MeetingSessionController` — must signal `CaptureLibraryChangeBroadcaster` (`Sources/Support/`) so Home re-resolves the transcript/audio URLs it cached at scan time. The consumer side is `Sources/UI/Shared/HomeCaptureRefreshObserver.swift` and `OwnFileResolver.swift`.
- Retained-audio maintenance must only manage Transcripted meeting transcripts and app-owned retained audio filenames. A transcript is only storage-owned when its frontmatter has `capture_type: meeting` and a valid `capture_id` or `transcript_id`. Be very conservative with deletion: Markdown transcripts stay, unrelated files in capture folders stay, symlinked audio folders are ignored, and converted or pre-existing M4A files should be owner-only.
- Meeting recording cancellation must be explicit, visible, and confirmed because discard deletes the captured audio. Do not wire Escape to meeting cancellation.
- `MeetingPromptDetector` can prompt from upcoming calendar events, from recently active supported runtime apps, or from a process actively holding the mic input (ad-hoc call detection). Zoom and Teams should rely on stronger calendar evidence because app-open/frontmost state is not enough to prove a call is active.
- Ad-hoc call detection (`MicActivityMonitor` → `MeetingPromptDetector.updateMicInputUsers`) must never prompt while Transcripted itself holds the mic: it is gated by `isOwnCaptureActive` (meeting recording or dictation) and the monitor drops our own bundle ID by prefix. Browser calls map to `.googleMeet` via family-prefix matching because the mic is held by helper/service processes (`com.google.Chrome.helper`, `com.apple.WebKit.GPU`), and reuse the `.runtimeApp` source so existing snooze/dismiss/backoff is unchanged. The feature is behind `AutoCallDetectionPreferences` (default on).
- Prompt dismissals are provider- and source-aware: runtime-only prompts can remind sooner, calendar-linked prompts can stay suppressed until the next relevant window, and Teams gets a longer minimum dismiss interval.
- Local mic diarization is opt-in and controlled by `Sources/Support/LocalSpeakerPreferences.swift`, so default meeting behavior still keeps the mic side as a single "You" speaker unless the user enables review for people in the room.
- Live meeting sidecar mode is opt-in and sidecar-only. It can write provisional live files under app support during recording, but the durable meeting Markdown still comes from the existing `TranscriptionTaskManager` save pipeline. Keep live ASR isolated from final transcription work; if another transcript is already processing, prefer deferring live ASR over contending with the final pipeline.
- Live streaming ASR can only start with a recording: `MeetingCaptureBridge` live PCM preview handlers must be installed before capture starts and never reassigned mid-session. `connectLiveSidecarToActiveRecording()` is the only mid-recording entry point (used by the meeting overlay's Live View button) and deliberately starts the sidecar session without live ASR; the final transcript still attaches normally.
- `MeetingRecordingStartGate` is the canonical place for meeting-recording permission policy and reason strings. Keep duplicate permission branching out of overlay code.
- `MeetingMicBoostPromptPolicy` is the canonical place for the in-meeting Boost Mic consent prompt. It must not present or apply actions after recording stop/cancel/termination teardown begins.
- `MeetingFailureExplanation` owns the answer to "what happened, what was retained, and can the user retry?" Keep support summaries and telemetry aligned through its report fields instead of duplicating outcome logic.
- `MeetingFailureKind` is the canonical place for stable failed-meeting categories used by presentation and metadata. Keep new classification rules centralized there.
- `MeetingFailureCopy` is the canonical place for human-facing failed-meeting titles and details. Keep retry messaging centralized there.
- `MeetingSessionUIPolicy` is the canonical place for deciding whether background meeting work should still surface as an active transcribing/saving state. Speaker review alone should not keep that state visible.
- `TranscriptionTaskManager` stays single-flight. App-level queueing belongs in `MeetingSessionController`, not in ad hoc background tasks.
- Live PCM handlers installed through `MeetingCaptureBridge` run on capture threads. Keep them real-time safe.
- Local meeting summaries rewrite the saved transcript after a slow local model run. Always re-read the transcript before writing and fail closed if transcript text changed while generation was in flight. Keep provider-specific setup and metadata explicit so Gemma MLX and Apple Foundation Models summaries remain distinguishable.

## Storage

Meeting capture artifacts live under `<capture-library>/meetings/`:

- `*.md`
- `audio/*_audio/` retained mic/system audio copied from successful meeting captures
- retained audio is compressed from WAV to M4A after transcript save; retention cleanup uses Transcripted transcript frontmatter date, not Markdown edit time
- retained-audio backfill skips orphaned, non-Transcripted, and symlinked audio folders instead of guessing ownership; failed audio is only compressed when it is still referenced by the failed-meeting retry queue

App-owned meeting state lives under `~/Library/Application Support/Transcripted/state/`:

- `speakers.sqlite`
- `stats.sqlite`
- `failed_transcriptions.json`

Temporary meeting scratch paths live under `~/Library/Application Support/Transcripted/tmp/recordings/`:

- raw audio captures
- imported audio copies
- `speaker_clips/`

Successful live and imported meeting recordings are retained in the capture
library before scratch cleanup. Failed live meeting transcriptions also copy
their available recording audio there while keeping scratch files available for
retry. Explicit discard still removes the scratch recording without saving a
transcript or retained audio.

Core logging for the embedded meeting pipeline is redirected to `~/Library/Application Support/Transcripted/logs/`.

See `docs/storage-paths.md` for the full map.

## Test and verification

- `bash build-deps.sh --force`
- `bash build.sh --no-open`
- `bash run-tests.sh`
- `bash run-integration-smoke.sh`

Relevant direct coverage:

- `Tests/FailedMeetingPresentationTests.swift`
- `Tests/MeetingFailureExplanationTests.swift`
- `Tests/MeetingFailureKindTests.swift`
- `Tests/MeetingPromptHeuristicsTests.swift`
- `Tests/MicActivityMonitorTests.swift`
- `Tests/MeetingRecordingStartGateTests.swift`
- `Tests/MeetingStartFailureClassifierTests.swift`
- `Tests/MeetingMicBoostPromptPolicyTests.swift`
- `Tests/MeetingRecordingCleanupTests.swift`
- `Tests/MeetingWarmupStatusPolicyTests.swift`
- `Tests/MeetingAudioInactivityDetectorTests.swift`
- `Tests/MeetingPromptDetectorTests.swift`
- `Tests/MeetingSessionUIPolicyTests.swift`
- `Tests/MeetingAudioStorageManagerTests.swift`
- `Tests/MeetingTranscriptStylerTests.swift`
- `Tests/MeetingRouteFixtureTests.swift`
- `Tests/LiveMeetingCodexSessionTests.swift`
- `Tests/LiveMeetingPreviewServerTests.swift`
- `Tests/LiveMeetingStreamingUpdatePolicyTests.swift`
- `Tests/LiveMeetingTranscriptFeedTests.swift`
- `Tests/LocalMeetingSummarizerTests.swift`
- `Tests/SpeakerNamingPolicyTests.swift`
- `Tests/Integration/AppCoreIntegrationSmoke.swift`

## Agent notes

- `MeetingSessionController` is the right place for app-level meeting behavior. If a change belongs to the reusable library, move down into `Sources/TranscriptedCore/`.
- The menubar links recent meetings into Settings Home instead of rendering inline recent meetings. Meeting changes often require checking `Sources/UI/MenuBar/MenuBarPrimaryActionsView.swift`, `Sources/UI/Settings/TranscriptedSettingsView.swift`, and `Sources/UI/Overlay/MeetingOverlayController.swift`.
