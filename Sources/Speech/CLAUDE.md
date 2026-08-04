# Speech Directory

## What This Does

`Sources/Speech/` owns the app's live dictation speech path.

## Key Files

- `ParakeetEngine.swift` — app-owned Parakeet STT engine, recording control, final dictation transcription, permission-aware input-readiness checks, short-audio gating, live level metering, and sanitized failure reporting for model init errors. Device-change recovery and model load/download/warmup/teardown are split into the two files below — ParakeetEngine remains the public-API owner and `@MainActor` home for that state; the split files are internal collaborator extensions.
- `ParakeetDeviceRecovery.swift` — `ParakeetEngine` extension: device-change detection (CoreAudio default-input listener, `AVAudioEngineConfigurationChange` observer) and the `attemptDeviceRecovery` / `scheduleConfigRecoveryTimeout` executor that rewarms the audio graph after a route change. The pure decision tables it consults (`ParakeetDeviceRecoveryReadinessPolicy`, `ParakeetDeviceRecoveryFailurePolicy`, `ParakeetDeviceRecoveryTimeoutPolicy`) live in `ParakeetStartRecordingFailurePolicy.swift`, not here.
- `ParakeetModelLifecycle.swift` — `ParakeetEngine` extension: model load/download/warmup/teardown paths (`initialize`, `performInitialize`, `prefetchModelFilesIfNeeded`, `cancelModelWork`, `teardownModel`)
- `ParakeetAudioDeviceLookup.swift` — CoreAudio default-input lookup and dictation input selection descriptors used before Parakeet starts recording
- `ParakeetAudioEngineSupport.swift` — support types for Parakeet engine startup snapshots, retired-engine retention, and default-input listener teardown
- `WhisperEngine.swift` — app-owned WhisperKit STT engine used when advanced users select a Whisper model
- `NemotronEngine.swift` — app-owned FluidAudio Nemotron streaming STT engine, beta-gated behind `SpeechModelBetaPreferences`; transcribes buffered samples only (recording stays in `ParakeetEngine`)
- `DictationAudioLevelMeter.swift` — normalizes live PCM buffers into a 0...1 level used by the dictation waveform UI
- `DictationAudioRecovery.swift` — analyzes recorded dictation audio for usable speech signal and extracts focused, gain-normalized retry segments when an initial transcription attempt returns empty
- `DictationInputDeviceSelectionPolicy.swift` — prefers a built-in mic over Bluetooth headset input for dictation when that avoids HFP-style playback downgrades
- `PersistentDictationInputController.swift` — owns the explicit faster-Bluetooth-dictation preference at runtime: keeps the preferred non-Bluetooth system input selected, follows device reconnects, and restores prior input ownership across clean or unclean exits
- `DictationReadinessWaitPolicy.swift` — tiny policy that decides whether dictation should keep waiting for recovery, refresh input readiness, or start recording immediately
- `DictationSession.swift` — `@MainActor` engine-facing dictation orchestrator extracted out of `DictationSessionController`: owns the recovery wait-loop state machine (`waitForEngineAndStart`, merging the former `.startRecoveryRecording`/`.startRecording` duplicate paths), the model-warmup wait loop (`waitForModelAndStart`), `startDictationAudioRecording`, and the small STTRouter-touching cleanup/cancel helpers. Talks to `STTRouter` directly and reports back through outcome enums and injected status closures instead of touching overlay types, so `DictationSessionController` stays the only place that turns those into panel presentation.
- `DictationSessionTypes.swift` — `DictationSession`'s class declaration plus its pure, `TranscriptedAppState`-free nested types (`State`, `WaitStatus`, `StartOutcome`, `StartPathDecision`, ...); split out so `run-tests.sh` can compile and fast-test them without pulling in `TranscriptedAppState`'s whole-app dependency graph, the same constraint that keeps `DictationSessionController` itself out of the fast-test source list
- `ParakeetModelInitDiagnostics.swift` — builds safe diagnostic context for model-initialization failures without leaking transcript or user-content data
- `ParakeetPrewarmPolicy.swift` — central policy for deciding whether speech-engine input-readiness checks should proceed or be skipped based on microphone authorization state
- `ParakeetRecoveryState.swift` — pure-logic state machine for device-change recovery: generation counter (so stale recovery tasks can bail) and readiness flags (`isRecovering`, `inputFormatReady`) that the dictation overlay waits on instead of racing
- `ParakeetShortAudioGate.swift` — central policy for deciding when very short recordings should be dropped, surfaced as intentional empty results, or still transcribed
- `ParakeetStartRecordingFailurePolicy.swift` — central recovery policy for invalid-format and audio-engine-start failures during recording startup
- `RecordedAudioTimeline.swift` — in-memory segmented audio buffer used when recorded audio needs to be preserved across interruptions or recovery handoffs
- `TranscriptionModelWarmupOwnership.swift` — balanced, generation-safe ownership state for disposable background model warmup versus active dictation/meeting/import use; shared runtimes resolve concurrent foreground work onto one concrete model
- `STTRouter.swift` — small main-actor wrapper used by the rest of the app

