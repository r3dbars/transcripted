# Core Folder

Audio capture pipeline, transcription orchestration, file saving, stats tracking, model downloads, error recovery, and app lifecycle. 47 Swift files (including Logging/).

## File Index

| File | Actor | Purpose |
|------|-------|---------|
| `Audio.swift` | NOT @MainActor | AVAudioEngine setup, recording start/stop, publishes audio levels/state |
| `AudioDeviceRecovery.swift` | NOT @MainActor | Mic watchdog timer, device disconnect recovery, sleep/wake resilience, 0o600 permissions on recovery segments |
| `AudioFileManager.swift` | NOT @MainActor | Audio file creation, WAV writing, buffer copying, format conversion, 0o600 permissions on mic/system files |
| `AudioLevelMonitor.swift` | NOT @MainActor | Audio level metering, silence detection, rolling buffer management |
| `SystemAudioCapture.swift` | NOT @MainActor | CoreAudio process taps (macOS 14.2+), device switching, format negotiation |
| `SystemAudioProcessTap.swift` | NOT @MainActor | CoreAudio process tap creation, aggregate device setup, format negotiation; replaced three force-unwraps of `tapStreamDescription` with safe optional binding to prevent DoS crashes |
| `SystemAudioBufferWriter.swift` | NOT @MainActor | Buffer statistics tracking, device change listener, recovery logic |
| `CoreAudioUtils.swift` | -- | CoreAudio device enumeration helpers |
| `Transcription.swift` | @MainActor | Pipeline orchestration: resample, diarize, transcribe, match speakers |
| `TranscriptionPipeline.swift` | nonisolated | Multichannel transcription pipeline (mic + system audio) |
| `TranscriptionTaskManager.swift` | @MainActor | Task queue, progress tracking, Qwen memory management |
| `TranscriptionPipelineRunner.swift` | nonisolated | Pipeline execution with speaker identification and notification |
| `TranscriptionTypes.swift` | -- | TranscriptionUtterance, TranscriptionResult, PipelineError, SpeakerNamingEntry |
| `DisplayStatus.swift` | -- | Enum for UI progress phases (idle/gettingReady/transcribing/finishing/saved/failed) |
| `SpeakerMatchingService.swift` | nonisolated | In-memory speaker embedding matching, mean embedding computation |
| `SpeakerNamingCoordinator.swift` | @MainActor | Speaker naming flow completion, applies names to DB and transcript, merges profiles by name |
| `QwenLifecycleManager.swift` | @MainActor | Qwen model pre-load on recording start, timeout, memory checks |
| `TranscriptSaver.swift` | Static | Markdown + YAML output, serial queue for file writes, path validation, 0o600 permissions on saved transcript .md files |
| `TranscriptFormatter.swift` | Static | YAML escaping, source label formatting, markdown generation |
| `TranscriptMetadataBuilder.swift` | -- | RecordingHealthInfo struct, YAML frontmatter metadata construction |
| `RetroactiveSpeakerUpdater.swift` | Static | Updates all transcripts when a speaker is renamed in Settings |
| `TranscriptStore.swift` | @MainActor | Reads saved transcripts for tray UI display. SpeakerInfo struct (yamlId, dbId, name) + parseSingle(url:) for external metadata access. |
| `TranscriptExporter.swift` | -- | Export to .md or .txt via NSSavePanel |
| `TranscriptScanner.swift` | -- | Finds transcripts in save directory, migration support |
| `TranscriptUtils.swift` | -- | Formatting utilities |
| `AgentOutput.swift` | Static | JSON sidecar + index for AI agent consumption |
| `StatsDatabase.swift` | NOT @MainActor | SQLite stats DB (serial queue `com.transcripted.statsdb`) |
| `StatsDatabaseModels.swift` | -- | RecordingMetadata, DailyActivity data models |
| `StatsDatabaseQueries.swift` | NOT @MainActor | Complex queries and aggregations for StatsDatabase |
| `StatsService.swift` | @MainActor | Stats aggregation for dashboard UI |
| `ModelDownloadService.swift` | Static | HuggingFace download with mirror fallback (hf-mirror.com), retry with exponential backoff, Qwen cache pre-population, structured error classification (DownloadErrorKind), isSafeModelFilename() path traversal validation |
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
| `Logging/AppLogger.swift` | @unchecked Sendable | Dual logging: os.Logger + FileLogger (JSONL). See Logging/CLAUDE.md |
| `Logging/FileLogger.swift` | -- | JSON line-delimited logs to ~/Library/Logs/Transcripted/ |

