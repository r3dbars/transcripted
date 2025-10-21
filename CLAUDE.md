# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Commands

### Building and Running
- Open `Murmur.xcodeproj` in Xcode to build and run
- Project requires macOS 26.0+ (macOS Sequoia) SDK
- Run via Xcode (⌘R) - builds and launches the menu bar app

### Key Build Settings
- Bundle ID format follows standard macOS app conventions
- Uses SwiftUI with AppKit integration for native macOS UI
- Requires signing with entitlements for microphone, speech recognition, and audio capture

## Architecture Overview

Murmur is a **macOS menu bar application** for real-time voice transcription with advanced system audio capture. It's designed for meeting recording, call transcription, and note-taking with privacy-first on-device processing.

### Core Technologies
- **SwiftUI + AppKit**: Floating panel UI, menu bar integration, settings windows
- **Speech Framework**: On-device speech recognition (macOS 26.0+) with server fallback
- **CoreAudio**: System-wide audio tap for capturing application audio (Zoom, Teams, FaceTime)
- **AVFoundation**: Audio engine for microphone input and audio mixing

### Key Capabilities
1. **Dual Audio Capture**: Microphone + system audio (calls/meetings) simultaneously
2. **On-Device Transcription**: Privacy-first using Apple's SpeechTranscriber/SpeechAnalyzer APIs
3. **Intelligent Audio Mixing**: Merges mic and system audio into unified transcript
4. **Call Detection**: Auto-detects Zoom, Teams, FaceTime, Slack calls with notification prompts
5. **Timestamped Transcripts**: Markdown output with speaker attribution and timeline

## Core Architecture

### App Structure (MurmurApp.swift)
- **AppDelegate**: Main app lifecycle, status bar menu, window management
- **FloatingPanel**: Always-on-top recording controls (start/stop, copy, save)
- **Menu Bar**: Quick access to show/hide window, settings, debug console

### Audio Pipeline (Audio.swift)
1. **Microphone capture**: AVAudioEngine input node → buffer processing
2. **System audio tap**: CoreAudio process tap (macOS 14.2+) for system-wide audio
3. **Audio mixing**: AudioMixer combines mic + system audio streams
4. **Transcription feed**: Merged audio sent to Transcription engine

### Transcription Engine (Transcription.swift)
- **SpeechTranscriber**: New macOS 26 API for continuous streaming transcription
- **SpeechAnalyzer**: Handles audio format negotiation and real-time processing
- **Hybrid Mode**: Automatically uses on-device model when available, falls back to server
- **Buffer Processing**: Converts incoming audio buffers to format expected by SpeechAnalyzer

### System Audio Capture (SystemAudioCapture.swift)
- Uses CoreAudio `AudioHardwareCreateProcessTap` to capture all system audio
- Creates aggregate audio device combining tap + output device
- Handles 48kHz real-time audio streaming from all apps
- Required entitlement: `com.apple.security.device.audio-input`

### Call Detection (CallDetector.swift)
- Monitors workspace for activation of meeting apps (Zoom, Teams, FaceTime, Slack)
- Shows native macOS notifications asking to start recording
- Clicking notification auto-starts recording session

### Transcript Storage (TranscriptSaver.swift)
- Auto-saves to `~/Documents/Murmur Transcripts/` (configurable)
- Markdown format with YAML frontmatter (date, duration, word count)
- Timeline format: `[MM:SS] [Mic/SysAudio] Transcript text`
- Native notification with "Show in Finder" action

## Critical Implementation Details

### macOS 26.0+ APIs
- **SpeechTranscriber**: Replaces older SFSpeechRecognizer for streaming transcription
- **SpeechAnalyzer**: New API for audio format negotiation and real-time analysis
- **@available(macOS 26.0, *)**: All main components require this version gate

### Entitlements (Murmur.entitlements)
Required for core functionality:
- `com.apple.security.device.audio-input` - Microphone and system audio capture
- `com.apple.security.personal-information.speech-recognition` - On-device transcription
- `com.apple.security.automation.apple-events` - Global hotkey registration

