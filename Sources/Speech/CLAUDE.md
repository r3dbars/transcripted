# Speech Directory

## What This Does

`Sources/Speech/` owns the app's live dictation speech path.

## Key Files

- `ParakeetEngine.swift` — app-owned Parakeet STT engine, recording control, live transcript state, model initialization, permission-aware prewarm decisions, audio-device handling, short-audio gating, and wake-recovery support
- `ParakeetPrewarmPolicy.swift` — central policy for deciding whether speech-engine prewarm should proceed or be skipped based on microphone authorization state
- `ParakeetShortAudioGate.swift` — central policy for deciding when very short recordings should be dropped, surfaced as intentional empty results, or still transcribed
- `RecordedAudioTimeline.swift` — in-memory segmented audio buffer used when recorded audio needs to be preserved across interruptions or recovery handoffs
- `STTRouter.swift` — small main-actor wrapper used by the rest of the app

## Current Notes

- This directory powers dictation.
- `ParakeetEngine` consults `ParakeetPrewarmPolicy` before prewarming the local model, so microphone-permission-aware warmup behavior belongs here rather than in app startup glue.
- `ParakeetEngine` consults `ParakeetShortAudioGate` before spending work on extremely short clips, so short-tap behavior changes belong here rather than in UI controllers.
- The meeting pipeline reuses the same app-owned `ParakeetEngine` through `Sources/Meeting/MeetingSTTAdapter.swift`.
- Do not assume a separate local-LLM drafting path exists in this tree.

## Verification

After changing speech code:

```bash
bash build.sh
bash run-tests.sh
```

Manual checks:

- dictation can start and stop cleanly
- very short recordings follow the expected drop / empty-result / transcribe behavior
- live transcript updates while listening
- device changes do not leave the app stuck
- wake / resume does not strand buffered audio or leave recovery state hanging

Relevant direct coverage:

- `Tests/ParakeetPrewarmPolicyTests.swift`
- `Tests/ParakeetShortAudioGateTests.swift`
- `Tests/RecordedAudioTimelineTests.swift`
