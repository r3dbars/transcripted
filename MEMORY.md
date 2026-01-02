# Memory: Lessons Learned & Debugging Reference

This file documents important lessons learned during development. Reference this when debugging similar issues.

---

## CoreAudio I/O Callback CPU Overload (Jan 2, 2026)

### Symptom
- System audio files were tiny (~50KB instead of ~2MB for a 40-second recording)
- Console showed: `HALC_ProxyIOContext::IOWorkLoop: skipping cycle due to overload` (hundreds of times)
- Only 3 I/O callbacks completed, then all subsequent audio frames were dropped
- System audio duration reported as 0.0 seconds
- Transcripts showed `system_utterances: 0` despite visualizer showing audio levels

### Root Cause
**Creating `AVAudioFile` inside the CoreAudio I/O callback caused CPU overload.**

The I/O callback (created via `AudioDeviceCreateIOProcIDWithBlock`) runs on a real-time audio thread with strict timing requirements. For a 512-sample buffer at 48kHz, the callback must return within ~10.7ms (realistically <1ms to be safe).

Creating an `AVAudioFile` involves:
1. File system metadata operations
2. Disk space allocation
3. WAV header writing
4. Potential disk I/O blocking

This can take 10-100ms, causing CoreAudio to skip subsequent cycles.

### The Broken Pattern
```swift
// BAD: File creation inside I/O callback
try capture.start { systemBuffer in
    // First callback creates the file - BLOCKS AUDIO THREAD!
    if self.systemAudioFile == nil {
        self.systemAudioFile = try AVAudioFile(forWriting: fileURL, ...)  // 10-100ms!
    }
    try self.systemAudioFile?.write(from: systemBuffer)
}
```

### The Fix
**Create the audio file BEFORE starting the I/O proc.**

1. Added `prepare()` method to `SystemAudioCapture` that creates the tap without starting I/O
2. Exposed `audioFormat` property to get the tap's format after preparation
3. Created audio file synchronously before calling `start()`
4. Callback now only does lightweight operations

```swift
// GOOD: File creation before I/O callback starts
try capture.prepare()  // Creates tap, gets format
let format = capture.audioFormat!
self.systemAudioFile = try AVAudioFile(forWriting: fileURL, settings: ...)  // Done BEFORE callbacks

try capture.start { systemBuffer in
    // Callback is now lightweight - no file creation!
    let copy = self.deepCopyBuffer(systemBuffer)
    self.fileQueue.async {
        try self.systemAudioFile?.write(from: copy)
    }
}
```

### Key Rules for CoreAudio Callbacks

1. **NEVER do disk I/O** - No file creation, no file reads, no logging to files
2. **NEVER allocate large memory blocks** - Pre-allocate buffers before starting
3. **NEVER block on locks** - Use lock-free queues or try-locks
4. **NEVER call Objective-C/Swift methods that might allocate** - Be careful with string interpolation
5. **Dispatch heavy work to background queues** - Use async dispatch for file writes
6. **Deep copy buffers before async dispatch** - System audio uses `bufferListNoCopy`, memory is only valid during callback

### How to Debug Similar Issues

1. **Check console for overload messages:**
   ```
   HALC_ProxyIOContext::IOWorkLoop: skipping cycle due to overload
   ```

2. **Add callback counters:**
   ```swift
   var callbackCount = 0
   // In callback:
   callbackCount += 1
   if callbackCount <= 3 { print("Callback #\(callbackCount)") }
   ```

3. **Check file sizes after recording:**
   ```bash
   ls -la ~/Documents/Transcripted/meeting_*_system.wav
   ```
   If system files are tiny (~50KB) but mic files are normal (~2MB), system audio callbacks are being dropped.

4. **Compare working vs broken commits:**
   ```bash
   git log --oneline -- Murmur/Core/Audio.swift
   git show <commit>:Murmur/Core/Audio.swift | grep -A 50 "system audio"
   ```

### Files Involved
- `Murmur/Core/Audio.swift` - Main recording class, manages mic + system audio files
- `Murmur/Core/SystemAudioCapture.swift` - CoreAudio process tap for system-wide audio
- `Murmur/Core/AudioPreprocessor.swift` - Merges mic + system into stereo for transcription

---

## General Audio Debugging Tips

### Verify Audio Pipeline Health
```swift
// Add to callback for debugging
print("Buffer: \(buffer.frameLength) frames, \(buffer.format.sampleRate)Hz")
```

### Check Audio File Contents
```bash
# Get duration of WAV file
afinfo ~/Documents/Transcripted/meeting_*_system.wav | grep duration

# Play audio file to verify content
afplay ~/Documents/Transcripted/meeting_*_system.wav
```

### Common Audio Issues

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| Tiny file size | Callbacks being dropped | Move heavy work out of callback |
| Wrong sample rate | Format mismatch | Use buffer's actual format, not hardcoded |
| Mono instead of stereo | Channel count mismatch | Check `format.channelCount` |
| Garbled audio | Interleaved/non-interleaved mismatch | Match `isInterleaved` setting |
| Silent audio | Wrong bus or format | Use `inputFormat(forBus: 1)` for hardware format |

---

## Related Documentation

- [Apple Audio Unit Hosting Guide](https://developer.apple.com/documentation/audiotoolbox/audio_unit_hosting_guide)
- [Core Audio Overview](https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/CoreAudioOverview/)
- Process taps require macOS 14.2+ (`AudioHardwareCreateProcessTap`)
