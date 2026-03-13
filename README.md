# Transcripted

A native macOS app that automatically records, transcribes, and organizes voice conversations from meetings and calls. Built with Swift, SwiftUI, using **Parakeet TDT V3** and **Sortformer** for 100% local transcription with speaker diarization — no cloud API, no internet required.

## Features

**Recording & Transcription**
- Floating pill UI - Dynamic Island-style interface that doesn't interrupt your workflow
- Dual audio capture - Records both microphone and system audio (Zoom, Meet, Teams, etc.)
- Local transcription - Parakeet TDT V3 (speech-to-text) + Sortformer (speaker diarization), runs on Neural Engine
- Persistent speaker matching - Learns voices over time via 256-dim embeddings
- Real-time status - Visual feedback during recording and processing

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
open Transcripted.xcodeproj

# Or build from command line
xcodebuild -project Transcripted.xcodeproj -scheme Transcripted -configuration Debug build

# Build for release
xcodebuild -project Transcripted.xcodeproj -scheme Transcripted -configuration Release build
```

## Permissions

On first launch, Transcripted requests:

| Permission | Purpose | Required |
|------------|---------|----------|
| Microphone | Capture your voice | Yes |
| Screen Recording | Capture system audio from meetings | For system audio |
| Reminders | Optional integration | Optional |

## Architecture

```
Transcripted/
├── Core/                                  # Business logic (21 files)
│   ├── Audio.swift                        # Microphone capture via AVAudioEngine
│   ├── SystemAudioCapture.swift           # System audio via CoreAudio process taps
│   ├── Transcription.swift                # Local transcription (Parakeet + Sortformer)
│   ├── TranscriptionTaskManager.swift     # Background transcription queue
│   ├── DateParser.swift                   # Natural language date parsing
│   ├── TranscriptSaver.swift              # Markdown output
│   ├── TranscriptScanner.swift            # Transcript file discovery & parsing
│   ├── StatsDatabase.swift                # SQLite stats persistence
│   ├── StatsService.swift                 # Recording & transcription statistics
│   └── ...                                # Additional core utilities
│
├── Services/                              # Local engines + external integrations
│   ├── ParakeetService.swift              # Local STT via FluidAudio
│   ├── SortformerService.swift            # Local speaker diarization
│   ├── SpeakerDatabase.swift              # Persistent voice fingerprints (SQLite)
│   ├── AudioResampler.swift               # Audio resampling + WAV loading
│   ├── QwenService.swift                  # Local Qwen model for speaker inference
│   ├── EmbeddingClusterer.swift           # Voice embedding clustering
│   └── SpeakerClipExtractor.swift         # Speaker audio clip extraction
│
├── UI/
│   ├── FloatingPanel/                     # Floating pill UI
│   │   ├── FloatingPanelController.swift  # Window management
│   │   ├── FloatingPanelView.swift        # Main SwiftUI view
│   │   ├── PillStateManager.swift         # State machine
│   │   └── Components/                    # 10 component files
│   │       ├── PillViews.swift            # Idle, Recording, Processing states
│   │       ├── WaveformViews.swift        # Audio visualizers
│   │       ├── CelebrationViews.swift     # Success animations
│   │       ├── ErrorViews.swift           # Error handling UI
│   │       ├── AttentionPromptView.swift  # Notifications
│   │       ├── SpeakerNamingView.swift    # Speaker identification
│   │       └── ...                        # Additional components
│   │
│   └── Settings/                          # Settings window
│       ├── SettingsWindowController.swift  # Window management
│       ├── SettingsContainerView.swift     # Single-page scrolling layout
│       ├── SettingsSidebarView.swift       # Sidebar navigation
│       ├── Components/
│       │   └── SettingsSectionCard.swift   # Reusable card component
│       └── Models/
│           └── SettingsNavigationState.swift  # Tab state
│
├── Design/
│   ├── DesignTokens.swift                 # Colors, spacing, animations
│   └── PremiumComponents.swift            # Shared UI components
│
├── Onboarding/                            # First-run experience (4 steps)
│   ├── OnboardingState.swift              # State management
│   ├── OnboardingContainerView.swift      # Container view
│   ├── OnboardingWindow.swift             # Window controller
│   ├── Steps/
│   │   ├── WelcomeStep.swift
│   │   ├── HowItWorksStep.swift
│   │   ├── PermissionsStep.swift
│   │   └── ReadyStep.swift
│   └── Animations/
│       └── ParticleExplosionView.swift    # Celebration effects
│
└── TranscriptedApp.swift                  # App entry point
```

## Transcription

All transcription runs **100% locally** on your Mac — no cloud API, no internet, no per-call cost:

- **Parakeet TDT V3** - NVIDIA's CoreML speech-to-text model (~600MB, runs on Neural Engine)
- **Sortformer** - NVIDIA's CoreML speaker diarization (identifies who speaks when)
- **Voice fingerprints** - WeSpeaker 256-dim embeddings stored in SQLite, learns voices over time
- **Per-segment transcription** - Sortformer identifies speaker segments, Parakeet transcribes each individually

Models are downloaded from HuggingFace on first launch if not bundled in the app.

## Configuration

Settings are stored in UserDefaults:

| Key | Description |
|-----|-------------|
| `transcriptSaveLocation` | Custom output folder |
| `userName` | Your name for speaker attribution |
| `enableUISounds` | Enable/disable UI sound effects |
| `useAuroraRecording` | Use Aurora recording mode |
| `enableQwenSpeakerInference` | Enable Qwen-based speaker name inference |

## Privacy & Security

- **100% local processing** — no API keys, no cloud services, no data leaves your Mac
- Audio files deleted after successful transcription
- No analytics or tracking
- Transcripts saved locally to `~/Documents/Transcripted/`

## Troubleshooting

### System Audio Not Capturing

1. Open **System Settings** → **Privacy & Security** → **Screen Recording**
2. Enable access for **Transcripted**
3. Restart the app

### Microphone Not Detected

1. Open **System Settings** → **Privacy & Security** → **Microphone**
2. Enable access for **Transcripted**

### Transcription Failing

- Check that Parakeet + Sortformer models loaded successfully (Settings → AI Services)
- Models download on first launch — ensure internet for initial setup
- Check `~/Documents/Transcripted/failed_transcriptions.json` for queued retries
- Ensure appropriate audio capture permissions are granted

## Contributing

1. Fork the repo and create your branch from `main`
2. Open `Transcripted.xcodeproj` in Xcode
3. Set your own **Development Team** in the Signing & Capabilities tab (the project has a placeholder team ID)
4. Build and run

The FluidAudio static library (`fluidaudio-libs/libFluidAudioAll.a`) is pre-built and included in the repo. If you need to rebuild it, run `./build-fluidaudio.sh`.

---

**Transcripted** - Your meetings, automatically organized.
