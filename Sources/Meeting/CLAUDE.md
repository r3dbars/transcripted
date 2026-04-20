# Meeting bridge

## What this directory does

`Sources/Meeting/` is the app-side adapter layer for the meeting feature. It keeps app-specific UI, storage, and `ParakeetEngine` ownership outside `TranscriptedCore` while reusing the core transcription pipeline.

## Files

- `FailedMeetingPresentation.swift` — maps `FailedTranscription` into `FailedMeetingItem` view-models with human-readable titles and retry metadata
- `MeetingCaptureBridge.swift` — `@MainActor` wrapper around core `Audio`, converts callback-based stop into `async`
- `MeetingFailureCopy.swift` — normalizes `MeetingFailureKind` values into user-facing titles and recovery copy
- `MeetingFailureKind.swift` — canonical failure taxonomy that classifies raw meeting errors into stable machine-readable kinds
- `MeetingImportedAudioPreparer.swift` — copies imported recordings into app-managed scratch paths, derives titles, and prepares single-file meeting transcription jobs
- `MeetingModelDownloader.swift` — loads Parakeet and diarization models together
- `MeetingPromptDetector.swift` — polls upcoming Calendar events, watches supported meeting apps, and asks the overlay to offer one-tap recording prompts
- `MeetingPromptHeuristics.swift` — shared scoring and snooze rules for calendar- and runtime-based prompt candidates
- `MeetingRecordingCleanup.swift` — removes scratch audio when a live meeting recording is explicitly discarded instead of saved
- `MeetingRecordingStartGate.swift` — permission preflight for meeting recording, including missing-permission reasons and user-facing error messages
- `MeetingSTTAdapter.swift` — adapts the app's shared `ParakeetEngine` to `TranscriptedCore.SpeechToTextEngine`
- `MeetingSessionController.swift` — top-level meeting state machine, permission gating, model warmup, capture start/stop, imported-audio handoff, queued transcription handoff, local-speaker-split handoff, failed-meeting actions, and transcript restyling
- `MeetingSessionUIPolicy.swift` — centralizes when queued or active transcription work should keep the meeting overlay in its transcribing/saving state
- `MeetingStoragePaths.swift` — current split meeting storage layout across the capture library, app state, logs, and temp folders
- `MeetingTranscriptStyler.swift` — restyles saved transcripts and renames files after save
- `MeetingWarmupStatusPolicy.swift` — centralizes the user-facing warmup progress, copy, and ready/failure state for dictation + meeting model startup across overlay, menubar, and settings surfaces

## End-to-end flow

1. `Sources/TranscriptedApp.swift` wires `MeetingSessionController` into `MeetingOverlayController`, the menubar, the `⌥M` hotkey, and the detected-meeting prompt flow.
2. `MeetingPromptDetector` polls upcoming Calendar events, observes supported runtime apps, scores candidate prompts, and asks `MeetingOverlayController` to present a short-lived prompt when the app is idle.
3. `Sources/TranscriptedAppState.swift` starts background model warmup through `meetingSession.prepareModels(showLoadingUI: false)`.
4. `MeetingWarmupStatusPolicy` turns dictation + meeting warmup state into shared progress/copy consumed by the meeting overlay, menubar header, and settings home activity surfaces.
5. `MeetingSessionController.startRecording(...)` first runs `MeetingRecordingStartGate` so missing microphone or System Audio Recording permission failures are blocked before capture starts, then uses `MeetingCaptureBridge` to start core audio capture into app-owned scratch paths.
6. `MeetingSessionController.stopRecording(...)` awaits mic/system audio files from the bridge, then either starts transcription immediately or queues it behind the active job.
7. `MeetingSessionController.cancelRecording(...)` is only for explicit confirmed discard flows; it stops capture, removes scratch audio, and does not enqueue transcription.
8. `MeetingSessionController.importAudioFile(...)` routes standalone recordings through `MeetingImportedAudioPreparer` and into the same save / naming / restyling pipeline used by live captures.
9. `TranscriptionTaskManager` runs one diarize → transcribe → save pipeline at a time. When `LocalSpeakerPreferences` is enabled, queued meeting work also asks the core pipeline to diarize the local mic channel instead of treating it as a single "You" speaker.
10. A subscription on `taskManager.$lastSavedTranscriptURL` calls `MeetingTranscriptStyler.restyleTranscript(...)` and updates the recent-meetings UI state.
11. If the speaker review sheet shows multiple local speakers, the user can either name them individually or collapse them back to a single "You" track via the UI's "Keep as You" path.
12. Failed meetings can be retried, deleted, or dismissed from the menubar recent-meetings section, with `MeetingFailureKind` providing stable failure categories and `MeetingFailureCopy` keeping error copy consistent across retryable and non-retryable states.

