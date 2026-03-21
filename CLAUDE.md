# Transcripted - AI Agent Navigation Guide

## Project Overview
Real-time system audio transcription app for macOS. Core pipeline: CoreAudio capture → Parakeet STT → PyAnnote diarization → WeSpeaker embeddings → Qwen name inference. Output: Markdown transcripts with YAML metadata.

## Folder Map
- **Core/**: Audio capture, transcription pipeline, task management, SQLite databases (speakers + stats)
- **Services/**: ML services (ParakeetService, DiarizationService, QwenService, SpeakerDatabase, EmbeddingClusterer)
- **UI/**: SwiftUI views, status item, settings, onboarding
- **Onboarding/**: First-run setup, model downloads from HuggingFace (~600MB)
- **Design/**: Shared design tokens, colors, typography

## Build & Test
```bash
xcodebuild -project Transcripted.xcodeproj -scheme Transcripted -configuration Debug build 2>&1
```
Test command: `xcodebuild -project Transcripted.xcodeproj -scheme Transcripted test`

## Critical Rules
1. **No I/O in CoreAudio callbacks** - Real-time audio thread cannot do file/network operations
2. **@MainActor on all services** - UI and service code must run on main thread
3. **Never commit to main** - Always create feature branches: `feat/description`, `fix/description`
4. **Branch naming**: `feat/{issue-id}-{slug}` or `fix/{issue-id}-{slug}`
5. **FluidAudio**: Pre-built static library at `fluidaudio-libs/libFluidAudioAll.a`

## Key Entry Points
- **TranscriptedApp.swift**: App entry point, @main struct
- **AppDelegate.swift**: Status item, menu management, window controllers
- **TranscriptionTaskManager.swift**: Task queue orchestration
- **Audio.swift**: CoreAudio capture pipeline

## Threading Model
- Audio capture runs on CoreAudio callback thread
- All transcription, diarization, and UI code must be @MainActor
- Use DispatchQueue for cross-thread communication

## Model Cache
Models downloaded to app container on first launch. Parakeet (~600MB) + Sortformer diarization model.

## Documentation
See CONTRIBUTING.md for full development guidelines.