## Current Notes

- This directory powers dictation.
- `ParakeetEngine` consults `ParakeetPrewarmPolicy` before checking microphone input readiness. Idle readiness checks must not leave `AVAudioEngine` running, because that keeps the macOS microphone indicator active.
- `ParakeetEngine` consults `ParakeetShortAudioGate` before spending work on extremely short clips, so short-tap behavior changes belong here rather than in UI controllers.
- `ParakeetEngine` mirrors `ParakeetRecoveryState` flags into `@Published var isRecovering` and `@Published var inputFormatReady` (forwarded through `STTRouter`). `DictationSessionController` uses `DictationReadinessWaitPolicy` in its wait-for-ready loop so it can distinguish between "still recovering", "refresh input readiness", and "safe to start" instead of blindly retrying. AirPods Hands-Free Profile (24kHz hw / 48kHz output bus) is supported: the tap is installed with `format: nil` so buffers arrive at the output rate, and `nativeSampleRate` tracks the output rate so downstream resampling is correct.
- `ParakeetEngine` consults `DictationInputDeviceSelectionPolicy` through `ParakeetAudioDeviceLookup` before recording so Bluetooth headset input does not unnecessarily hijack playback when a built-in mic fallback is available.
- `ParakeetEngine` consults `ParakeetStartRecordingFailurePolicy` when startup fails so format-reset, engine rebuild, and prewarm-retry behavior stay consistent across direct starts and recovery attempts.
- Route-change analytics are committed only after the config-change debounce resolves to a new categorical route. Notification churn and A -> B -> A oscillation stay quiet, but the underlying device-recovery state machine still runs.
- Zombie-engine recovery owns a separate generation-gated task, replaces the stale `AVAudioEngine` through a timed reset, and retries once. Do not fold that task back into the startup watchdog or reuse the detected zombie graph.
- `ParakeetEngine` stays `@MainActor` for app state, published UI state, and event reporting, but all `AVAudioEngine` graph work runs through its private serial audio-engine queue. Keep recording start/stop/readiness APIs async so callers do not block the main actor while CoreAudio settles, starts, stops, or rebuilds.
- `ParakeetEngine` reports model-init failures with `ParakeetModelInitDiagnostics.failureContext(...)`, which keeps diagnostics useful for packaging/download/debugging issues without shipping raw transcript or device content.
- `scripts/ops/dictation-stop-autoeval.sh --encoder-compute cpu-and-gpu|all` is the local-only encoder compute comparison. Production keeps FluidAudio's default unless that benchmark process sets `TRANSCRIPTED_PARAKEET_ENCODER_COMPUTE_UNITS`.
- Dictation intentionally exposes only final transcription. The abandoned provisional-text/EOU path was removed rather than kept behind a false feature flag. A future live dictation experience must add a real streaming engine and end-to-end tests instead of reviving dormant audio-tap branches.
- `DictationAudioLevelMeter` converts live audio buffers into normalized meter levels using `TranscriptedConstants` floor and ceiling thresholds. Keep waveform calibration changes here instead of burying them in overlay code.
- `DictationAudioRecovery` analyzes buffered audio for usable speech signal (peak, RMS, active ratio) and can produce a focused, gain-normalized retry segment. `ParakeetEngine` uses it to retry transcription when an initial attempt returns empty rather than silently dropping audio that contained real speech.
- The meeting pipeline reuses the same app-owned `STTRouter` through `Sources/Meeting/MeetingSTTAdapter.swift`.
- Do not assume a separate local-LLM drafting path exists in this tree.

## Verification

After changing speech code:

```bash
bash build.sh --no-open
bash run-tests.sh
```

Manual checks:

- dictation can start and stop cleanly
- very short recordings follow the expected drop / empty-result / transcribe behavior
- final dictation text appears after stop/transcribe; provisional live text is not shown
- device changes do not leave the app stuck or force a Bluetooth headset mic when a safer built-in fallback exists
- wake / resume does not strand buffered audio or leave recovery state hanging

Relevant direct coverage:

- `Tests/DictationAudioLevelMeterTests.swift`
- `Tests/DictationAudioRecoveryTests.swift`
- `Tests/DictationInputDeviceSelectionPolicyTests.swift`
- `Tests/DictationReadinessWaitPolicyTests.swift`
- `Tests/DictationSessionStateTests.swift`
- `Tests/BluetoothRouteContractTests.swift`
- `Tests/ParakeetModelInitDiagnosticsTests.swift`
- `Tests/ParakeetPrewarmPolicyTests.swift`
- `Tests/ParakeetRecoveryStateTests.swift`
- `Tests/ParakeetShortAudioGateTests.swift`
- `Tests/ParakeetStartRecordingFailurePolicyTests.swift`
- `Tests/DeviceRecoveryPolicyTests.swift`
- `Tests/RecordedAudioTimelineTests.swift`
- `Tests/TranscriptionModelWarmupOwnershipTests.swift`
