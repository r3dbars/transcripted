# Meeting bridge

## What this directory does

`Sources/Meeting/` is the app-side adapter layer for the meeting feature. It keeps app-specific UI, storage, and `ParakeetEngine` ownership outside `TranscriptedCore` while reusing the core transcription pipeline.

## Files

- `FailedMeetingPresentation.swift` — maps `FailedTranscription` into `FailedMeetingItem` view-models with human-readable titles and retry metadata
- `MeetingCaptureBridge.swift` — `@MainActor` wrapper around core `Audio`, converts callback-based stop into `async`
- `MeetingModelDownloader.swift` — loads Parakeet and diarization models together
- `MeetingPromptDetector.swift` — polls upcoming Calendar events, watches supported meeting apps, and asks the overlay to offer one-tap recording prompts
- `MeetingPromptHeuristics.swift` — shared scoring and snooze rules for calendar- and runtime-based prompt candidates
- `MeetingSTTAdapter.swift` — adapts the app's shared `ParakeetEngine` to `TranscriptedCore.SpeechToTextEngine`
- `MeetingSessionController.swift` — top-level meeting state machine, model warmup, capture start/stop, queued transcription handoff, failed-meeting actions, and transcript restyling
- `MeetingStoragePaths.swift` — current split meeting storage layout across the capture library, app state, logs, and temp folders
- `MeetingTranscriptStyler.swift` — restyles saved transcripts and renames files after save
- `TranscriptSaver+AppSpeakerMaintenance.swift` — app-side `TranscriptSaver` extension for settings-driven speaker rename and merge flows that refresh the agent index after `TranscriptedCore` rewrites transcript speaker names

## End-to-end flow

1. `Sources/TranscriptedApp.swift` wires `MeetingSessionController` into `MeetingOverlayController`, the menubar, the `⌥M` hotkey, and the detected-meeting prompt flow.
2. `MeetingPromptDetector` polls upcoming Calendar events, observes supported runtime apps, scores candidate prompts, and asks `MeetingOverlayController` to present a short-lived prompt when the app is idle.
3. `Sources/TranscriptedAppState.swift` starts background model warmup through `meetingSession.prepareModels(showLoadingUI: false)`.
4. `MeetingSessionController.startRecording(...)` uses `MeetingCaptureBridge` to start core audio capture into app-owned scratch paths.
5. `MeetingSessionController.stopRecording(...)` awaits mic/system audio files from the bridge, then either starts transcription immediately or queues it behind the active job.
6. `TranscriptionTaskManager` runs one diarize → transcribe → save pipeline at a time.
7. A subscription on `taskManager.$lastSavedTranscriptURL` calls `MeetingTranscriptStyler.restyleTranscript(...)` and updates the recent-meetings UI state.
8. Failed meetings can be retried, deleted, or dismissed from the menubar recent-meetings section.

## Key invariants

- `TranscriptedCore` owns the reusable pipeline. App code in this directory should prefer adapters and protocol seams over direct core edits.
- `MeetingSTTAdapter.cleanup()` is intentionally a no-op. `TranscriptedAppState` owns `ParakeetEngine` lifecycle for the whole app.
- Meeting captures should follow the current capture library, while databases, logs, and temp recordings stay under the app-owned Transcripted Application Support folders.
- `MeetingPromptDetector` can prompt from either upcoming calendar events or recently active supported meeting apps (Zoom, Teams, Webex, FaceTime, plus browser-hosted providers like Google Meet).
- `TranscriptionTaskManager` stays single-flight. App-level queueing belongs in `MeetingSessionController`, not in ad hoc background tasks.
- Live PCM handlers installed through `MeetingCaptureBridge` run on capture threads. Keep them real-time safe.

## Storage

Meeting capture artifacts live under `<capture-library>/meetings/`:

- `*.md`
- `*.json`
- `transcripted.json`

App-owned meeting state lives under `~/Library/Application Support/Transcripted/state/`:

- `speakers.sqlite`
- `stats.sqlite`
- `failed_transcriptions.json`

Temporary meeting scratch paths live under `~/Library/Application Support/Transcripted/tmp/recordings/`:

- raw audio captures
- `speaker_clips/`

Core logging for the embedded meeting pipeline is redirected to `~/Library/Application Support/Transcripted/logs/`.

See `docs/storage-paths.md` for the full map.

## Test and verification

- `bash build.sh`
- `bash run-tests.sh`
- `bash run-integration-smoke.sh`

Relevant direct coverage:

- `Tests/MeetingPromptHeuristicsTests.swift`
- `Tests/MeetingTranscriptStylerTests.swift`
- `Tests/SpeakerNamingPolicyTests.swift`
- `Tests/Integration/AppCoreIntegrationSmoke.swift`

## Agent notes

- `MeetingSessionController` is the right place for app-level meeting behavior. If a change belongs to the reusable library, move down into `Sources/TranscriptedCore/`.
- The menubar's recent-meetings UI is part of the meeting feature surface. Meeting changes often require checking `Sources/UI/MenuBarRecentMeetingsView.swift` and `Sources/UI/MeetingOverlayController.swift`.
