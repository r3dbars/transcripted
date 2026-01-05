# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Important References

- **MEMORY.md** - Contains lessons learned and debugging references from past issues. **Check this file first when debugging audio, transcription, or performance issues.**

## Behavioral Guidelines

### Proactive Implementation
By default, implement changes rather than only suggesting them. If intent is unclear, infer the most useful likely action and proceed, using tools to discover missing details instead of guessing.

### Read Before Answering
Never speculate about code you have not opened. If a specific file is referenced, read it before answering. Investigate and read relevant files BEFORE answering questions about the codebase. This is especially critical for this codebase given the nuanced CoreAudio and Speech framework APIs.

### Work Summaries
After completing a task that involves tool use (file edits, builds, searches), provide a quick summary of the work done.

### Parallel Tool Execution
When calling multiple tools with no dependencies between them, make all independent calls in parallel to maximize speed and efficiency.

### No Overengineering
Avoid over-engineering. Only make changes that are directly requested or clearly necessary:
- Don't add features beyond what was asked
- Don't refactor surrounding code unless explicitly requested
- A bug fix doesn't need surrounding code cleaned up
- A simple feature doesn't need extra configurability

## Project Overview

**Transcripted** is a native macOS application that automatically records, transcribes, and organizes voice conversations from meetings and calls. The app uses Deepgram for cloud transcription with multichannel speaker diarization. It extracts action items from transcripts using Gemini AI and sends them to Apple Reminders or Todoist.

## Build & Run Commands

```bash
# Open in Xcode (primary development method)
open Murmur.xcodeproj

# Build from command line
xcodebuild -project Murmur.xcodeproj -scheme Murmur -configuration Debug build

# Build for release
xcodebuild -project Murmur.xcodeproj -scheme Murmur -configuration Release build

# Clean build
xcodebuild -project Murmur.xcodeproj -scheme Murmur clean
```

**Requirements:**
- macOS 14.2+ (Sonoma) - required for system audio capture APIs
- Xcode 15+
- Swift 5.9+

## Architecture

### Core Audio Pipeline

```
Murmur/Core/Audio.swift              → Microphone capture via AVAudioEngine
                                     → Writes to WAV file in real-time
                                     → Monitors audio levels for silence detection

Murmur/Core/SystemAudioCapture.swift → System-wide audio via CoreAudio process taps
                                     → Creates aggregate device with tap
                                     → Captures all system audio including meeting apps

Murmur/Core/Transcription.swift      → Deepgram multichannel transcription
                                     → Merges mic + system audio into stereo
                                     → Speaker diarization per channel

Murmur/Core/TranscriptSaver.swift    → Outputs markdown with YAML frontmatter
                                     → Saves to ~/Documents/Transcripted/
```

### Transcription Provider

The app uses **Deepgram** for cloud transcription with multichannel support:

| Feature | Description |
|---------|-------------|
| Model | Nova-3 with smart formatting |
| Multichannel | Mic (ch0) + System audio (ch1) in stereo |
| Diarization | Speaker identification within each channel |
| Retry | Exponential backoff (2s, 4s, 8s) for 408, 429, 500-504 |

**Service:** `Murmur/Services/DeepgramService.swift`

**Note:** System audio is required for transcription. The app will prompt for Screen Recording permission.

### State Management

```
TranscriptedApp.swift (AppDelegate)
├── Audio                    → Recording state, audio levels
├── TranscriptionTaskManager → Background transcription queue, progress tracking
├── FailedTranscriptionManager → Retry queue with persistent storage
├── RecordingValidator       → Pre-recording system checks
└── FloatingPanelController  → UI coordination
```

### Action Item Pipeline

When enabled, transcripts are processed for action items:
```
Murmur/Core/ActionItemExtractor.swift → Sends transcript to Gemini 2.0 Flash Lite API
                                      → Extracts tasks, owners, priorities, due dates

Murmur/Core/DateParser.swift          → Parses natural language dates ("next Friday", "EOW")
                                      → Uses NSDataDetector + custom fallbacks

Murmur/Services/RemindersService.swift → Creates EKReminders from extracted action items
Murmur/Services/TodoistService.swift   → Alternative: sends tasks to Todoist via API
```

### UI Components

The floating panel UI is organized in `Murmur/UI/FloatingPanel/`:

