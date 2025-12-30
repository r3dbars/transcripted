# Transcripted

A native macOS app that automatically records, transcribes, and organizes voice conversations from meetings and calls. Built with Swift, SwiftUI, and supports both on-device and cloud transcription.

## Features

**Recording & Transcription**
- Floating pill UI - Dynamic Island-style interface that doesn't interrupt your workflow
- Dual audio capture - Records both microphone and system audio (Zoom, Meet, Teams, etc.)
- Multiple transcription providers - Apple (on-device), Deepgram, or AssemblyAI
- Real-time status - Visual feedback during recording and processing

**AI-Powered Action Items**
- Automatic extraction - Uses Gemini AI to identify tasks from transcripts
- Smart parsing - Understands "next Friday", "EOW", relative dates
- Task integration - Sends to Apple Reminders or Todoist
- Review workflow - Approve/edit items before adding

**Output & Organization**
- Markdown transcripts - With YAML frontmatter (date, duration, word count)
- Speaker identification - Labels by audio source (Mic/System Audio)
- Timeline format - `[MM:SS]` timestamps throughout
- Auto-save - Transcripts saved to `~/Documents/Transcripted/`

## Requirements

- macOS 14.2+ (Sonoma) - required for system audio capture APIs
- Xcode 15+
- Swift 5.9+

## Building

```bash
# Open in Xcode (recommended)
open Murmur.xcodeproj

# Or build from command line
xcodebuild -project Murmur.xcodeproj -scheme Murmur -configuration Debug build

# Build for release
xcodebuild -project Murmur.xcodeproj -scheme Murmur -configuration Release build
```

## Permissions

On first launch, Transcripted requests:

| Permission | Purpose | Required |
|------------|---------|----------|
| Microphone | Capture your voice | Yes |
| Speech Recognition | On-device transcription | Yes |
| Screen Recording | Capture system audio from meetings | For system audio |
| Reminders | Create tasks from action items | Optional |

## Architecture

```
Murmur/
├── Core/                           # Business logic
│   ├── Audio.swift                 # Microphone capture via AVAudioEngine
│   ├── SystemAudioCapture.swift    # System audio via CoreAudio process taps
│   ├── Transcription.swift         # Apple Speech framework wrapper
│   ├── TranscriptionTaskManager.swift  # Background transcription queue
│   ├── ActionItemExtractor.swift   # Gemini AI integration
│   ├── DateParser.swift            # Natural language date parsing
│   └── TranscriptSaver.swift       # Markdown output
│
├── Services/                       # External integrations
│   ├── DeepgramService.swift       # Cloud transcription
│   ├── AssemblyAIService.swift     # Cloud transcription
│   ├── RemindersService.swift      # Apple Reminders
│   └── TodoistService.swift        # Todoist API
│
├── UI/
│   ├── FloatingPanel/              # Floating pill UI
│   │   ├── FloatingPanelController.swift   # Window management
│   │   ├── FloatingPanelView.swift         # Main SwiftUI view
│   │   ├── PillStateManager.swift          # State machine
│   │   ├── Components/
│   │   │   ├── PillViews.swift             # Idle, Recording, Processing states
│   │   │   ├── WaveformViews.swift         # Audio visualizers
│   │   │   ├── CelebrationViews.swift      # Success animations
│   │   │   ├── ErrorViews.swift            # Error handling UI
│   │   │   ├── AttentionPromptView.swift   # Notifications
│   │   │   └── ReviewTrayView.swift        # Action item review
│   │   └── Helpers/
│   │       └── LawsComponents.swift        # UI primitives
│   ├── Settings.swift              # Preferences window
│   ├── ActionItemReviewView.swift  # Task approval UI
│   └── FailedTranscriptionsView.swift  # Retry queue
│
├── Design/
│   ├── DesignTokens.swift          # Colors, spacing, animations
│   └── PremiumComponents.swift     # Shared UI components
│
├── Onboarding/                     # First-run experience
│   ├── OnboardingState.swift
│   ├── OnboardingWindow.swift
│   └── Steps/                      # Welcome, Permissions, etc.
│
└── TranscriptedApp.swift           # App entry point
```

## Transcription Providers

| Provider | Type | Features |
|----------|------|----------|
| Apple | On-device | 100% private, no internet required |
| Deepgram | Cloud | Speaker diarization, sentiment, summaries |
| AssemblyAI | Cloud | Speaker diarization, chapters, entities |

Configure in Settings (gear icon in menu bar).

## Configuration

Settings are stored in UserDefaults:

| Key | Description |
|-----|-------------|
| `transcriptSaveLocation` | Custom output folder |
| `transcriptionProvider` | "apple", "deepgram", or "assemblyai" |
| `geminiAPIKey` | For action item extraction |
| `taskService` | "reminders" or "todoist" |
| `userName` | Your name for task attribution |

## Privacy & Security

- On-device transcription available (Apple provider)
- Cloud providers only used when explicitly configured
- Audio files deleted after successful transcription
- No analytics or tracking
- All API keys stored locally in UserDefaults

## Troubleshooting

### System Audio Not Capturing

1. Open **System Settings** → **Privacy & Security** → **Screen Recording**
2. Enable access for **Transcripted**
3. Restart the app

### Microphone Not Detected

1. Open **System Settings** → **Privacy & Security** → **Microphone**
2. Enable access for **Transcripted**

### Transcription Failing

- Check your API keys in Settings (for cloud providers)
- Verify internet connection (for cloud providers)
- Check `~/Documents/Transcripted/failed_transcriptions.json` for queued retries

## License

MIT License

---

**Transcripted** - Your meetings, automatically organized.
