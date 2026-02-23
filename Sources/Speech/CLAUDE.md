# Speech — WhisperEngine (Primary) + SpeechEngine (Legacy)

## What This Does

Audio recording and transcription. **WhisperEngine** is the sole transcription engine — it records audio, provides live streaming text via Apple Speech (display-only), and batch-transcribes via whisper.cpp (large-v3-turbo) for the final transcript. SpeechEngine is legacy code preserved for reference.

## Key Files

- `WhisperEngine.swift` (~500 lines) — `@MainActor ObservableObject`: audio recording, NSLock-batched sample collection, live Apple Speech display, Whisper batch inference on serial DispatchQueue, audio level metering
- `SpeechEngine.swift` — Legacy Apple-only speech engine (unused in v2 — WhisperEngine is sole engine)

## Architecture

```
Audio Input (AVAudioEngine tap, mono at native sample rate)
    │
    ├─→ Consumer 1: Apple Speech (live display only — SFSpeechAudioBufferRecognitionRequest)
    │   └─→ liveTranscript — shown in overlay during recording
    │
    ├─→ Consumer 2: Whisper sample buffer (NSLock-protected pendingSamples)
    │   └─→ Flushed into sampleBuffer on stopRecording() or transcribe()
    │   └─→ Batch inference via whisper_full() on serial inferenceQueue
    │   └─→ Returns final transcript text
    │
    └─→ Consumer 3: Audio level metering (~20Hz throttled)
        └─→ audioLevel (0.0–1.0) — drives waveform animation in overlay
```

## Critical Design Decisions

### NSLock for Audio Thread → MainActor Transfer

The audio render callback runs on a real-time thread with ~10ms deadlines. Originally, each callback created a `Task { @MainActor }` to append samples (~47 Tasks/second). This was replaced with an NSLock-protected intermediate buffer:

```swift
// Audio callback (real-time thread):
self.pendingSamplesLock.lock()
self.pendingSamples.append(contentsOf: samples)
self.pendingSamplesLock.unlock()

// MainActor (stopRecording/transcribe):
pendingSamplesLock.lock()
sampleBuffer.append(contentsOf: pendingSamples)
pendingSamples.removeAll(keepingCapacity: true)
pendingSamplesLock.unlock()
```

**Why NSLock over actors:** Actor isolation involves scheduling on an executor with unpredictable latency. NSLock's `lock()`/`unlock()` is a single syscall with deterministic ~1μs overhead. Swift 6 warns about NSLock in async context — this is a false positive here since the lock protects a buffer between the audio thread and MainActor, not between two async contexts.

### Serial Inference Queue

`whisper_context` is NOT safe for concurrent `whisper_full()` calls — the Metal backend shares command buffers internally. A private serial `DispatchQueue` (`com.draft.whisper-inference`) prevents the `ggml_abort` crash that occurs with concurrent access.

### State Transition Guards

- `loadModel()`: refuses if `isRecording` or `isTranscribing` (unloading during Metal inference = use-after-free)
- `unloadModel()`: same guard — model can't be freed while inference queue uses it
- `startRecording()`: requires `isModelLoaded` (prevents recording without a model) AND `AVCaptureDevice.authorizationStatus(for: .audio) == .authorized` (prevents ObjC exception if mic permission revoked at runtime)
- `transcribe()`: guards against `isTranscribing` to prevent concurrent inference

### Audio Engine Pre-warming

`prewarm()` starts and immediately stops the audio engine on launch. This forces macOS to initialize the audio graph and allocate Core Audio buffers upfront, reducing first-recording latency from ~300ms to near-zero.

### Device Change Handling

Observes `.AVAudioEngineConfigurationChange` notification to detect when audio devices change (e.g., USB mic plugged/unplugged). On change, the engine re-reads the native sample rate and re-warms if needed.

### deinit Cleanup

```swift
deinit {
    NotificationCenter.default.removeObserver(configChangeObserver)
    audioEngine.inputNode.removeTap(onBus: 0)   // Release mic (green dot goes away)
    audioEngine.stop()
    whisper_free(whisperContext)                   // Free model memory
}
```

Without the audio engine cleanup, the microphone green dot persists after the engine deallocates.

## Public Interface

```swift
@Published var isRecording: Bool
@Published var isTranscribing: Bool
@Published var audioLevel: Float          // 0.0–1.0 RMS for waveform
@Published var liveTranscript: String     // Apple Speech display-only text

var isModelLoaded: Bool
var inputDeviceName: String               // Current mic name for logging

func loadModel(path: String) -> Bool      // Load GGML model (guarded)
func unloadModel()                        // Free model (guarded)
func prewarm()                            // Pre-initialize audio engine
func startRecording()                     // Start mic tap + Apple Speech + sample collection
func stopRecording()                      // Stop tap, flush pending samples
func cancel()                             // Stop without transcribing
func transcribe() async -> String?        // Batch Whisper inference (serial queue)
```

## Critical Gotchas

### 1. Multi-Channel Audio Interfaces

Pro audio interfaces like BEACN Mic (96kHz/4ch) cause Apple Speech error 1110. Fix: force mono tap format at native sample rate — AVAudioEngine handles channel mixdown automatically. **Do NOT force 16kHz** — sample rate mismatch crashes with an ObjC exception.

### 2. Apple Speech Live Transcript Resets

Apple Speech silently resets `bestTranscription.formattedString` mid-session. The live transcript tracks `committedLiveText` and detects resets to avoid losing display text. This is display-only — Whisper owns the final transcript.

### 3. Microphone Permission Can Be Revoked at Runtime

`startRecording()` checks `AVCaptureDevice.authorizationStatus(for: .audio)` before `installTap()`. Without this check, revoking mic permission while the app is open causes `installTap()` to throw an unrecoverable ObjC exception.

## Verification

After modifying WhisperEngine, verify with these checks:

- **Basic recording:** ⌥D → speak → ⌥D → draft appears with correct transcription
- **Long recording:** Record 60+ seconds → Apple Speech live text chains tasks seamlessly, Whisper batch transcription returns full text
- **Model load/unload:** Check `WHISPER | model loaded` in debug log on launch
- **State guards:** Try calling `unloadModel()` while recording → should log warning and refuse
- **Mic permission:** Revoke mic permission in System Settings → press hotkey → should log warning, not crash
- **Audio device change:** Plug/unplug USB mic during idle → should log device change and re-warm
- **Memory:** Record for 60+ seconds → check Activity Monitor for no memory growth from Task creation (batched samples eliminate ~47 Tasks/sec)
- **Quit cleanup:** Quit app during recording → green mic dot should disappear immediately
- **Debug log:** `tail -f ~/draft-debug.log | grep WHISPER` shows all whisper events
- **Build:** `bash build.sh` — pre-existing warnings only (NSLock in async context is intentional)
