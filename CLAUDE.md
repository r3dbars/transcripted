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

**Transcripted** is a native macOS application that automatically records, transcribes, and organizes voice conversations from meetings and calls. The app uses **Parakeet TDT V3** (local CoreML speech-to-text) and **Sortformer** (local CoreML speaker diarization) via the FluidAudio library — all transcription runs 100% on-device with no cloud API or internet required. It extracts action items from transcripts using Gemini AI and sends them to Apple Reminders or Todoist.

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

Murmur/Core/Transcription.swift      → Local transcription via Parakeet + Sortformer
                                     → Diarizes system audio, transcribes per-segment
                                     → Speaker matching via persistent voice database

Murmur/Core/TranscriptSaver.swift    → Outputs markdown with YAML frontmatter
                                     → Saves to ~/Documents/Transcripted/
```

### Transcription Engine (Local)

The app uses **FluidAudio** for 100% local transcription — no cloud API, no internet, no cost:

| Component | Model | Purpose |
|-----------|-------|---------|
| Speech-to-text | Parakeet TDT V3 (~600MB CoreML) | Transcribes audio to text on Neural Engine |
| Speaker diarization | Sortformer (~CoreML) | Identifies who speaks when in system audio |
| Voice fingerprints | WeSpeaker (256-dim embeddings) | Persistent speaker matching across sessions |

**Services:** `Murmur/Services/ParakeetService.swift`, `Murmur/Services/SortformerService.swift`
**Database:** `Murmur/Services/SpeakerDatabase.swift` (SQLite, voice embeddings)
**Resampler:** `Murmur/Services/AudioResampler.swift` (48kHz → 16kHz for model input)

**Pipeline:** Record → Sortformer diarizes system audio → Parakeet transcribes each speaker segment → Parakeet transcribes mic → Match speakers to database → Merge utterances chronologically

**Note:** Models are downloaded from HuggingFace on first launch if not bundled. System audio capture requires appropriate permissions.

### State Management

```
TranscriptedApp.swift (AppDelegate)
├── Audio                    → Recording state, audio levels
├── TranscriptionTaskManager → Background transcription queue, progress tracking
├── FailedTranscriptionManager → Retry queue with persistent storage
├── FailedActionItemManager  → Retry queue for failed action item delivery
├── RecordingValidator       → Pre-recording system checks
├── StatsService             → Recording statistics and streak tracking
├── StatsDatabase            → SQLite persistence for stats
└── FloatingPanelController  → UI coordination
```

### Action Item Pipeline

When enabled, transcripts are processed for action items:
```
Murmur/Core/ActionItemExtractor.swift → Sends transcript to Gemini 2.5 Pro API (two-pass pipeline)
                                      → Pass 1: Speaker identification
                                      → Pass 2: Action item extraction (tasks, owners, priorities, due dates)

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
│   ├── ReviewTrayView.swift        # Action item review tray
│   ├── AuroraIdleView.swift        # Aurora animation for idle state
│   ├── AuroraRecordingView.swift   # Aurora animation for recording state
│   ├── AuroraProcessingView.swift  # Aurora animation for processing state
│   └── AuroraSuccessView.swift     # Aurora animation for success state
└── Helpers/
    └── LawsComponents.swift        # Reusable UI primitives (buttons, status text)
```

Settings window (`Murmur/UI/Settings/`):
```
Settings/
├── SettingsWindowController.swift          # NSWindowController, 800x600 fixed window
├── SettingsContainerView.swift             # Sidebar + content layout
├── SettingsSidebarView.swift               # Left sidebar navigation
├── Models/
│   └── SettingsNavigationState.swift       # Tab state (Dashboard, Preferences)
├── Tabs/
│   ├── DashboardView.swift                 # Stats, recent transcripts
│   └── PreferencesView.swift               # Storage, model status, task service, appearance
└── Components/
    ├── RecentTranscriptsView.swift          # Recent transcript list
    └── SettingsSectionCard.swift            # Reusable card component