## Key invariants

- `TranscriptedCore` owns the reusable pipeline. App code in this directory should prefer adapters and protocol seams over direct core edits.
- `MeetingSTTAdapter.cleanup()` is intentionally a no-op. `TranscriptedAppState` owns `ParakeetEngine` lifecycle for the whole app.
- Meeting captures should follow the current capture library, while databases, logs, and temp recordings stay under the app-owned Transcripted Application Support folders.
- Imported meeting audio should be copied into app-controlled scratch space before transcription so later cleanup and metadata writes stay consistent with live captures.
- Meeting recording cancellation must be explicit, visible, and confirmed because discard deletes the captured audio. Do not wire Escape to meeting cancellation.
- `MeetingPromptDetector` can prompt from either upcoming calendar events or recently active supported meeting apps (Zoom, Teams, Webex, FaceTime, plus browser-hosted providers like Google Meet).
- Local mic diarization is opt-in and controlled by `Support/LocalSpeakerPreferences.swift`, so default meeting behavior still keeps the mic side as a single "You" speaker unless the user enables review for people in the room.
- `MeetingRecordingStartGate` is the canonical place for meeting-recording permission policy and reason strings. Keep duplicate permission branching out of overlay code.
- `MeetingFailureKind` is the canonical place for stable failed-meeting categories used by presentation and metadata. Keep new classification rules centralized there.
- `MeetingFailureCopy` is the canonical place for human-facing failed-meeting titles and details. Keep retry messaging centralized there.
- `MeetingSessionUIPolicy` is the canonical place for deciding whether background meeting work should still surface as an active transcribing/saving state. Speaker review alone should not keep that state visible.
- `TranscriptionTaskManager` stays single-flight. App-level queueing belongs in `MeetingSessionController`, not in ad hoc background tasks.
- Live PCM handlers installed through `MeetingCaptureBridge` run on capture threads. Keep them real-time safe.

## Storage

Meeting capture artifacts live under `<capture-library>/meetings/`:

- `*.md`

App-owned meeting state lives under `~/Library/Application Support/Transcripted/state/`:

- `speakers.sqlite`
- `stats.sqlite`
- `failed_transcriptions.json`

Temporary meeting scratch paths live under `~/Library/Application Support/Transcripted/tmp/recordings/`:

- raw audio captures
- imported audio copies
- `speaker_clips/`

Core logging for the embedded meeting pipeline is redirected to `~/Library/Application Support/Transcripted/logs/`.

See `docs/storage-paths.md` for the full map.

## Test and verification

- `bash build.sh`
- `bash run-tests.sh`
- `bash run-integration-smoke.sh`

Relevant direct coverage:

- `Tests/FailedMeetingPresentationTests.swift`
- `Tests/MeetingFailureKindTests.swift`
- `Tests/MeetingPromptHeuristicsTests.swift`
- `Tests/MeetingRecordingStartGateTests.swift`
- `Tests/MeetingSessionUIPolicyTests.swift`
- `Tests/MeetingTranscriptStylerTests.swift`
- `Tests/MeetingWarmupStatusPolicyTests.swift`
- `Tests/SpeakerNamingPolicyTests.swift`
- `Tests/Integration/AppCoreIntegrationSmoke.swift`

## Agent notes

- `MeetingSessionController` is the right place for app-level meeting behavior. If a change belongs to the reusable library, move down into `Sources/TranscriptedCore/`.
- The menubar's recent-meetings UI is part of the meeting feature surface. Meeting changes often require checking `Sources/UI/MenuBar/MenuBarRecentMeetingsView.swift` and `Sources/UI/Overlay/MeetingOverlayController.swift`.
