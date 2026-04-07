# Speech — Parakeet STT Engine

## What This Does

Audio recording and transcription via **ParakeetEngine** — a CoreML-based STT engine using FluidAudio's Parakeet TDT V3 for final accurate transcription and Parakeet EOU 120M for low-latency live display. `STTRouter` wraps ParakeetEngine with Combine property forwarding and model-readiness gating for SwiftUI binding.

## Key Files

- `ParakeetEngine.swift` — `@MainActor ObservableObject`: AVAudioEngine tap, NSLock-batched sample collection, EOU streaming live display via `StreamingEouAsrManager`, CoreML batch inference via FluidAudio `AsrManager`, audio level metering, device change handling, `ParakeetModelState` enum for download/load progress
- `STTRouter.swift` (54 lines) — Wrapper forwarding 5 `@Published` properties (`isRecording`, `isTranscribing`, `audioLevel`, `liveTranscript`, `recordingInterrupted`) from ParakeetEngine via Combine `assign(to:)`. Gates `startRecording()` on `isModelLoaded` and logs a warning via `EventReporter` if the model is not ready. Passes through `isModelLoaded` and `inputDeviceName` as computed properties. Also exposes `stopRecording()`, `transcribe()`, and `cancel()` as direct pass-throughs to ParakeetEngine.
- `AudioResampler.swift` (28 lines) — Pure Swift linear-interpolation sample rate conversion (native → 16kHz for Parakeet). No dependencies. Stateless `enum` with a single `resample(_:from:to:)` static method.

## Architecture

```
Audio Input (AVAudioEngine tap, mono at native sample rate)
    │
    ├─→ Consumer 1: Parakeet EOU streaming (live display — StreamingEouAsrManager)
    │   └─→ resample chunk → 16kHz → process(audioBuffer:) every ~320ms
    │   └─→ setEouCallback fires on silence → committedStreamText → liveTranscript
    │
    ├─→ Consumer 2: Parakeet TDT V3 sample buffer (NSLock-protected pendingSamples)
    │   └─→ Flushed into sampleBuffer on stopRecording() or transcribe()
    │   └─→ Resampled to 16kHz via AudioResampler
    │   └─→ Batch inference via AsrManager.transcribe()
    │   └─→ Returns final transcript text (replaces live display on completion)
    │
    └─→ Consumer 3: Audio level metering (~20Hz throttled)
        └─→ audioLevel (0.0–1.0) — drives waveform animation in overlay
```

## Critical Design Decisions

### NSLock for Audio Thread → MainActor Transfer

The audio render callback runs on a real-time thread with ~10ms deadlines. NSLock provides deterministic ~1μs overhead for the shared sample buffer between the audio thread and MainActor. Swift 6 warns about NSLock in async context — this is a false positive since the lock protects a buffer between threads, not between two async contexts.

### ParakeetModelState Enum

`ParakeetModelState` tracks model lifecycle: `.notLoaded` → `.downloading(progress:)` → `.loading` → `.ready` (or `.failed(String)`). The `.downloading` case carries a `Double` progress value for UI progress bars. Published as `modelDownloadState` on `ParakeetEngine`.

### Model Initialization

`ParakeetEngine.initialize()` loads CoreML models either from the app bundle (`Contents/Resources/parakeet-models/parakeet-tdt-0.6b-v3-coreml/`) or via HuggingFace download (~600MB). Bundle detection checks for the `Encoder.mlmodelc` file existence. The `modelDownloadState` published property drives a progress bar in settings. Model loading is async and non-blocking — the app starts immediately. Guarded by `asrManager == nil` to prevent double initialization.

### Audio Engine Pre-warming

`prewarm()` starts the audio engine on launch (guarded by `isEnginePrewarmed` flag). This forces macOS to initialize the audio graph and allocate Core Audio buffers upfront, reducing first-recording latency from ~300ms to near-zero. Also registers the `.AVAudioEngineConfigurationChange` observer for device changes (observer is installed once and stored in `configChangeObserver`).

### Device Change Handling

Observes `.AVAudioEngineConfigurationChange` notification to detect when audio devices change (e.g., USB mic plugged/unplugged). On change, the engine stops any active recording (removes tap, stops live speech), re-reads the native sample rate, and re-warms. If re-warm fails while recording was active, `recordingInterrupted` is set to `true` — DraftSessionController observes this and cancels the session with a user-visible error. If re-warm succeeds but was recording, attempts to restart recording automatically.

