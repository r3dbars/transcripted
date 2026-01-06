# Memory: Lessons Learned & Debugging Reference

This file documents important lessons learned during development. Reference this when debugging similar issues.

---

## Architecture Quick Reference

### What This App Does
Transcripted captures mic + system audio, transcribes via cloud APIs, identifies speakers and extracts action items via Gemini, then sends tasks to Reminders/Todoist.

### Core Data Flow
```
Record → WAV files → Transcription → Speaker ID → Save → Action Items → Review → Tasks
```

### Key Components
| Component | File | Purpose |
|-----------|------|---------|
| Audio capture | `Core/Audio.swift` | Mic via AVAudioEngine, coordinates system audio |
| System audio | `Core/SystemAudioCapture.swift` | CoreAudio process taps (macOS 26+) |
| Orchestration | `Core/TranscriptionTaskManager.swift` | Background transcription queue, progress |
| UI State | `UI/FloatingPanel/PillStateManager.swift` | State machine: idle→recording→processing→reviewing |
| Action Items | `Core/ActionItemExtractor.swift` | Two-pass Gemini: speaker ID, then extraction |
| Transcription | `Core/Transcription.swift` | Provider abstraction (Apple/Deepgram/AssemblyAI) |
| Transcript Output | `Core/TranscriptSaver.swift` | Markdown with YAML frontmatter |

### State Machine (PillStateManager)
```
idle (40×20) → recording (180×40) → processing (180×40) → reviewing (280px tray) → idle
```

---

## macOS 26 System Audio Permissions

**Important**: System audio capture via `AudioHardwareCreateProcessTap` does NOT require Screen Recording permission on macOS 26. The OS provides an audio-only permission flow, which is more privacy-preserving.

This is why the app uses `@available(macOS 26.0, *)` throughout.

---

## Transcription Pipeline

### Providers
| Provider | Type | Key Feature |
|----------|------|-------------|
| Apple | On-device | Privacy-first, 45-sec chunks |
| AssemblyAI | Cloud | Speaker diarization, sentiment, chapters |
| Deepgram | Cloud | Nova-2, low latency |

### Multichannel vs Single-Source
- **Both mic + system available**: Merge to stereo → single API call (50% fewer calls)
- **Mic only**: Single source pipeline

### DisplayStatus (Goal-Gradient Effect)
```
idle → gettingReady (0-15%) → transcribing (15-75%) → findingActionItems (75-95%) → finishing (95-100%)
```

---

## UI & Design System

### Floating Panel States
| State | Dimensions | Content |
|-------|------------|---------|
| idle | 40×20 | Dormant waveform |
| recording | 180×40 | Aurora + timer + stop button |
| processing | 180×40 | Aurora + progress + status text |
| reviewing | 280px tray | Action item list |

### Aurora Color Palette (Synthwave)
- **Mic audio**: Hot pink coral `#EC4899` / light `#F472B6`
- **System audio**: Electric blue `#3B82F6` / light `#60A5FA`
- **Background**: Dark charcoal `#1A1A1A`
- **Text primary**: White `#FFFFFF`

### Animation Timing
- Pill morph: 175ms spring (response: 0.175, damping: 0.8)
- Content fade: 100ms
- Toast duration: 5s
- Success celebration: 2s

### Key UI Files
- `Design/DesignTokens.swift` - All colors, spacing, animations
- `UI/FloatingPanel/Components/Aurora*.swift` - Recording/Processing/Success views
- `UI/FloatingPanel/PillStateManager.swift` - State machine with sound feedback

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

### Audio Format Critical Details
- **Hardware format**: Use `inputFormat(forBus: 1)`, NOT `outputFormat(forBus: 0)`
- **Mic audio**: Saved as mono (manually downmixed if multi-channel)
- **System audio**: 48kHz stereo (tap claims 96kHz but actual is 48kHz)
- **Deep copy required**: System audio buffers use `bufferListNoCopy` - memory only valid during callback

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

## Expected Console Warnings (Jan 4, 2026)

### CoreAudio Internal Warnings

During system audio setup and teardown, the macOS CoreAudio framework emits internal log messages that **cannot be suppressed from user code**. These are **expected and harmless**:

