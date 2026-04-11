# Meeting Bridge

## What this directory owns

`Sources/Meeting/` is the app-side adapter layer for meeting capture. It keeps
app-specific UI, storage, model warmup, and transcript presentation outside
`TranscriptedCore` while reusing the core pipeline.

## Important files

- `MeetingSessionController.swift` — top-level meeting state machine, model warmup, capture start/stop, single-flight transcription queueing, failed-meeting actions, and transcript restyling hooks
- `MeetingCaptureBridge.swift` — `@MainActor` wrapper around core audio capture, converts callback stop APIs into `async`
- `MeetingPromptDetector.swift` — Calendar-driven supported-link detection used to offer one-tap meeting prompts
- `MeetingModelDownloader.swift` — coordinated warmup for Parakeet and diarization models
- `MeetingSTTAdapter.swift` — adapts the app’s shared `ParakeetEngine` to `TranscriptedCore.SpeechToTextEngine`
- `MeetingStoragePaths.swift` — splits user-facing captures from app-owned state, logs, and tmp scratch
- `MeetingTranscriptStyler.swift` — restyles saved transcripts and final filenames after save
- `FailedMeetingPresentation.swift` — maps `FailedTranscription` into UI-facing retry / delete rows

## End-to-end flow

1. `TranscriptedApp.swift` wires `MeetingSessionController` into the meeting overlay, menu bar, hotkey routing, and detected-meeting prompts.
2. `TranscriptedAppState.swift` starts background model warmup with `prepareModels(showLoadingUI: false)`.
3. `MeetingSessionController.startRecording(...)` uses `MeetingCaptureBridge` to begin capture.
4. `stopRecording(...)` awaits mic/system files, then starts transcription immediately or queues it behind the active job.
5. `TranscriptionTaskManager` runs one diarize → transcribe → save pipeline at a time.
6. When a transcript lands, `MeetingTranscriptStyler` restyles the saved file and the recent-meetings UI updates.

## Storage split

User-facing meeting captures live in the selected capture library:

- default: `~/Library/Application Support/Transcripted/captures/meetings/`

App-owned state stays under the Transcripted Application Support root:

- speaker DB: `~/Library/Application Support/Transcripted/state/speakers.sqlite`
- stats DB: `~/Library/Application Support/Transcripted/state/stats.sqlite`
- failed queue: `~/Library/Application Support/Transcripted/state/failed_transcriptions.json`
- logs: `~/Library/Application Support/Transcripted/logs/`
- speaker clips scratch: `~/Library/Application Support/Transcripted/tmp/recordings/speaker_clips/`
- recording scratch: `~/Library/Application Support/Transcripted/tmp/recordings/`

## Key invariants

- keep `TranscriptedCore` reusable; prefer adapters and protocol seams over app-specific edits in core
- `MeetingSTTAdapter.cleanup()` stays a no-op because `TranscriptedAppState` owns the shared `ParakeetEngine`
- meeting queueing stays single-flight through `TranscriptionTaskManager`
- live PCM handlers installed through `MeetingCaptureBridge` must remain real-time safe
- the recent-meetings menu bar UI is part of the meeting feature surface, not a separate concern

## Verify

```bash
bash build.sh
bash run-tests.sh
bash run-integration-smoke.sh
```

Relevant coverage:

- `Tests/MeetingTranscriptStylerTests.swift`
- `Tests/SpeakerNamingPolicyTests.swift`
- `SmokeTests/CoreIntegrationSmoke.swift`
