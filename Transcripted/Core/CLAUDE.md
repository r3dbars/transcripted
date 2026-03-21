# Core Folder

Audio capture pipeline, transcription orchestration, file saving, stats tracking, and error recovery. 23 Swift files.

## File Index

| File | Actor | Purpose |
|------|-------|---------|
| `Audio.swift` | NOT @MainActor | AVAudioEngine + SystemAudioCapture, publishes audio levels/state, device recovery |
| `SystemAudioCapture.swift` | NOT @MainActor | CoreAudio process taps (macOS 14.2+), device switching, format negotiation |
| `Transcription.swift` | @MainActor | Pipeline orchestration: Parakeet -> PyAnnote -> WeSpeaker -> speaker matching |
| `TranscriptionTaskManager.swift` | @MainActor | Task queue, DisplayStatus for UI progress, Qwen memory management |
| `TranscriptionTypes.swift` | — | TranscriptionUtterance, TranscriptionResult, PipelineError, SpeakerNamingEntry |
| `TranscriptSaver.swift` | Static | Markdown + YAML output, retroactive speaker name updates |
| `TranscriptStore.swift` | @MainActor | Reads saved transcripts for tray UI display |
| `TranscriptExporter.swift` | — | Export to .md or .txt via NSSavePanel |
| `TranscriptScanner.swift` | — | Finds transcripts in save directory, migration support |
| `TranscriptUtils.swift` | — | Formatting utilities |
| `StatsDatabase.swift` | NOT @MainActor | SQLite stats (serial queue `com.transcripted.statsdb`) |
| `StatsService.swift` | @MainActor | Stats aggregation for dashboard UI |
| `AgentOutput.swift` | Static | JSON sidecar + index for AI agent consumption |
| `RecordingValidator.swift` | Static | Pre-recording checks (disk space, permissions, save path) |
| `FailedTranscription.swift` | — | Model for retryable failed transcriptions |
| `FailedTranscriptionManager.swift` | @MainActor | Retry queue, persists to JSON, auto-cleans permanent failures |
| `DiagnosticExporter.swift` | — | Diagnostic bundle export for bug reports |
| `Clipboard.swift` | — | Clipboard management |
| `CoreAudioUtils.swift` | — | CoreAudio device enumeration helpers |
| `DateFormattingHelper.swift` | — | Date formatting utilities |
| `DateParser.swift` | — | Date parsing utilities |
| `Logging/AppLogger.swift` | @unchecked Sendable | Dual logging: os.Logger + FileLogger (JSONL) |
| `Logging/FileLogger.swift` | — | JSON line-delimited logs to ~/Library/Logs/Transcripted/ |

## Audio.swift - Published Properties (UI Bindings)
```
@Published isRecording: Bool
@Published isMonitoring: Bool
@Published audioLevel: Float              // 0.0-1.0+ (meter)
@Published recordingDuration: TimeInterval
@Published audioLevelHistory: [Float]     // 15-element rolling buffer
@Published systemAudioLevelHistory: [Float]
@Published error: String?
@Published systemAudioStatus: SystemAudioStatus  // healthy/reconnecting/silent/failed
@Published silenceDuration: TimeInterval
@Published isSilent: Bool                 // audioLevel < 0.02
@Published micAudioFileURL: URL?
@Published systemAudioFileURL: URL?
```

## Audio Recovery Mechanisms
- **Device disconnect**: Watchdog timer (3-5s) -> `recoverFromDeviceChange()`, max 5 attempts, 5s cooldown
- **Sleep/wake**: NSWorkspace notifications -> proactive recovery after 500ms stabilization
- **System audio loss**: 10s silence -> `.silent` status, 10+ min -> `.failed`
- **Write errors**: Stops recording after 10 consecutive write errors
- **originalMicAudioFileURL vs micAudioFileURL**: During recovery, new WAV segment created. Pipeline MUST use `originalMicAudioFileURL` for transcription.

## DisplayStatus (TranscriptionTaskManager)
```
case idle                           // progress: 0.0
case gettingReady                   // progress: 0.10
case transcribing(progress: Double) // progress: 0.15 + (p * 0.60) = 15-75%
case finishing                      // progress: 0.97
case transcriptSaved                // progress: 1.0
case failed(message: String)        // progress: 0.0
```

## Transcription Pipeline Details
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

## Transcript Output (YAML Frontmatter)
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

## StatsDatabase Schema
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

## Error Handling
- **PipelineError**: Permanent (emptyAudioFile, recordingTooShort, invalidAudioFormat, missingSystemAudio) vs Transient (modelNotLoaded, modelInferenceFailed, saveFailed). `isRetryable` determines retry eligibility.
- **FailedTranscriptionManager**: Auto-deletes permanent errors + retryCount >= 3 on init.
- **Qwen timeout**: 5-minute safety timeout if model loaded but not consumed by pipeline.
- **Memory check**: Qwen pre-load requires 2GB free (4GB headroom).

## Threading Rules
- **Audio.swift & SystemAudioCapture.swift are NOT @MainActor** - manage real-time audio threads
- **NO I/O in CoreAudio callbacks** - file/network/locks will cause audio glitches
- **Transcription pipeline methods are `nonisolated`** - offloaded from main thread
- **StatsDatabase**: Serial queue for SQLite (NOT @MainActor)
- **TranscriptSaver**: Serial queue `com.transcripted.fileupdate` prevents concurrent writes

## Logger Subsystems
AppLogger.audio, .audioMic, .audioSystem, .transcription, .pipeline, .speakers, .services, .ui, .stats, .app

## Gotchas
- CoreAudio warnings (HALC_ShellObject, throwing -10877) are harmless internal messages
- SystemAudioCapture.prepare() MUST precede start() - query audioFormat after prepare
- Generation counter in SystemAudioCapture prevents stale delayed cleanup from destroying new sessions
- Recording duration gate: < 2s rejected automatically
- RecordingValidator rejects symlinks, ".." traversals, system directories (/System, /Library, /usr)