### inputDeviceName Computed Property

Uses CoreAudio `AudioObjectGetPropertyData` to read the default input device ID and its `kAudioDevicePropertyDeviceNameCFString`. Returns `"Unknown"` on any failure. Used in debug logging and EventReporter context for all recording/prewarm events.

### startRecording() Returns Bool

`startRecording()` returns `false` on failure (model not loaded, mic unauthorized, audio format creation failed, engine start failed). Pre-allocates sample buffer capacity for 120 seconds of audio at native sample rate. On engine start failure, the audio tap is explicitly removed to prevent a double-install ObjC exception on the next call. Callers (STTRouter, DraftSessionController) check the return value and show error UI.

### transcribe() Returns Optional String

`transcribe()` is an async method that performs batch Parakeet inference on accumulated audio. Guards: returns `nil` if already transcribing, if sample buffer is empty, or if `asrManager` is unavailable. Flushes any remaining `pendingSamples` into `sampleBuffer` under lock before inference. Resamples to 16kHz via `AudioResampler`, then calls `manager.transcribe(_:source:)`. Logs RTF (real-time factor = inference time / audio duration) and character count to `EventReporter`. On empty result, logs a warning and returns `nil`. Always clears `sampleBuffer` and resets `isTranscribing` on both success and failure paths.

### EOU Streaming Live Display

`StreamingEouAsrManager` (Parakeet EOU 120M) receives resampled 16kHz audio in ~320ms chunks from the audio tap. End-of-utterance detection fires after 1280ms of silence, committing the utterance to `committedStreamText` and updating `liveTranscript`. EOU model load is non-fatal — if it fails, `liveTranscript` stays empty during recording but the final TDT V3 batch result is unaffected. EOU model is ~120MB vs ~600MB for TDT V3.

### cancel() and cleanup()

`cancel()` stops recording (removes tap, stops live speech), clears all buffers and transcript state, and resets `isTranscribing` to `false`. Used when the user cancels a session mid-recording.

`cleanup()` cancels the init task, releases the `AsrManager`, and resets `modelDownloadState` to `.notLoaded`. Used during app shutdown to free CoreML resources.

### deinit Cleanup

```swift
deinit {
    if let observer = configChangeObserver {
        NotificationCenter.default.removeObserver(observer)   // Remove device change observer
    }
    audioEngine.inputNode.removeTap(onBus: 0)   // Release mic (green dot goes away)
    audioEngine.stop()
    asrManager?.cleanup()
}
```

Without the audio engine cleanup, the microphone green dot persists after the engine deallocates. The `configChangeObserver` removal prevents dangling notification callbacks.

## Critical Gotchas

### 1. Multi-Channel Audio Interfaces

Pro audio interfaces like BEACN Mic (96kHz/4ch) cause Apple Speech error 1110. Fix: force mono tap format at native sample rate — AVAudioEngine handles channel mixdown automatically. **Do NOT force 16kHz** — sample rate mismatch crashes with an ObjC exception.

### 2. EOU Debounce Delay

EOU fires after 1280ms of silence. For fast back-to-back phrases, the last phrase may not commit to `liveTranscript` until the user pauses. This is display-only — TDT V3 owns the final accurate transcript and captures everything.

### 3. Microphone Permission Can Be Revoked at Runtime

`startRecording()` checks `AVCaptureDevice.authorizationStatus(for: .audio)` before `installTap()`. Without this check, revoking mic permission while the app is open causes `installTap()` to throw an unrecoverable ObjC exception.

## Verification

After modifying ParakeetEngine, verify with these checks:

- **Basic recording:** ⌥D → speak → ⌥D → draft appears with correct transcription
- **Long recording:** Record 60+ seconds → EOU live text updates phrase-by-phrase, Parakeet batch transcription returns full accurate text
- **Model load:** Check `PARAKEET | models loaded` in debug log on launch
- **Mic permission:** Revoke mic permission in System Settings → press hotkey → should log warning, not crash
- **Audio device change:** Plug/unplug USB mic during idle → should log device change and re-warm
- **Quit cleanup:** Quit app during recording → green mic dot should disappear immediately
- **Debug log:** `tail -f ~/draft-debug.log | grep PARAKEET` shows all parakeet events
- **Build:** `bash build.sh` — pre-existing warnings only (NSLock in async context is intentional)
