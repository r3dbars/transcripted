# Speech Directory

## What This Does

`Sources/Speech/` owns the app's live dictation speech path.

## Key Files

- `ParakeetEngine.swift` — app-owned Parakeet STT engine, recording control, live transcript state, model initialization, permission-aware input-readiness checks, audio-device handling, short-audio gating, wake-recovery support, and sanitized failure reporting for model init errors
- `WhisperEngine.swift` — app-owned WhisperKit STT engine used when advanced users select a Whisper model
- `DictationAudioRecovery.swift` — analyzes recorded dictation audio for usable speech signal and extracts focused, gain-normalized retry segments when an initial transcription attempt returns empty
- `DictationInputDeviceSelectionPolicy.swift` — prefers a built-in mic over Bluetooth headset input for dictation when that avoids HFP-style playback downgrades
- `ParakeetModelInitDiagnostics.swift` — builds safe diagnostic context for model-initialization failures without leaking transcript or user-content data
- `ParakeetPrewarmPolicy.swift` — central policy for deciding whether speech-engine input-readiness checks should proceed or be skipped based on microphone authorization state
- `ParakeetRecoveryState.swift` — pure-logic state machine for device-change recovery: generation counter (so stale recovery tasks can bail) and readiness flags (`isRecovering`, `inputFormatReady`) that the dictation overlay waits on instead of racing
- `ParakeetShortAudioGate.swift` — central policy for deciding when very short recordings should be dropped, surfaced as intentional empty results, or still transcribed
- `ParakeetStartRecordingFailurePolicy.swift` — central recovery policy for invalid-format and audio-engine-start failures during recording startup
- `RecordedAudioTimeline.swift` — in-memory segmented audio buffer used when recorded audio needs to be preserved across interruptions or recovery handoffs
- `STTRouter.swift` — small main-actor wrapper used by the rest of the app

## Current Notes

- This directory powers dictation.
- `ParakeetEngine` consults `ParakeetPrewarmPolicy` before checking microphone input readiness. Idle readiness checks must not leave `AVAudioEngine` running, because that keeps the macOS microphone indicator active.
- `ParakeetEngine` consults `ParakeetShortAudioGate` before spending work on extremely short clips, so short-tap behavior changes belong here rather than in UI controllers.
- `ParakeetEngine` mirrors `ParakeetRecoveryState` flags into `@Published var isRecovering` and `@Published var inputFormatReady` (forwarded through `STTRouter`). `DictationSessionController` waits on these in its wait-for-ready loop instead of blindly retrying. AirPods Hands-Free Profile (24kHz hw / 48kHz output bus) is supported: the tap is installed with `format: nil` so buffers arrive at the output rate, and `nativeSampleRate` tracks the output rate so downstream resampling is correct.
- `ParakeetEngine` consults `DictationInputDeviceSelectionPolicy` before recording so Bluetooth headset input does not unnecessarily hijack playback when a built-in mic fallback is available.
- `ParakeetEngine` consults `ParakeetStartRecordingFailurePolicy` when startup fails so format-reset, engine rebuild, and prewarm-retry behavior stay consistent across direct starts and recovery attempts.
- `ParakeetEngine` stays `@MainActor` for app state, published UI state, and event reporting, but all `AVAudioEngine` graph work runs through its private serial audio-engine queue. Keep recording start/stop/readiness APIs async so callers do not block the main actor while CoreAudio settles, starts, stops, or rebuilds.
- `ParakeetEngine` reports model-init failures with `ParakeetModelInitDiagnostics.failureContext(...)`, which keeps diagnostics useful for packaging/download/debugging issues without shipping raw transcript or device content.
- `DictationAudioRecovery` analyzes buffered audio for usable speech signal (peak, RMS, active ratio) and can produce a focused, gain-normalized retry segment. `ParakeetEngine` uses it to retry transcription when an initial attempt returns empty rather than silently dropping audio that contained real speech.
- The meeting pipeline reuses the same app-owned `STTRouter` through `Sources/Meeting/MeetingSTTAdapter.swift`.
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
- device changes do not leave the app stuck or force a Bluetooth headset mic when a safer built-in fallback exists
- wake / resume does not strand buffered audio or leave recovery state hanging

Relevant direct coverage:

- `Tests/DictationAudioRecoveryTests.swift`
- `Tests/DictationInputDeviceSelectionPolicyTests.swift`
- `Tests/ParakeetModelInitDiagnosticsTests.swift`
- `Tests/ParakeetPrewarmPolicyTests.swift`
- `Tests/ParakeetRecoveryStateTests.swift`
- `Tests/ParakeetShortAudioGateTests.swift`
- `Tests/ParakeetStartRecordingFailurePolicyTests.swift`
- `Tests/RecordedAudioTimelineTests.swift`
