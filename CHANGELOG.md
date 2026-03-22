# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.0] - 2026-03-22

### Added
- **Floating pill redesign** — new saved state notification card (260×56) showing transcript title, duration, and speaker count with Copy/Open actions and 10s auto-dismiss
- **LED audio dot indicators** — coral dot for mic, teal dot for system audio, both glow reactively with audio levels during recording (replaces aurora fog)
- **Preview Transcript onboarding step** — realistic multi-speaker transcript preview with staggered animations before the permissions ask; addresses 38% drop-off at that step
- **Download speed + ETA during onboarding** — model download now shows real-time MB/s and estimated time remaining
- **Structured download errors** — errors classified by type (network, TLS, disk space, timeout) with specific icons and actionable guidance instead of raw error strings
- **Close-during-download confirmation** — closing the onboarding window during an active model download now shows a confirmation dialog
- **HuggingFace mirror fallback** — downloads retry with exponential backoff and automatically fall back to hf-mirror.com when primary CDN is unreachable
- **Pre-flight download checks** — onboarding verifies network connectivity and disk space before starting downloads, fails fast with user-friendly messages
- **Qwen cache pre-population** — Qwen pre-populates its cache directory before mlx-swift-lm attempts its own download, eliminating a class of first-run failures
- **Click-outside tray dismissal** — clicking outside the transcript tray now closes it
- **Simplified transcript footer** — cleaner, less cluttered transcript footer UI

### Fixed
- Processing view replaced with clean progress bar + status text (no more aurora fog during processing)
- Idle pill state shrunk to 52×26 collapsed / 160×36 expanded for less visual intrusion
- Recording pill size matched to idle expanded (160×36) for visual consistency

### Security
- SQL injection prevention in SpeakerDatabase.getColumnNames — table name validated against compile-time allowlist before interpolation
- Path traversal fix in HuggingFace model filename handling — filenames from API response sanitized before use in file paths
- Two additional medium-severity fixes from automated nightly security audit

### Removed
- ~1000 lines of dead code: PillViews, CelebrationViews, WaveformViews, PillIdleView, PillRecordingView, PillProcessingView, AuroraSuccessView


## [0.4.0] - 2026-03-20

### Added
- Smart titles and date separators in transcript tray — recordings show speaker names and time of day
- Menu bar redesign with smart titles, meeting stats, and human-readable labels
- Pill onboarding callout with glow ring for first-time users
- Sentence merging: consecutive utterances from the same speaker with <1.5s gap are merged into single utterances
- Ghost speaker matching threshold (0.92) prevents false matches from low-quality segments
- Save path validation rejects system directories, symlink traversal, and `..` components
- Orphaned audio file cleanup on app launch
- Output length validation after audio resampling

### Fixed
- Notification spam eliminated — recording start/stop no longer fires repeated system alerts
- Audio resampler truncating recordings to 30 seconds (AVAudioConverter terminal state bug)
- Parakeet crash on segments between 0.5-1.0 seconds (minimum raised to 1.0s)
- Qwen memory threshold too high for 16GB machines (4GB → 3GB)
- Qwen timeout firing during long recordings (now deferred until pipeline starts)
- Data races in Audio.swift (5 thread-safety fixes with NSLock)
- SpeakerDatabase silent failures now logged at CRITICAL/WARNING level
- Timer lifecycle in AuroraProcessingView (replaced with SwiftUI Timer.publish)
- Fire-and-forget tasks in recording and naming views now properly cancelled

### Security
- File permissions set to 600 on speakers.sqlite, stats.sqlite, and app.jsonl
- Removed stale API key error handling code
- Added save path validation against traversal attacks

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
