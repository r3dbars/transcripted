# Meeting bridge

## What this directory does

`Sources/Meeting/` is the app-side adapter layer for the meeting feature. It keeps app-specific UI, storage, and `ParakeetEngine` ownership outside `TranscriptedCore` while reusing the core transcription pipeline.

## Files

- `FailedMeetingPresentation.swift` — maps `FailedTranscription` into `FailedMeetingItem` view-models with human-readable titles and retry metadata
- `MeetingCaptureBridge.swift` — `@MainActor` wrapper around core `Audio`, converts callback-based stop into `async`
- `MeetingModelDownloader.swift` — loads Parakeet and diarization models together
- `MeetingSTTAdapter.swift` — adapts Draft's `ParakeetEngine` to `TranscriptedCore.SpeechToTextEngine`
- `MeetingSessionController.swift` — top-level meeting state machine, model warmup, capture start/stop, failed-meeting actions, transcript restyling
- `MeetingStoragePaths.swift` — current meeting storage layout under the Draft-named compatibility root
- `MeetingTranscriptStyler.swift` — restyles saved transcripts and renames files after save

## End-to-end flow

1. `Sources/TranscriptedApp.swift` wires `MeetingSessionController` into `MeetingOverlayController`, the menubar, and the `⌥M` hotkey.
2. `Sources/TranscriptedAppState.swift` starts background model warmup through `meetingSession.prepareModels(showLoadingUI: false)`.
3. `MeetingSessionController.startRecording(...)` uses `MeetingCaptureBridge` to start core audio capture into app-owned scratch paths.
4. `MeetingSessionController.stopRecording(...)` awaits mic/system audio files from the bridge.
5. `TranscriptionTaskManager.startTranscription(...)` runs the core diarize → transcribe → save pipeline.
6. A subscription on `taskManager.$lastSavedTranscriptURL` calls `MeetingTranscriptStyler.restyleTranscript(...)` and updates the "recent meetings" UI state.
7. Failed meetings can be retried, deleted, or dismissed from the menubar recent-meetings section.

## Key invariants

- `TranscriptedCore` owns the reusable pipeline. App code in this directory should prefer adapters and protocol seams over direct core edits.
- `MeetingSTTAdapter.cleanup()` is intentionally a no-op. `TranscriptedAppState` owns `ParakeetEngine` lifecycle for the whole app.
- Meeting storage must stay under the current Draft-named app-support paths, not `TranscriptedCore.default` standalone paths.
- Live PCM handlers installed through `MeetingCaptureBridge` run on capture threads. Keep them real-time safe.

## Storage

Meeting artifacts live under `~/Library/Application Support/Draft/meetings/`:

- `transcripts/`
- `speakers.sqlite`
- `stats.sqlite`
- `failed_transcriptions.json`
- `speaker_clips/`
- `recordings/`

Core logging for the embedded meeting pipeline is redirected to `~/Library/Application Support/Draft/logs/`.

See `docs/storage-paths.md` for the full map.

## Test and verification

- `bash build.sh`
- `bash run-tests.sh`
- `bash run-integration-smoke.sh`

Relevant direct coverage:

- `Tests/MeetingTranscriptStylerTests.swift`
- `Tests/SpeakerNamingPolicyTests.swift`
- `SmokeTests/CoreIntegrationSmoke.swift`

## Agent notes

- `MeetingSessionController` is the right place for app-level meeting behavior. If a change belongs to the reusable library, move down into `Sources/TranscriptedCore/`.
- The menubar's recent-meetings UI is part of the meeting feature surface. Meeting changes often require checking `Sources/UI/MenuBarRecentMeetingsView.swift` and `Sources/UI/MeetingOverlayController.swift`.
