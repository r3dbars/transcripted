# Speech Directory

## What This Does

`Sources/Speech/` owns the app's live dictation speech path.

## Key Files

- `ParakeetEngine.swift` — app-owned Parakeet STT engine, recording control, live transcript state, model initialization, permission-aware prewarm decisions, audio-device handling, short-audio gating, wake-recovery support, and sanitized failure reporting for model init errors
- `ParakeetModelInitDiagnostics.swift` — builds safe diagnostic context for model-initialization failures without leaking transcript or user-content data
- `ParakeetPrewarmPolicy.swift` — central policy for deciding whether speech-engine prewarm should proceed or be skipped based on microphone authorization state
- `ParakeetRecoveryState.swift` — pure-logic state machine for device-change recovery: generation counter (so stale recovery tasks can bail) and readiness flags (`isRecovering`, `inputFormatReady`) that the dictation overlay waits on instead of racing
- `ParakeetShortAudioGate.swift` — central policy for deciding when very short recordings should be dropped, surfaced as intentional empty results, or still transcribed
- `RecordedAudioTimeline.swift` — in-memory segmented audio buffer used when recorded audio needs to be preserved across interruptions or recovery handoffs
- `STTRouter.swift` — small main-actor wrapper used by the rest of the app

## Current Notes

- This directory powers dictation.
- `ParakeetEngine` consults `ParakeetPrewarmPolicy` before prewarming the local model, so microphone-permission-aware warmup behavior belongs here rather than in app startup glue.
- `ParakeetEngine` consults `ParakeetShortAudioGate` before spending work on extremely short clips, so short-tap behavior changes belong here rather than in UI controllers.
- `ParakeetEngine` mirrors `ParakeetRecoveryState` flags into `@Published var isRecovering` and `@Published var inputFormatReady` (forwarded through `STTRouter`). `DictationSessionController` waits on these in its wait-for-ready loop instead of blindly retrying. AirPods Hands-Free Profile (24kHz hw / 48kHz output bus) is supported: the tap is installed with `format: nil` so buffers arrive at the output rate, and `nativeSampleRate` tracks the output rate so downstream resampling is correct.
- `ParakeetEngine` reports model-init failures with `ParakeetModelInitDiagnostics.failureContext(...)`, which keeps diagnostics useful for packaging/download/debugging issues without shipping raw transcript or device content.
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

- `Tests/ParakeetModelInitDiagnosticsTests.swift`
- `Tests/ParakeetPrewarmPolicyTests.swift`
- `Tests/ParakeetRecoveryStateTests.swift`
- `Tests/ParakeetShortAudioGateTests.swift`
- `Tests/RecordedAudioTimelineTests.swift`