```

Other UI files:
- **ActionItemReviewView** (`Murmur/UI/ActionItemReviewView.swift`) - Task approval workflow
- **FailedTranscriptionsView** (`Murmur/UI/FailedTranscriptionsView.swift`) - UI for retry queue management

### Onboarding Flow

Four-step onboarding managed by `Murmur/Onboarding/OnboardingState.swift`:
1. Welcome → 2. How It Works → 3. Permissions → 4. Ready

Permissions requested: Microphone (required), Screen Recording (for system audio), Reminders (optional)

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
| `geminiAPIKey` | Gemini API key for action item extraction |
| `taskService` | "reminders" or "todoist" |
| `todoistAPIKey` | Todoist API key (if using Todoist) |
| `userName` | User's name for action item attribution |
| `hasCompletedOnboarding` | Onboarding completion flag |
| `remindersListId` | Selected Apple Reminders list ID |
| `enableUISounds` | Enable/disable recording sounds |
| `useAuroraRecording` | Enable aurora animation |
| `floatingPanelX` | Saved pill X position |
| `floatingPanelY` | Saved pill Y position |

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
- `AudioHardwareCreateProcessTap` API for system audio capture

### Audio Format Handling
- Mic audio: Uses hardware format from `inputNode.inputFormat(forBus: 1)` (NOT `outputFormat`)
- System audio: Native 48kHz (tap claims 96kHz but actual rate is 48kHz)
- Transcription: Resampled to 16kHz mono for Parakeet/Sortformer input

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

### Local Model Loading
- **Parakeet + Sortformer**: Models loaded from app bundle on launch, or downloaded from HuggingFace on first run
- Model states: `.notLoaded` → `.loading` → `.ready` (or `.failed`)
- Initialization triggered in `setupApp()` via `taskManager?.transcription.initializeModels()`

## File Organization

```
Murmur/
├── Core/
│   ├── Logging/
│   │   ├── AppLogger.swift        # Unified logging (os.Logger + JSON Lines file)
│   │   └── FileLogger.swift       # Rolling JSON Lines logger at ~/Library/Logs/
│   ├── Audio.swift                # Microphone capture via AVAudioEngine
│   ├── SystemAudioCapture.swift   # System audio via CoreAudio process taps
│   ├── Transcription.swift        # Local transcription via Parakeet + Sortformer
│   ├── TranscriptionTypes.swift   # Engine-agnostic result types (TranscriptionResult, etc.)
│   ├── TranscriptionTaskManager.swift  # Background transcription queue
│   ├── TranscriptSaver.swift      # Markdown output with YAML frontmatter
│   ├── TranscriptScanner.swift    # Transcript file discovery
│   ├── TranscriptUtils.swift      # Transcript helper utilities
│   ├── ActionItemExtractor.swift  # Gemini AI two-pass action item pipeline
│   ├── DateParser.swift           # Natural language date parsing
│   ├── DateFormattingHelper.swift # Date formatting utilities
│   ├── Clipboard.swift            # Clipboard operations
│   ├── CoreAudioUtils.swift       # CoreAudio helper utilities
│   ├── RecordingValidator.swift   # Pre-recording system checks
│   ├── FailedTranscription.swift  # Failed transcription model
│   ├── FailedTranscriptionManager.swift  # Retry queue with persistent storage
│   ├── FailedActionItemManager.swift     # Retry queue for failed action items
│   ├── ServiceResult.swift        # Generic service result type
│   ├── StatsService.swift         # Recording statistics and streak tracking
│   └── StatsDatabase.swift        # SQLite persistence for stats
├── Design/                        # Visual design system
│   ├── DesignTokens.swift         # Colors, spacing, animation presets
│   └── PremiumComponents.swift    # Reusable premium UI components
├── Onboarding/                    # Four-step onboarding flow
│   ├── OnboardingState.swift      # State management for onboarding
│   ├── OnboardingContainerView.swift  # Container view for steps
│   ├── OnboardingWindow.swift     # Onboarding window controller
│   ├── Steps/
│   │   ├── WelcomeStep.swift      # Step 1: Welcome
│   │   ├── HowItWorksStep.swift   # Step 2: How It Works
│   │   ├── PermissionsStep.swift  # Step 3: Permissions
│   │   └── ReadyStep.swift        # Step 4: Ready
│   └── Animations/
│       └── ParticleExplosionView.swift  # Celebration particle effects
├── Services/                      # Local engines + external integrations
│   ├── ParakeetService.swift      # Local STT via FluidAudio (Parakeet TDT V3)
│   ├── SortformerService.swift    # Local speaker diarization via FluidAudio
│   ├── SpeakerDatabase.swift      # Persistent voice fingerprints (SQLite + 256-dim embeddings)
│   ├── AudioResampler.swift       # Audio resampling (48kHz → 16kHz) and WAV loading
│   ├── RemindersService.swift     # Apple Reminders integration
│   └── TodoistService.swift       # Todoist API integration
├── UI/
│   ├── FloatingPanel/             # Floating pill UI
│   │   ├── FloatingPanelController.swift  # NSWindowController
│   │   ├── FloatingPanelView.swift        # Main SwiftUI composition
│   │   ├── PillStateManager.swift         # State machine
│   │   ├── Components/
│   │   │   ├── PillViews.swift            # Pill state views
│   │   │   ├── WaveformViews.swift        # Audio visualizers
│   │   │   ├── CelebrationViews.swift     # Success animations
│   │   │   ├── ErrorViews.swift           # Error banners
│   │   │   ├── AttentionPromptView.swift  # Silence warning
│   │   │   ├── ReviewTrayView.swift       # Action item review tray
│   │   │   ├── AuroraIdleView.swift       # Aurora idle animation
│   │   │   ├── AuroraRecordingView.swift  # Aurora recording animation
│   │   │   ├── AuroraProcessingView.swift # Aurora processing animation
│   │   │   └── AuroraSuccessView.swift    # Aurora success animation
│   │   └── Helpers/
│   │       └── LawsComponents.swift       # Reusable UI primitives
│   ├── Settings/                  # Settings sidebar+tabs system
│   │   ├── SettingsWindowController.swift  # NSWindowController, 800x600
│   │   ├── SettingsContainerView.swift     # Sidebar + content layout
│   │   ├── SettingsSidebarView.swift       # Left sidebar navigation
│   │   ├── Models/
│   │   │   └── SettingsNavigationState.swift  # Tab state
│   │   ├── Tabs/
│   │   │   ├── DashboardView.swift        # Stats, recent transcripts
│   │   │   └── PreferencesView.swift      # API keys, storage, appearance
│   │   └── Components/
│   │       ├── RecentTranscriptsView.swift # Recent transcript list
│   │       └── SettingsSectionCard.swift   # Reusable card component
│   ├── ActionItemReviewView.swift # Task approval workflow
│   └── FailedTranscriptionsView.swift  # Retry queue management UI
├── TranscriptedApp.swift          # App entry point (AppDelegate pattern)
└── Transcripted.entitlements
```

## Logging

**Log file:** `~/Library/Logs/Transcripted/app.jsonl`
**Format:** JSON Lines (one JSON object per line)
**Max entries:** 2000 (rolling, trims oldest 500 when full)
**Read logs:** `Read ~/Library/Logs/Transcripted/app.jsonl`
**Filter by subsystem:** `Grep` for `"s":"audio.mic"` etc.

**Subsystems:**

| Subsystem | Covers |
|-----------|--------|
| `audio` | General audio start/stop, sleep/wake |
| `audio.mic` | Mic capture, device switches, recovery |
| `audio.system` | System audio tap, buffers, device changes |
| `transcription` | Parakeet/Sortformer model loading, STT/diarization |
| `pipeline` | Task lifecycle, saving, file management, retries |
| `speaker-db` | Speaker matching, voice embeddings, merges |
| `action-items` | Gemini extraction, review, task delivery |
| `services` | Reminders/Todoist API calls |
| `ui` | Pill state transitions, UI events |
| `stats` | Recording statistics, database operations |
| `app` | App lifecycle, model initialization |

**For ANY runtime issue: Read the log file first.**

## Agent Task Routing

Read the component CLAUDE.md in the relevant folder FIRST:

| Issue domain | Read first |
|-------------|------------|
| Audio/recording issues | `Murmur/Core/CLAUDE.md` |
| Transcription/STT issues | `Murmur/Services/CLAUDE.md` |
| Speaker ID issues | `Murmur/Services/CLAUDE.md` |
| Pipeline/saving issues | `Murmur/Core/CLAUDE.md` |
| UI/settings issues | `Murmur/UI/CLAUDE.md` |
| Floating pill issues | `Murmur/UI/FloatingPanel/CLAUDE.md` |
| Design system changes | `Murmur/Design/CLAUDE.md` |
| Onboarding flow | `Murmur/Onboarding/CLAUDE.md` |

## Component Dependencies

```
TranscriptedApp.swift (entry point)
├── Core/Audio.swift + Core/SystemAudioCapture.swift
├── Core/TranscriptionTaskManager.swift
│   ├── Core/Transcription.swift
│   │   ├── Services/ParakeetService.swift
│   │   ├── Services/SortformerService.swift
│   │   └── Services/SpeakerDatabase.swift
│   ├── Core/TranscriptSaver.swift
│   └── Core/ActionItemExtractor.swift
│       ├── Services/RemindersService.swift
│       └── Services/TodoistService.swift
├── UI/FloatingPanel/FloatingPanelController.swift
└── UI/Settings/SettingsWindowController.swift
```
