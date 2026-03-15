# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-03-14

### Added

- 100% local transcription using Parakeet TDT V3 (speech-to-text) and Sortformer (speaker diarization) via FluidAudio
- Dual audio capture — microphone and system audio (Zoom, Meet, Teams, etc.)
- Floating pill UI — Dynamic Island-style interface with recording, processing, and celebration states
- Automatic meeting detection — starts recording when bidirectional audio is detected
- Persistent speaker identification via 256-dimensional voice embeddings stored in SQLite
- On-device speaker name inference using Qwen 3.5-4B
- Markdown transcript output with YAML frontmatter, timestamps, and speaker labels
- Auto-save to ~/Documents/Transcripted/
- Transcript export (Markdown and plain text)
- First-run onboarding flow with permissions setup
- Settings window for configuration
- Global hotkey support
- Failed transcription queue with automatic retries
- Recording statistics tracking

### Technical

- Built with Swift 5.9+ and SwiftUI, targeting macOS 14.2+
- CoreAudio process taps for system audio capture
- Neural Engine acceleration for ML model inference
- SQLite-backed speaker database and stats persistence
- JSON Lines logging to ~/Library/Logs/Transcripted/

[0.1.0]: https://github.com/r3dbars/transcripted/releases/tag/v0.1.0
