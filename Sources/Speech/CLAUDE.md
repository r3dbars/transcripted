# Speech Directory

## What This Does

`Sources/Speech/` owns the app's live dictation speech path.

## Key Files

- `ParakeetEngine.swift` — app-owned Parakeet STT engine, recording control,
  live transcript state, model initialization, and audio-device handling
- `STTRouter.swift` — small main-actor wrapper used by the rest of the app

## Current Notes

- This directory powers dictation
- The meeting pipeline reuses the same app-owned `ParakeetEngine` through
  `Sources/Meeting/MeetingSTTAdapter.swift`
- Do not assume a separate local-LLM drafting path exists in this tree

## Verification

After changing speech code:

```bash
bash build.sh
bash run-tests.sh
```

Manual checks:

- dictation can start and stop cleanly
- live transcript updates while listening
- device changes do not leave the app stuck
