# Core Folder

Audio capture pipeline, transcription orchestration, file saving, stats tracking, error recovery, and app lifecycle. 46 Swift files (including Logging/).

## File Index

| File | Actor | Purpose |
|------|-------|---------|
| `Audio.swift` | NOT @MainActor | AVAudioEngine setup, recording start/stop, publishes audio levels/state |
| `AudioDeviceRecovery.swift` | NOT @MainActor | Mic watchdog timer, device disconnect recovery, sleep/wake resilience |
| `AudioFileManager.swift` | NOT @MainActor | Audio file creation, WAV writing, buffer copying, format conversion |
| `AudioLevelMonitor.swift` | NOT @MainActor | Audio level metering, silence detection, rolling buffer management |
| `SystemAudioCapture.swift` | NOT @MainActor | CoreAudio process taps (macOS 14.2+), device switching, format negotiation |
| `SystemAudioProcessTap.swift` | NOT @MainActor | CoreAudio process tap creation, aggregate device setup |
| `SystemAudioBufferWriter.swift` | NOT @MainActor | Buffer statistics tracking, device change listener, recovery logic |
| `CoreAudioUtils.swift` | -- | CoreAudio device enumeration helpers |
| `Transcription.swift` | @MainActor | Pipeline orchestration: resample, diarize, transcribe, match speakers |
| `TranscriptionPipeline.swift` | nonisolated | Multichannel transcription pipeline (mic + system audio) |
| `TranscriptionTaskManager.swift` | @MainActor | Task queue, progress tracking, Qwen memory management |
| `TranscriptionPipelineRunner.swift` | nonisolated | Pipeline execution with speaker identification and notification |
| `TranscriptionTypes.swift` | -- | TranscriptionUtterance, TranscriptionResult, PipelineError, SpeakerNamingEntry |
| `DisplayStatus.swift` | -- | Enum for UI progress phases (idle/gettingReady/transcribing/finishing/saved/failed) |
| `SpeakerMatchingService.swift` | nonisolated | In-memory speaker embedding matching, mean embedding computation |
| `SpeakerNamingCoordinator.swift` | @MainActor | Speaker naming flow completion, applies names to DB and transcript |
| `QwenLifecycleManager.swift` | @MainActor | Qwen model pre-load on recording start, timeout, memory checks |
| `TranscriptSaver.swift` | Static | Markdown + YAML output, serial queue for file writes |
| `TranscriptFormatter.swift` | Static | YAML escaping, source label formatting, markdown generation |
| `TranscriptMetadataBuilder.swift` | -- | RecordingHealthInfo struct, YAML frontmatter metadata construction |
| `RetroactiveSpeakerUpdater.swift` | Static | Updates all transcripts when a speaker is renamed in Settings |
| `TranscriptStore.swift` | @MainActor | Reads saved transcripts for tray UI display |
| `TranscriptExporter.swift` | -- | Export to .md or .txt via NSSavePanel |
| `TranscriptScanner.swift` | -- | Finds transcripts in save directory, migration support |
| `TranscriptUtils.swift` | -- | Formatting utilities |
| `AgentOutput.swift` | Static | JSON sidecar + index for AI agent consumption |
| `StatsDatabase.swift` | NOT @MainActor | SQLite stats DB (serial queue `com.transcripted.statsdb`) |
| `StatsDatabaseModels.swift` | -- | RecordingMetadata, DailyActivity data models |
| `StatsDatabaseQueries.swift` | NOT @MainActor | Complex queries and aggregations for StatsDatabase |
| `StatsService.swift` | @MainActor | Stats aggregation for dashboard UI |
| `RecordingValidator.swift` | Static | Pre-recording checks (disk space, permissions, save path) |
| `FailedTranscription.swift` | -- | Model for retryable failed transcriptions |
| `FailedTranscriptionManager.swift` | @MainActor | Retry queue, persists to JSON, auto-cleans permanent failures |
| `AppServices.swift` | @MainActor | Dependency injection container holding protocol-typed service instances |
| `RecordingCoordinator.swift` | @MainActor | Recording lifecycle (toggle, completion handler, orphaned file cleanup) |
| `MenuBarManager.swift` | @MainActor | Status bar menu setup and management (AppDelegate extension) |
| `HotkeyManager.swift` | @MainActor | Global Cmd+Shift+R hotkey registration (AppDelegate extension) |
| `NotificationCoordinator.swift` | @MainActor | UNUserNotificationCenter categories, permissions, delegate handling |
| `WindowCoordinator.swift` | @MainActor | Window lifecycle (settings, onboarding, panel visibility) |
| `AppDelegateDebug.swift` | @MainActor | DEBUG-only helpers (reset onboarding, test naming tray) |
| `DiagnosticExporter.swift` | -- | Diagnostic bundle export for bug reports |
| `Clipboard.swift` | -- | Clipboard management |
| `DateFormattingHelper.swift` | -- | Date formatting utilities |
| `DateParser.swift` | -- | Date parsing utilities |
| `Logging/AppLogger.swift` | @unchecked Sendable | Dual logging: os.Logger + FileLogger (JSONL) |
| `Logging/FileLogger.swift` | -- | JSON line-delimited logs to ~/Library/Logs/Transcripted/ |

## Threading Rules

- **Audio.swift, AudioDeviceRecovery, AudioFileManager, AudioLevelMonitor** -- NOT @MainActor, run on audio threads
- **SystemAudioCapture, SystemAudioProcessTap, SystemAudioBufferWriter** -- NOT @MainActor, CoreAudio threads
- **NO I/O in CoreAudio callbacks** -- file/network/locks will cause audio glitches
- **TranscriptionPipeline, TranscriptionPipelineRunner, SpeakerMatchingService** -- `nonisolated`, offloaded from main thread
- **StatsDatabase, StatsDatabaseQueries** -- Serial queue for SQLite (NOT @MainActor)
- **TranscriptSaver, TranscriptFormatter, RetroactiveSpeakerUpdater** -- Serial queue `com.transcripted.fileupdate`
- **All other managers/coordinators** -- @MainActor

## Key Extensions (split from original files)

- `Audio.swift` was split into: Audio, AudioDeviceRecovery, AudioFileManager, AudioLevelMonitor
- `SystemAudioCapture.swift` was split into: SystemAudioCapture, SystemAudioProcessTap, SystemAudioBufferWriter
- `TranscriptionTaskManager.swift` was split into: TranscriptionTaskManager, TranscriptionPipelineRunner, QwenLifecycleManager, SpeakerNamingCoordinator
- `Transcription.swift` was split into: Transcription, TranscriptionPipeline, SpeakerMatchingService
- `TranscriptSaver.swift` was split into: TranscriptSaver, TranscriptFormatter, TranscriptMetadataBuilder, RetroactiveSpeakerUpdater
- `StatsDatabase.swift` was split into: StatsDatabase, StatsDatabaseModels, StatsDatabaseQueries
- `AppDelegate` extensions: RecordingCoordinator, MenuBarManager, HotkeyManager, NotificationCoordinator, WindowCoordinator, AppDelegateDebug
