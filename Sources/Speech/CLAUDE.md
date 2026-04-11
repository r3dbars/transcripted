# Speech

## What this directory owns

`Sources/Speech/` owns the app’s live STT path and audio-device-facing dictation
recording logic.

## Important files

- `ParakeetEngine.swift` — app-owned Parakeet STT engine, recording control, live transcript state, model initialization, and audio-device handling
- `STTRouter.swift` — small main-actor wrapper used by the rest of the app
- `RecordedAudioTimeline.swift` — audio timing helpers shared by recording / transcript paths

## Notes

- dictation uses this directory directly
- meetings reuse the same app-owned `ParakeetEngine` through `Sources/Meeting/MeetingSTTAdapter.swift`
- wake handling and runtime recovery touch this layer indirectly through `TranscriptedAppState` and `Sources/Reliability/`

## Verify

```bash
bash build.sh
bash run-tests.sh
```

Manual checks:

- dictation starts and stops cleanly
- live transcript updates while listening
- audio-device changes and wake events do not leave the app stuck