| Warning | When | Why |
|---------|------|-----|
| `HALC_ShellObject::SetPropertyData: call to the proxy failed` | Startup | Internal format negotiation during aggregate device creation |
| `throwing -10877` | Startup | `kAudioUnitErr_InvalidElement` during tap initialization |
| `AudioObjectRemovePropertyListener: no object with given ID` | Cleanup | Race condition when destroying audio objects |

### Why These Can't Be Suppressed

These messages are logged directly by the CoreAudio framework (HALC = Hardware Abstraction Layer Core), not by our code. They appear even when all our error handling is correct. The messages indicate internal operations that the framework handles gracefully.

### Verifying Audio Is Working Despite Warnings

If you see these warnings but want to confirm audio capture is working:

1. **Check callback count** - Should see "I/O Proc callback #1", #2, #3 at startup
2. **Check file sizes** - System audio should grow continuously (~384KB/sec)
3. **No "skipping cycle due to overload"** - This is the critical error (see CPU Overload section above)

### SwiftUI Warning

`onChange(of: DisplayStatus) action tried to update multiple times per frame` - Fixed by wrapping state updates in `Task { @MainActor in ... }` to debounce rapid status changes during transcription progress updates.

---

## Dual SystemAudioCapture Conflict Bug (Jan 6, 2026)

### Symptom
- System audio captured for only ~60 seconds, then went silent for remainder of recording
- Mic audio worked perfectly for entire duration
- Console showed: `✅ System audio capture started` but later `⚠️ System audio: Silent for 10s`
- Transcript showed `system_utterances: 1` vs `mic_utterances: 18`
- System audio file had audio at start, then silence

### Root Cause
**Two concurrent `SystemAudioCapture` instances conflicted.**

1. `MeetingDetector` creates a passive `SystemAudioCapture` for meeting detection (monitoring audio levels without recording)
2. `Audio.swift` creates another `SystemAudioCapture` for actual recording
3. When recording starts, both taps run simultaneously
4. After 3 seconds, `MeetingDetector.checkForMeetingApps()` sees `isRecording == true`
5. It calls `stopPassiveAudioMonitor()` → `SystemAudioCapture.stop()` → `cleanup()`
6. Cleanup destroys the process tap and aggregate device
7. **This breaks the recording's tap** - CoreAudio doesn't handle concurrent taps well

### Evidence
- System audio captured "Hello" (first word) at 60% confidence before passive monitor stopped
- System audio duration: 66.0s (until passive monitor cleanup)
- Mic audio duration: 131.9s (full recording)
- Log sequence: passive starts → recording starts → passive destroyed → silence begins

### The Fix
**Stop the passive monitor BEFORE starting the recording's capture.**

1. Added `stopPassiveMonitorForRecording()` method to `MeetingDetector`
2. Added `meetingDetector` weak reference to `Audio`
3. Call `meetingDetector?.stopPassiveMonitorForRecording()` at start of `startAudioCapture()`
4. Wired up dependency in `TranscriptedApp.setupMeetingDetection()`

### Files Modified
- `Murmur/Core/MeetingDetector.swift` - Added `stopPassiveMonitorForRecording()` method
- `Murmur/Core/Audio.swift` - Added `meetingDetector` reference and call before capture
- `Murmur/TranscriptedApp.swift` - Wire up `audio.setMeetingDetector(meetingDetector!)`

### Key Lesson
**CoreAudio process taps and aggregate devices are system resources.** Having multiple concurrent taps for the same processes can cause resource conflicts. When one tap is destroyed during cleanup, it can affect others. Always ensure only one tap is active at a time.

### How to Debug Similar Issues
1. **Check for multiple SystemAudioCapture instances** - Search for `SystemAudioCapture()` constructor calls
2. **Check cleanup timing** - Look at "Cleaning up system audio capture" logs vs recording duration
3. **Compare audio durations** - If system audio is shorter than mic, something killed the tap mid-recording
4. **Look for the first captured system audio** - If present, proves tap WAS working initially

---

## Related Documentation

- [Apple Audio Unit Hosting Guide](https://developer.apple.com/documentation/audiotoolbox/audio_unit_hosting_guide)
- [Core Audio Overview](https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/CoreAudioOverview/)
- Process taps via `AudioHardwareCreateProcessTap` - macOS 26 provides audio-only permission (no Screen Recording needed)
- [OSStatus Lookup](https://www.osstatus.com/) - For decoding CoreAudio error codes