## Audio.swift - Published Properties (UI Bindings)
```
@Published isRecording: Bool               // in Audio.swift
@Published isMonitoring: Bool              // in Audio.swift
@Published audioLevel: Float               // 0.0-1.0+ (meter) — updated by AudioLevelMonitor
@Published recordingDuration: TimeInterval // in Audio.swift
@Published audioLevelHistory: [Float]      // 15-element rolling buffer — AudioLevelMonitor
@Published systemAudioLevelHistory: [Float]// AudioLevelMonitor
@Published error: String?                  // in Audio.swift
@Published systemAudioStatus: SystemAudioStatus  // healthy/reconnecting/silent/failed
@Published silenceDuration: TimeInterval   // AudioLevelMonitor
@Published isSilent: Bool                  // audioLevel < 0.02 — AudioLevelMonitor
@Published micAudioFileURL: URL?           // AudioFileManager
@Published systemAudioFileURL: URL?        // AudioFileManager
```

## Audio Recovery Mechanisms (AudioDeviceRecovery.swift)
- **Device disconnect**: Watchdog timer (3-5s) -> `recoverFromDeviceChange()`, max 5 attempts, 5s cooldown
- **Sleep/wake**: NSWorkspace notifications -> proactive recovery after 500ms stabilization
- **System audio loss**: 10s silence -> `.silent` status, 10+ min -> `.failed`
- **Write errors**: Stops recording after 10 consecutive write errors
- **originalMicAudioFileURL vs micAudioFileURL**: During recovery, new WAV segment created. Pipeline MUST use `originalMicAudioFileURL` for transcription.
- **Security**: Recovery segments written with 0o600 permissions (owner-only) to protect biometric voice data

## Audio File Security (AudioFileManager.swift + AudioDeviceRecovery.swift)
- **Issue**: Raw meeting WAV files created with default umask permissions (644), making biometric voice recordings world-readable
- **Fix**: Applied 0o600 permissions immediately after file creation in `AudioFileManager.swift` (mic and system files) and `AudioDeviceRecovery.swift` (recovery segments)
- **Pattern**: Matches existing pattern used by `SpeakerClipExtractor` for speaker clips

## DisplayStatus (DisplayStatus.swift)
```
case idle                           // progress: 0.0
case gettingReady                   // progress: 0.10
case transcribing(progress: Double) // progress: 0.15 + (p * 0.60) = 15-75%
case finishing                      // progress: 0.97
case transcriptSaved                // progress: 1.0
case failed(message: String)        // progress: 0.0
```

## Transcription Pipeline Details (TranscriptionPipeline.swift + TranscriptionPipelineRunner.swift)
```
transcribeMultichannel(micURL, systemURL, onProgress):
  Step 1 (0-10%):   Load & resample both to 16kHz mono (AudioResampler)
  Step 2 (10-30%):  Offline diarization + EmbeddingClusterer.postProcess()
                     -> DB-informed merging, ghost speaker detection
  Step 3 (30-65%):  Transcribe system segments per speaker
                     -> Adaptive threshold matching (1 seg=0.85, 2-3=0.78, 4+=0.70)
                     -> Quality gate: skip segments < 0.3 quality or < 1.0s
                     -> Ghost speakers force-merged into nearest real speaker
  Step 4 (65-90%):  Transcribe mic segments per silence region
                     -> Energy-based silence detection (RMS < 0.01, 25ms frames, 400ms gap)
  Step 5 (90-100%): Merge consecutive utterances (maxGap: 1.5s, maxDuration: 30s cap)
```