### Privacy Permissions (Info.plist)
User-facing permission prompts:
- `NSMicrophoneUsageDescription` - Microphone access for transcription
- `NSSpeechRecognitionUsageDescription` - On-device speech recognition
- `NSAudioCaptureUsageDescription` - System audio capture for meetings
- `NSAppleEventsUsageDescription` - Global hotkey support

### On-Device Model Management (SpeechModelManager.swift)
- Checks if on-device speech model is downloaded via Settings > Keyboard > Dictation
- Prompts user once to download model for enhanced privacy
- Falls back to server-based transcription if model unavailable
- Exposed in Settings window with download link

### Audio Format Handling
- **System Audio**: Real-world sample rate is 48kHz (not 96kHz as claimed by tap)
- **Microphone**: Default 48kHz or device native rate
- **Transcription Input**: SpeechAnalyzer negotiates optimal format (usually 16kHz mono)
- **BufferConverter.swift**: Handles all format conversions between stages

### Debug Infrastructure (Debug/)
- **AudioDebugMonitor**: Centralized logging for audio pipeline
- **DebugWindow**: SwiftUI console showing real-time audio stats, buffer info, transcription status
- Access via menu bar: Debug Console... (⌘D)

## File Organization

```
Murmur/
├── MurmurApp.swift           # App entry point, AppDelegate, menu bar logic
├── Core/                     # Audio and transcription engines
│   ├── Audio.swift           # Microphone + system audio capture
│   ├── Transcription.swift   # Speech recognition engine
│   ├── SystemAudioCapture.swift  # CoreAudio tap implementation
│   ├── AudioMixer.swift      # Merges mic + system audio streams
│   ├── CallDetector.swift    # Meeting app detection
│   ├── TranscriptSaver.swift # Markdown file generation
│   ├── SpeechModelManager.swift  # On-device model availability
│   └── BufferConverter.swift # Audio format conversion utilities
├── UI/                       # SwiftUI views
│   ├── FloatingPanel.swift   # Main recording controls
│   └── Settings.swift        # Preferences window
└── Debug/                    # Development tools
    ├── AudioDebugMonitor.swift  # Logging infrastructure
    └── DebugWindow.swift     # Real-time debug console
```

## Development Patterns

### State Management
- Uses SwiftUI `@Published` properties for UI reactivity
- `@ObservedObject` for cross-component state sharing
- `@AppStorage` for persisted user preferences (save location, microphone selection)

### Async/Await Usage
- Transcription APIs are fully async (SpeechTranscriber, SpeechAnalyzer)
- Audio capture uses callbacks (AVAudioEngine tap, CoreAudio IOProc)
- MainActor.run {} for UI updates from background threads

### Memory Management
- Audio buffers are large - use `@preconcurrency import AVFoundation` to avoid warnings
- SystemAudioCapture cleanup required (AudioHardwareDestroyProcessTap, aggregate device removal)
- Transcription engine must be stopped before deallocation

### Error Handling
- Permission errors shown to user via `@Published var error: String?`
- Audio capture failures logged to AudioDebugMonitor
- Graceful degradation if system audio unavailable (continues with mic only)

## Common Development Tasks

### Adding New Audio Sources
1. Capture audio in Audio.swift similar to microphone tap
2. Feed buffers to AudioMixer for merging
3. Update AudioDebugMonitor logging for new source
4. Add visualizer to FloatingPanelView if needed

### Extending Transcript Format
- Modify TranscriptSaver.swift markdown templates
- Update YAML frontmatter for new metadata fields
- Adjust timeline format in formatMarkdownWithTimestamps()

### Supporting Additional Meeting Apps
- Add bundle ID to CallDetector.meetingApps dictionary
- Test notification triggering with app activation

### Customizing Transcription Behavior
- SpeechTranscriber options in Transcription.swift startAsync()
- Adjust reportingOptions for interim vs final results
- Modify attributeOptions for timing/confidence data

## Known Platform Limitations

- **macOS 26.0+ required**: Core Speech APIs only available in latest OS
- **System audio tap**: Requires user permission, may fail on some audio devices
- **On-device model**: Not all languages supported, requires manual download
- **Real-time processing**: Large audio buffers can cause memory pressure on older Macs
