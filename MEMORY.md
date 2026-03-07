# MEMORY.md — Debugging Reference

Read this file FIRST when debugging runtime issues. Indexed by symptom for fast lookup.

---

## Symptom Index

| Symptom | Section |
|---|---|
| Tiny system audio file (~50KB) | [CoreAudio I/O Overload](#coreaudio-io-overload) |
| "skipping cycle due to overload" in console | [CoreAudio I/O Overload](#coreaudio-io-overload) |
| System audio cuts out mid-recording | [Dual Tap Conflict](#dual-tap-conflict) |
| "0Hz 0ch" in logs | [Audio Format Rules](#audio-format-rules) |
| 96kHz mismatch / half-duration files | [Audio Format Rules](#audio-format-rules) |
| System audio half duration / sped-up playback | [NEVER Hardcode Sample Rates](#never-hardcode-sample-rates) |
| Model stuck in `.loading` | [Model Loading Issues](#model-loading-issues) |
| Wrong speaker names / poor matching | [Speaker Matching Debugging](#speaker-matching-debugging) |
| HALC_ShellObject warnings | [Expected Console Warnings](#expected-console-warnings) |
| "throwing -10877" at startup | [Expected Console Warnings](#expected-console-warnings) |
| onChange tried to update multiple times | [Expected Console Warnings](#expected-console-warnings) |
| Garbled/silent audio | [Common Audio Issues](#common-audio-issues) |
| Pill stuck in state | Check `ui` logs for "Blocked transition" |

---

## NEVER Hardcode Sample Rates

**THIS IS THE #1 AUDIO BUG IN THIS CODEBASE. It has been fixed twice. Do not introduce it again.**

**What went wrong (March 2026)**: `Audio.swift` hardcoded `actualSampleRate = 48000.0` for system audio WAV files. The aggregate device actually ran at 24kHz (matching the Mac's built-in mic hardware), not 48kHz. Result: WAV header said 48kHz but data was 24kHz → audio played back at 2x speed, system audio duration showed as exactly half of mic duration.

**The rule**: ALWAYS read the actual sample rate from the device. NEVER hardcode 48000, 44100, 24000, or any other rate.

**How it's solved now**:
1. `SystemAudioCapture.setupSystemAudioTap()` reads `aggregateDeviceID.readNominalSampleRate()` after creating the aggregate device
2. If the tap format rate differs from the device nominal rate, it corrects the format
3. `Audio.swift` uses `tapFormat.sampleRate` (the corrected value) for WAV file settings

**How to detect**: Compare system audio duration vs mic duration in logs. They should be within ~1s. If system is exactly half of mic, the sample rate is wrong.

---

## Audio Format Rules

- **Mic format**: Use `inputFormat(forBus: 1)` (hardware format). NEVER `outputFormat(forBus: 0)` — returns 0Hz 0ch.
- **System audio**: Use aggregate device's nominal sample rate (via `readNominalSampleRate()`). Do NOT hardcode any rate — the tap format rate can differ from the actual device rate.
- **Mic saving**: Mono (manually downmixed if multi-channel hardware)
- **System audio buffers**: Use `bufferListNoCopy` — memory only valid during callback. Deep-copy before async dispatch.

---

## CoreAudio I/O Overload

**Symptom**: System audio files tiny (~50KB instead of ~2MB). Console: `HALC_ProxyIOContext::IOWorkLoop: skipping cycle due to overload`. Only 3 I/O callbacks complete, then all frames dropped. `system_utterances: 0` despite visualizer showing levels.

**Root cause**: Creating `AVAudioFile` inside CoreAudio I/O callback. For 512-sample buffer at 48kHz, callback must return within ~10.7ms. File creation takes 10-100ms.

**Fix pattern**: Create audio file BEFORE starting I/O proc.
```swift
// GOOD: File creation before callbacks
try capture.prepare()  // Creates tap, gets format
systemAudioFile = try AVAudioFile(forWriting: url, settings: ...)  // Before I/O
try capture.start { buffer in
    let copy = deepCopyBuffer(buffer)  // Deep copy required
    fileQueue.async { try systemAudioFile?.write(from: copy) }
}
```

**CoreAudio callback rules**:
1. NEVER do disk I/O — no file creation, reads, or logging
2. NEVER allocate large memory — pre-allocate buffers
3. NEVER block on locks — use lock-free queues or try-locks
4. NEVER call ObjC/Swift methods that might allocate
5. Dispatch heavy work to background queues
6. Deep-copy buffers before async dispatch

---

## Dual Tap Conflict

**Symptom**: System audio captured for ~60s then goes silent. Mic works for full duration. `system_utterances: 1` vs `mic_utterances: 18`.

**Root cause**: Two concurrent `SystemAudioCapture` instances (recording + passive monitor) conflict. When passive monitor calls `cleanup()`, it destroys the shared process tap and breaks the recording's capture.

**Key lesson**: CoreAudio process taps are system resources. Multiple concurrent taps for same processes cause conflicts. Ensure only one tap active at a time. Stop passive monitors BEFORE starting recording capture.

**Note**: The MeetingDetector component that caused this was removed (Feb 2026), but the lesson applies to any future use of multiple SystemAudioCapture instances.

---

## Expected Console Warnings

These CoreAudio framework warnings are **expected and harmless** — they cannot be suppressed from user code:

| Warning | When | Why |
|---|---|---|
| `HALC_ShellObject::SetPropertyData: call to the proxy failed` | Startup | Internal format negotiation during aggregate device creation |
| `throwing -10877` | Startup | `kAudioUnitErr_InvalidElement` during tap initialization |
| `AudioObjectRemovePropertyListener: no object with given ID` | Cleanup | Race condition destroying audio objects |

**SwiftUI warning**: `onChange action tried to update multiple times per frame` — caused by rapid DisplayStatus changes. Fixed by wrapping state updates in `Task { @MainActor in }`.

**Verifying audio works despite warnings**: Check callback count (should see callbacks #1, #2, #3 at startup), check file sizes (system audio ~384KB/sec), no "skipping cycle due to overload".

---

## Common Audio Issues

| Symptom | Cause | Fix |
|---|---|---|
| Tiny system audio file | Callbacks dropped (I/O overload) | Move heavy work out of callback. See [CoreAudio I/O Overload](#coreaudio-io-overload) |
| Wrong sample rate | Format mismatch | System = use device nominal rate. Mic = use buffer's actual format |
| Mono instead of stereo | Channel count mismatch | Check `format.channelCount` |
| Garbled audio | Interleaved/non-interleaved mismatch | Match `isInterleaved` setting |
| Silent audio | Wrong bus or format | Use `inputFormat(forBus: 1)` for hardware format |
| Half-expected duration | Tap format rate differs from device rate | Use `readNominalSampleRate()` on aggregate device |

---

## Audio Debugging Commands

```bash
# Check file duration
afinfo ~/Documents/Transcripted/meeting_*_system.wav | grep duration

# Play audio to verify content
afplay ~/Documents/Transcripted/meeting_*_system.wav

# Check file sizes (system should be ~384KB/sec)
ls -la ~/Documents/Transcripted/meeting_*_system.wav

# Read app logs
# Use Read tool on: ~/Library/Logs/Transcripted/app.jsonl
# Filter with Grep for subsystem: "s":"audio.system"
```

---

## Model Loading Issues

**Symptom**: Model stuck in `.loading`, transcription never starts.

**Check**: Grep logs for subsystem `transcription`. Common causes:
- HuggingFace download failed (network or disk space)
- Bundle path wrong — models expected at `Contents/Resources/parakeet-models/` and `sortformer-models/`
- Qwen: needs 4GB free memory — check `hasMemoryForQwen()` in TranscriptionTaskManager

**Qwen-specific**: Model cached at `~/Library/Caches/models/mlx-community/Qwen3.5-4B-4bit/`. `QwenService.isModelCached` checks this path. Model is loaded on-demand (NOT at startup).

---

## Speaker Matching Debugging

**Symptom**: Wrong speaker names, speakers merged incorrectly, or speakers not recognized.

**Check**: Grep logs for subsystem `speaker-db`.

**Key parameters** (in SpeakerDatabase.swift):
- Match threshold: adaptive 0.85 (1 segment) → 0.70 (4+ segments)
- EMA alpha: 0.15 for embedding blending
- Post-processing: pairwise merge 0.85, DB-informed split 0.62

**Common issues**:
- Threshold too low → different speakers merged
- Threshold too high → same speaker gets multiple profiles
- Stale profiles → run `pruneWeakProfiles()`
- Name variants not recognized → check `areNameVariants()` in SpeakerDatabase

---

## Transcription Pipeline Reference

**Pipeline** (batch, after recording stops):
1. Resample audio to 16kHz mono (AudioResampler)
2. Sortformer diarizes system audio → speaker segments with embeddings
3. EmbeddingClusterer post-processes segments (merge + split)
4. Parakeet transcribes each speaker segment individually
5. Parakeet transcribes full mic track (split into sentences)
6. Match speaker embeddings against SpeakerDatabase
7. Merge mic + system utterances chronologically

**DisplayStatus progression**: idle → gettingReady (0-15%) → transcribing (15-75%) → finishing (95-100%) → transcriptSaved | failed

**Historical providers (removed)**: Deepgram (removed Feb 2026), Apple Speech (legacy), AssemblyAI (never integrated).

---

## Reference Links
- [Core Audio Overview](https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/CoreAudioOverview/)
- [OSStatus Lookup](https://www.osstatus.com/) — decode CoreAudio error codes
- Process taps via `AudioHardwareCreateProcessTap` — macOS 26 provides audio-only permission (no Screen Recording needed)
