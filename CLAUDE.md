# Transcripted - AI Agent Navigation Guide

## Project Overview
Menu bar-only macOS app for real-time system audio transcription. Pipeline: CoreAudio capture -> Parakeet STT -> PyAnnote diarization -> WeSpeaker embeddings -> Qwen name inference. Output: Markdown transcripts with YAML frontmatter.

## Architecture
- **App entry**: `TranscriptedApp.swift` (@main) -> `AppDelegate` manages all systems
- **Activation policy**: `.accessory` (menu bar only, no dock icon)
- **UI**: Floating pill (Dynamic Island style) + Settings window + Onboarding window
- **Dependencies**: mlx-swift-lm (Qwen LLM), Sparkle (auto-updates), FluidAudio (static lib at `fluidaudio-libs/libFluidAudioAll.a`)

## Folder Map
- **Core/** (23 files): Audio capture, transcription pipeline, task management, transcript saving, stats DB, failed transcription retry, logging, agent JSON output
- **Services/** (8 files): ML services (ParakeetService, DiarizationService, QwenService, SpeakerDatabase, EmbeddingClusterer, AudioResampler, SpeakerClipExtractor, MeetingDetector)
- **UI/FloatingPanel/** (16 files): Morphing pill UI with aurora visualizations, transcript tray, speaker naming dialog
- **UI/Settings/** (4 files): Single-page settings dashboard with reusable components
- **Onboarding/** (6 files): 3-step first-run flow (Welcome -> Permissions -> Model Setup)
- **Design/** (2 files): 84 color tokens, 9 spacing values, 13 radius values, 22 animation presets, premium components

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
- **TranscriptedApp.swift**: @main struct, AppDelegate manages status bar, hotkey (Cmd+Shift+R), window controllers
- **Core/TranscriptionTaskManager.swift**: Task queue orchestration, DisplayStatus for UI, Qwen memory management
- **Core/Audio.swift**: CoreAudio capture, publishes isRecording/audioLevel/recordingDuration
- **Core/Transcription.swift**: @MainActor pipeline orchestration with nonisolated transcription methods

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
