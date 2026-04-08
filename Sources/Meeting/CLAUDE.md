# Meeting Directory

## What This Does

`Sources/Meeting/` is the app-side bridge between Transcripted's current macOS
UI and the reusable `TranscriptedCore` library.

## Key Files

- `MeetingSessionController.swift` — main app-facing meeting subsystem; owns
  the core DI container, task manager, model warmup, failed-meeting list, and
  published UI state
- `MeetingCaptureBridge.swift` — wraps `TranscriptedCore.Audio` for main-actor
  UI consumption and turns the completion callback into an async await point
- `MeetingSTTAdapter.swift` — adapts app-owned `ParakeetEngine` to
  `TranscriptedCore.SpeechToTextEngine`
- `MeetingModelDownloader.swift` — coordinates Parakeet + diarization model
  readiness
- `MeetingStoragePaths.swift` — isolates meeting data under
  `~/Library/Application Support/Draft/meetings/`
- `MeetingTranscriptStyler.swift` — rewrites saved transcript presentation and
  renames artifacts when needed

## Architecture

`MeetingSessionController` builds a Draft-flavored `CoreStoragePaths`, then
constructs:

1. `MeetingCaptureBridge`
2. `MeetingSTTAdapter`
3. `DiarizationService`
4. `SpeakerDatabase`
5. `FailedTranscriptionManager`
6. `AppServices`
7. `TranscriptionTaskManager`
8. `MeetingModelDownloader`

That keeps app-specific wiring, storage choices, and UI-facing state in
`Sources/Meeting/` while the transcription pipeline itself stays in
`Sources/TranscriptedCore/`.

## Guardrails

- Keep Draft/UI types out of `TranscriptedCore`
- Keep app-specific storage policy in `MeetingStoragePaths`, not inside core
- Reuse the app's single `ParakeetEngine`; do not spin up a second STT engine

## Verification

After changing this directory:

```bash
bash build.sh
bash run-tests.sh
bash run-integration-smoke.sh
```
