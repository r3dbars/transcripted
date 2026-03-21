# Transcripted - AI Agent Navigation Guide

## Project Overview
Menu bar-only macOS app for real-time system audio transcription. Pipeline: CoreAudio capture -> Parakeet STT -> PyAnnote diarization -> WeSpeaker embeddings -> Qwen name inference. Output: Markdown transcripts with YAML frontmatter.

## Architecture
- **App entry**: `TranscriptedApp.swift` (@main) -> `AppDelegate` (slim coordinator with extensions)
- **Activation policy**: `.accessory` (menu bar only, no dock icon)
- **UI**: Floating pill (Dynamic Island style) + Settings window + Onboarding window
- **Dependencies**: mlx-swift-lm (Qwen LLM), Sparkle (auto-updates), FluidAudio (static lib at `fluidaudio-libs/libFluidAudioAll.a`)
- **Protocols**: 7 service protocols in `Services/Protocols/` (SpeechToTextEngine, DiarizationEngine, SpeakerStore, etc.)
- **DI**: `AppServices` container in `Core/AppServices.swift`

## Folder Map (~140 Swift files, agent-first: max ~300 lines per file, single responsibility)
- **Core/** (46 files): Audio capture (Audio + 3 extensions), transcription pipeline (TaskManager + 3 extensions), transcript saving (4 files), stats DB (3 files), failed transcription retry, logging, coordinators (Hotkey, MenuBar, Notification, Window, Recording)
- **Services/** (18 files): ML services (11 files) + Protocols/ subdirectory (7 service protocols)
- **UI/FloatingPanel/** (26 files): Morphing pill UI, aurora visualizations (4 files), transcript tray (3 files), speaker naming (3 files), Components/ (21 files), Helpers/ (1 file)
- **UI/Settings/** (18 files): Settings container + Sections/ (7 section views) + Components/ (6 reusable components) + Models/ (1 file)
- **Onboarding/** (6 files): 3-step first-run flow (Welcome -> Permissions -> Model Setup)
- **Design/** (23 files): Colors/ (6 files), Components/ (7 premium components), root tokens (10 files: Spacing, Radius, Typography, Animations, Shadows, ViewModifiers, Gradients, Dimensions, Accessibility, CardModifiers)

## Build & Test
```bash
xcodebuild -project Transcripted.xcodeproj -scheme Transcripted -configuration Debug build 2>&1
```
Test command: `xcodebuild -project Transcripted.xcodeproj -scheme Transcripted test`

## Critical Rules
1. **No I/O in CoreAudio callbacks** - Real-time audio thread cannot do file/network/lock operations
2. **Audio.swift and SystemAudioCapture.swift are NOT @MainActor** - They manage AVAudioEngine/CoreAudio which require synchronous access from audio threads. They dispatch UI updates to main thread explicitly.
3. **All other services are @MainActor** - ParakeetService, DiarizationService, QwenService, Transcription, TranscriptionTaskManager (exception: SpeakerDatabase uses dedicated utility queue instead)
4. **Never commit to main** - Always create feature branches: `feat/description`, `fix/description`
5. **Branch naming**: `feat/{issue-id}-{slug}` or `fix/{issue-id}-{slug}`

## Recording -> Transcript Pipeline
```
User presses Cmd+Shift+R (global hotkey)
  -> Audio.startRecording() [CoreAudio thread]
  -> onRecordingStart callback -> TaskManager.prepareForRecording()
  -> User stops recording
  -> Audio.stopRecording() -> onRecordingComplete(micURL, systemURL)
  -> TaskManager.startTranscription(micURL, systemURL, outputFolder)
     -> Gate: reject < 2s recordings
     -> Step 1 (0-10%): Resample both to 16kHz mono
     -> Step 2 (10-30%): Offline diarization (PyAnnote) + EmbeddingClusterer post-process
     -> Step 3 (30-65%): Transcribe system segments with Parakeet per speaker
     -> Step 4 (65-90%): Transcribe mic segments per silence region
     -> Step 5 (90-100%): Merge consecutive utterances (1.5s gap, 30s cap)
  -> TranscriptSaver.saveTranscript() writes .md + YAML
  -> AgentOutput.writeTranscriptJSON() writes .json sidecar
  -> FloatingPanel shows success state
```

## Key Entry Points
- **TranscriptedApp.swift**: @main struct + slim AppDelegate coordinator
- **AppDelegate extensions**: MenuBarManager, HotkeyManager, NotificationCoordinator, WindowCoordinator, RecordingCoordinator (in Core/)
- **Core/TranscriptionTaskManager.swift**: Task queue (extensions: QwenLifecycleManager, SpeakerNamingCoordinator, TranscriptionPipelineRunner)
- **Core/DisplayStatus.swift**: DisplayStatus enum + TranscriptionTask struct
- **Core/Audio.swift**: CoreAudio capture (extensions: AudioDeviceRecovery, AudioLevelMonitor, AudioFileManager)
- **Core/Transcription.swift**: @MainActor pipeline (extensions: TranscriptionPipeline, SpeakerMatchingService)
- **Core/AppServices.swift**: DI container with protocol-typed services
- **Services/Protocols/**: 7 service protocols (SpeechToTextEngine, DiarizationEngine, SpeakerStore, etc.)

## Threading Model
- **Audio thread**: Audio.swift + SystemAudioCapture.swift (NOT @MainActor, sync audio access)
- **Main thread**: All UI, Transcription, TaskManager, ParakeetService, DiarizationService, QwenService
- **Utility queue**: SpeakerDatabase (thread-safe SQLite via `DispatchQueue(label: "com.transcripted.speakerdb", qos: .utility)`)
- **Serial queue**: TranscriptSaver file updates, StatsDatabase writes
- **Cross-thread**: Audio dispatches UI updates via `DispatchQueue.main.async`

## Data Storage
- **Transcripts**: `~/Documents/Transcripted/*.md` (Markdown + YAML frontmatter)
- **Agent JSON**: `~/Documents/Transcripted/*.json` (sidecar for each transcript)
- **Speakers DB**: `~/Documents/Transcripted/speakers.sqlite` (256-dim embeddings, profiles)
- **Stats DB**: `~/Documents/Transcripted/stats.sqlite` (recording history, daily activity)
- **Failed queue**: `~/Documents/Transcripted/failed_transcriptions.json`
- **Speaker clips**: `~/Documents/Transcripted/speaker_clips/{speakerId}.wav`
- **Qwen model**: `~/Library/Caches/models/mlx-community/Qwen3.5-4B-4bit` (~2.5GB)
- **Logs**: `~/Library/Logs/Transcripted/app.jsonl` (JSON lines)

## Model Cache
- **Parakeet**: Bundled or downloaded from HuggingFace (~600MB), 16kHz target rate
- **Diarization**: PyAnnote offline + Sortformer streaming, bundled or via FluidAudio
- **Qwen**: On-demand download (~2.5GB), loads/unloads to manage memory

## Documentation
See CONTRIBUTING.md for full development guidelines.