```
FloatingPanel/
├── FloatingPanelController.swift   # NSWindowController, window management
├── FloatingPanelView.swift         # Main SwiftUI view composition
├── PillStateManager.swift          # State machine (idle/recording/processing/reviewing)
├── Components/
│   ├── PillViews.swift             # Pill state views (Idle, Recording, Processing, Reviewing)
│   ├── WaveformViews.swift         # Audio visualizers (EdgePeek, WaveformMini, Dormant)
│   ├── CelebrationViews.swift      # Success animations (checkmarks, confetti)
│   ├── ErrorViews.swift            # Error banners with recovery hints
│   ├── AttentionPromptView.swift   # Notification prompts (silence warning)
│   └── ReviewTrayView.swift        # Action item review tray
└── Helpers/
    └── LawsComponents.swift        # Reusable UI primitives (buttons, status text)
```

Other UI files:
- **SettingsView** (`Murmur/UI/Settings.swift`) - Tabbed settings (Recording, AI Features, Advanced)
- **ActionItemReviewView** (`Murmur/UI/ActionItemReviewView.swift`) - Task approval workflow
- **FailedTranscriptionsView** - UI for retry queue management

### Onboarding Flow

Six-step onboarding managed by `Murmur/Onboarding/OnboardingState.swift`:
1. Welcome → 2. Value Proposition → 3. How It Works → 4. Permissions → 5. Demo → 6. Ready

Permissions requested: Microphone + Speech Recognition (required), Screen Recording (for system audio), Reminders (optional)

## Design System

Defined in `Murmur/Design/DesignTokens.swift`:
- **Panel theme**: Dark charcoal (`panelCharcoal`, `panelCharcoalElevated`)
- **Recording accent**: Coral red (`recordingCoral` #FF6B6B)
- **Text**: `panelTextPrimary`, `panelTextSecondary`, `panelTextMuted`
- **Onboarding theme**: Warm cream with terracotta accents
- **Animation presets**: `.elegant` (0.5s), `.refined`, `.snappy`

## Data Flow

1. **Recording starts** → `RecordingValidator.validateRecordingConditions()` checks disk space, permissions, devices
2. **Audio capture** → `Audio.start()` + `SystemAudioCapture.start()` write WAV files
3. **Recording stops** → `onRecordingComplete` callback triggers
4. **Transcription queued** → `TranscriptionTaskManager.startTranscription()`
5. **On failure** → `FailedTranscriptionManager.addFailedTranscription()` persists to `~/Documents/Transcripted/failed_transcriptions.json`
6. **On success** → `TranscriptSaver.save()` writes markdown, audio files deleted
7. **Action items** → Extracted via Gemini API, sent to Reminders or Todoist

## Configuration

User settings stored in `UserDefaults`:

| Key | Description |
|-----|-------------|
| `transcriptSaveLocation` | Custom output folder path |
| `deepgramAPIKey` | Deepgram API key for transcription |
| `geminiAPIKey` | Gemini API key for action item extraction |
| `taskService` | "reminders" or "todoist" |
| `todoistAPIKey` | Todoist API key (if using Todoist) |
| `userName` | User's name for action item attribution |
| `hasCompletedOnboarding` | Onboarding completion flag |
| `enableMeetingDetection` | Enable/disable meeting detection prompt |

## Debug Features

In DEBUG builds, the menu bar includes "Reset Onboarding (Debug)" to test the onboarding flow.

To test failed transcription retry:
```swift
// In TranscriptionTaskManager.startTranscription(), uncomment:
// throw NSError(domain: "TestError", code: 999, ...)
```

## Important Implementation Notes

### macOS Version Annotations
The app uses `@available(macOS 26.0, *)` annotations throughout, targeting macOS 14.2+ due to:
- `AudioHardwareCreateProcessTap` API for system audio
- `SpeechAnalyzer` with `.audioTimeRange` attribute options

### Audio Format Handling
- Mic audio: Uses hardware format from `inputNode.inputFormat(forBus: 1)` (NOT `outputFormat`)
- System audio: Native 48kHz (tap claims 96kHz but actual rate is 48kHz)
- Transcription: Converts to Int16 format required by Speech framework

### Transcript Format
Output is markdown with YAML frontmatter:
```yaml
---
date: YYYY-MM-DD
time: HH:mm:ss
duration: "MM:SS"
processing_time: "X.Xs"
word_count: N
---
```
Timeline entries: `[MM:SS] [Mic/SysAudio/Speaker X] Text`

### Cloud Service Retry Logic
- **Deepgram**: Automatic retry with exponential backoff (2s, 4s, 8s) for status codes 408, 429, 500-504

## File Organization

```
Murmur/
├── Core/              # Audio, transcription, clipboard, validators
├── Design/            # DesignTokens, PremiumComponents
├── Onboarding/        # Steps/, Animations/, OnboardingState
├── Services/          # RemindersService, TodoistService, DeepgramService
├── UI/                # FloatingPanel, Settings, FailedTranscriptionsView
├── TranscriptedApp.swift   # App entry point (AppDelegate pattern)
└── Transcripted.entitlements
```
