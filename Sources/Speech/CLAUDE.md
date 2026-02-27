# Speech — Parakeet STT Engine

## What This Does

Audio recording and transcription via **ParakeetEngine** — a CoreML-based STT engine using FluidAudio's Parakeet TDT V3 (~0.2s latency). `STTRouter` wraps ParakeetEngine with Combine property forwarding for SwiftUI binding.

## Key Files

- `ParakeetEngine.swift` (~490 lines) — `@MainActor ObservableObject`: AVAudioEngine tap, NSLock-batched sample collection, live Apple Speech display, CoreML batch inference via FluidAudio AsrManager, audio level metering
- `STTRouter.swift` (~50 lines) — Thin wrapper forwarding `@Published` properties from ParakeetEngine via Combine
- `AudioResampler.swift` — Sample rate conversion (native → 16kHz for Parakeet)

## Architecture

```
Audio Input (AVAudioEngine tap, mono at native sample rate)
    │
    ├─→ Consumer 1: Apple Speech (live display only — SFSpeechAudioBufferRecognitionRequest)
    │   └─→ liveTranscript — shown in overlay during recording
    │
    ├─→ Consumer 2: Parakeet sample buffer (NSLock-protected pendingSamples)
    │   └─→ Flushed into sampleBuffer on stopRecording() or transcribe()
    │   └─→ Resampled to 16kHz via AudioResampler
    │   └─→ Batch inference via AsrManager.transcribe()
    │   └─→ Returns final transcript text
    │
    └─→ Consumer 3: Audio level metering (~20Hz throttled)
        └─→ audioLevel (0.0–1.0) — drives waveform animation in overlay
```

## Critical Design Decisions

### NSLock for Audio Thread → MainActor Transfer

The audio render callback runs on a real-time thread with ~10ms deadlines. NSLock provides deterministic ~1μs overhead for the shared sample buffer between the audio thread and MainActor. Swift 6 warns about NSLock in async context — this is a false positive since the lock protects a buffer between threads, not between two async contexts.

### Model Initialization

`ParakeetEngine.initialize()` loads CoreML models either from the app bundle (`Contents/Resources/parakeet-models/`) or via HuggingFace download (~600MB). The `modelDownloadState` published property drives a progress bar in settings. Model loading is async and non-blocking — the app starts immediately.

### Audio Engine Pre-warming

`prewarm()` starts and immediately stops the audio engine on launch. This forces macOS to initialize the audio graph and allocate Core Audio buffers upfront, reducing first-recording latency from ~300ms to near-zero.

### Device Change Handling

Observes `.AVAudioEngineConfigurationChange` notification to detect when audio devices change (e.g., USB mic plugged/unplugged). On change, the engine re-reads the native sample rate and re-warms if needed. If re-warm fails while recording was active, `recordingInterrupted` is set to `true` — DraftSessionController observes this and cancels the session with a user-visible error.

### startRecording() Returns Bool

`startRecording()` returns `false` on failure (model not loaded, mic unauthorized, audio format creation failed, engine start failed). On engine start failure, the audio tap is explicitly removed to prevent a double-install ObjC exception on the next call. Callers (STTRouter, DraftSessionController) check the return value and show error UI.

### deinit Cleanup

```swift
deinit {
    audioEngine.inputNode.removeTap(onBus: 0)   // Release mic (green dot goes away)
    audioEngine.stop()
    asrManager?.cleanup()
}
```

Without the audio engine cleanup, the microphone green dot persists after the engine deallocates.

## Critical Gotchas

### 1. Multi-Channel Audio Interfaces

Pro audio interfaces like BEACN Mic (96kHz/4ch) cause Apple Speech error 1110. Fix: force mono tap format at native sample rate — AVAudioEngine handles channel mixdown automatically. **Do NOT force 16kHz** — sample rate mismatch crashes with an ObjC exception.

### 2. Apple Speech Live Transcript Resets

Apple Speech silently resets `bestTranscription.formattedString` mid-session. The live transcript tracks `committedLiveText` and detects resets to avoid losing display text. This is display-only — Parakeet owns the final transcript.

### 3. Microphone Permission Can Be Revoked at Runtime

`startRecording()` checks `AVCaptureDevice.authorizationStatus(for: .audio)` before `installTap()`. Without this check, revoking mic permission while the app is open causes `installTap()` to throw an unrecoverable ObjC exception.

## Verification

After modifying ParakeetEngine, verify with these checks:

- **Basic recording:** ⌥D → speak → ⌥D → draft appears with correct transcription
- **Long recording:** Record 60+ seconds → Apple Speech live text chains tasks seamlessly, Parakeet batch transcription returns full text
- **Model load:** Check `PARAKEET | models loaded` in debug log on launch
- **Mic permission:** Revoke mic permission in System Settings → press hotkey → should log warning, not crash
- **Audio device change:** Plug/unplug USB mic during idle → should log device change and re-warm
- **Quit cleanup:** Quit app during recording → green mic dot should disappear immediately
- **Debug log:** `tail -f ~/draft-debug.log | grep PARAKEET` shows all parakeet events
- **Build:** `bash build.sh` — pre-existing warnings only (NSLock in async context is intentional)