## Transcript Output — YAML Frontmatter (TranscriptFormatter.swift + TranscriptMetadataBuilder.swift)
```yaml
---
date: 2024-01-15
time: 14:30:00
duration: "47:32"
processing_time: "120.5s"
transcription_engine: parakeet_local
diarization_engine: pyannote_offline
sources: [mic, system_audio]
mic_utterances: 42
system_utterances: 156
mic_speakers: 1
system_speakers: 4
total_word_count: 8291
capture_quality: excellent|good|fair|degraded
audio_gaps: 0
device_switches: 0
speakers:
  - id: "system_0"
    db_id: "uuid"
    name: "Alice"
    confidence: high|medium
tags: [transcripted, meeting, speaker/alice]  # only if Obsidian enabled
---
```

## StatsDatabase Schema (StatsDatabaseModels.swift + StatsDatabaseQueries.swift)
```sql
-- Table: recordings
id TEXT PRIMARY KEY, date TEXT, time TEXT, duration_seconds INT,
word_count INT, speaker_count INT, processing_time_ms INT,
transcript_path TEXT, title TEXT, created_at TEXT

-- Table: daily_activity
date TEXT PRIMARY KEY, recording_count INT, total_duration_seconds INT,
action_items_count INT, updated_at TEXT
```
WAL mode, busy_timeout 5000ms, NORMAL sync, 0o600 permissions.

## Error Handling (TranscriptionTypes.swift + FailedTranscriptionManager.swift)
- **PipelineError**: Permanent (emptyAudioFile, recordingTooShort, invalidAudioFormat, missingSystemAudio) vs Transient (modelNotLoaded, modelInferenceFailed, saveFailed). `isRetryable` determines retry eligibility.
- **FailedTranscriptionManager**: Auto-deletes permanent errors + retryCount >= 3 on init.
- **Qwen timeout** (QwenLifecycleManager.swift): 5-minute safety timeout if model loaded but not consumed by pipeline.
- **Memory check** (QwenLifecycleManager.swift): Qwen pre-load requires 2GB free (4GB headroom).

## Threading Rules
- **Audio.swift, AudioDeviceRecovery, AudioFileManager, AudioLevelMonitor** -- NOT @MainActor, run on audio threads
- **SystemAudioCapture, SystemAudioProcessTap, SystemAudioBufferWriter** -- NOT @MainActor, CoreAudio threads
- **NO I/O in CoreAudio callbacks** -- file/network/locks will cause audio glitches
- **TranscriptionPipeline, TranscriptionPipelineRunner, SpeakerMatchingService** -- `nonisolated`, offloaded from main thread
- **StatsDatabase, StatsDatabaseQueries** -- Serial queue for SQLite (NOT @MainActor)
- **TranscriptSaver, TranscriptFormatter, RetroactiveSpeakerUpdater** -- Serial queue `com.transcripted.fileupdate`
- **All other managers/coordinators** -- @MainActor

## Logger Subsystems (Logging/AppLogger.swift)
AppLogger.audio, .audioMic, .audioSystem, .transcription, .pipeline, .speakers, .services, .ui, .stats, .app

## Key Extensions (split from original files)
- `Audio.swift` was split into: Audio, AudioDeviceRecovery, AudioFileManager, AudioLevelMonitor
- `SystemAudioCapture.swift` was split into: SystemAudioCapture, SystemAudioProcessTap, SystemAudioBufferWriter
- `TranscriptionTaskManager.swift` was split into: TranscriptionTaskManager, TranscriptionPipelineRunner, QwenLifecycleManager, SpeakerNamingCoordinator
- `Transcription.swift` was split into: Transcription, TranscriptionPipeline, SpeakerMatchingService
- `TranscriptSaver.swift` was split into: TranscriptSaver, TranscriptFormatter, TranscriptMetadataBuilder, RetroactiveSpeakerUpdater
- `StatsDatabase.swift` was split into: StatsDatabase, StatsDatabaseModels, StatsDatabaseQueries
- `AppDelegate` extensions: RecordingCoordinator, MenuBarManager, HotkeyManager, NotificationCoordinator, WindowCoordinator, AppDelegateDebug

## Gotchas
- CoreAudio warnings (HALC_ShellObject, throwing -10877) are harmless internal messages
- SystemAudioCapture.prepare() MUST precede start() - query audioFormat after prepare
- Generation counter in SystemAudioCapture prevents stale delayed cleanup from destroying new sessions
- Recording duration gate: < 2s rejected automatically
- RecordingValidator rejects symlinks, ".." traversals, system directories (/System, /Library, /usr)
