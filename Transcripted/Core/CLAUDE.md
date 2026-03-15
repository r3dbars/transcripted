# Core — CLAUDE.md

## Purpose
Audio capture, transcription pipeline, task management, transcript saving, statistics, and logging. The engine room of Transcripted — everything runs 100% locally.

## Files

| File | Responsibility | Threading |
|---|---|---|
| `Audio.swift` | Mic capture via AVAudioEngine, WAV writing, silence detection | class (ObservableObject, manages real-time audio threads) |
| `SystemAudioCapture.swift` | System audio via CoreAudio process taps, aggregate device | class (ObservableObject, NOT @MainActor, DispatchQueue + NSLock) |
| `Transcription.swift` | Orchestrates Parakeet STT + Sortformer diarization + speaker matching | @MainActor, nonisolated for heavy compute |
| `TranscriptionTaskManager.swift` | Background transcription queue, progress tracking, speaker naming flow | @MainActor |
| `TranscriptionTypes.swift` | Engine-agnostic types: TranscriptionResult, SpeakerNamingRequest, etc. | Value types |
| `TranscriptSaver.swift` | Markdown output with YAML frontmatter, retroactive speaker updates | Static methods |
| `TranscriptStore.swift` | ObservableObject for transcript tray (recent 10, copy-to-clipboard) | @MainActor |
| `TranscriptScanner.swift` | Transcript file discovery & parsing | Static methods |
| `TranscriptUtils.swift` | Summary updates, file renaming | Static methods |
| `RecordingValidator.swift` | Pre-recording checks: disk space, permissions, devices, save path validation | Static methods |
| `FailedTranscriptionManager.swift` | Persistent retry queue (JSON at ~/Documents/Transcripted/failed_transcriptions.json) | @MainActor |
| `StatsService.swift` | Recording statistics, streaks, motivational messages | @MainActor, singleton |
| `StatsDatabase.swift` | SQLite persistence for stats (recordings, daily_activity tables) | DispatchQueue serial |
| `DateParser.swift` | Natural language date parsing ("next Friday", "EOW") | Static methods |
| `DateFormattingHelper.swift` | Cached date formatters | Static methods |
| `Clipboard.swift` | NSPasteboard copy | Static methods |
| `CoreAudioUtils.swift` | AudioObjectID extensions, property reading helpers | Extensions |
| `AgentOutput.swift` | Agent-consumable JSON sidecars + index + CLAUDE.md for output directory | Static methods |
| `TranscriptExporter.swift` | Export transcripts as Markdown or plain text via NSSavePanel | Static methods |
| `Logging/AppLogger.swift` | Unified logging with subsystem loggers (os.Logger + file) | Sendable singleton |
| `Logging/FileLogger.swift` | JSON Lines logger at ~/Library/Logs/Transcripted/app.jsonl | DispatchQueue serial |

## Key Types

**Audio**: `@Published isRecording`, `isMonitoring`, `audioLevel` (0-1), `recordingDuration`, `audioLevelHistory` ([Float], 15 samples), `systemAudioLevelHistory`, `silenceDuration`, `isSilent`, `systemAudioStatus`, `recordingGaps`. Callbacks: `onRecordingStart`, `onRecordingComplete(micURL, systemURL)`.

**SystemAudioCapture**: `prepare()` → `start(bufferCallback:)` → `stop()`. Exposes `audioFormat` after prepare. Recovery: `recoverFromOutputChange()` on device switch. Watchdog: 3s silence timeout.

**TranscriptionTaskManager**: `@Published displayStatus: DisplayStatus` — idle → gettingReady → transcribing(progress:Double) → finishing → transcriptSaved | failed(String). `@Published speakerNamingRequest: SpeakerNamingRequest?` triggers naming tray. Key methods: `startTranscription(micURL:systemURL:outputFolder:healthInfo:)`, `retryFailedTranscription(failedId:)`.

**TranscriptionResult**: `micUtterances: [TranscriptionUtterance]`, `systemUtterances`, `duration`, `processingTime`. Computed: `allUtterances`, word counts, speaker counts.

**TranscriptionUtterance**: `start`, `end`, `channel`, `speakerId`, `persistentSpeakerId: UUID?`, `transcript: String`.

**RecordingHealthInfo**: `captureQuality` (.excellent/.good/.fair/.degraded), `audioGaps`, `deviceSwitches`. Factory: `from(audio:systemCapture:)`.

## Threading Rules
- **Audio**: NOT explicitly @MainActor. AVAudioEngine callbacks on real-time threads. UI updates dispatched to main.
- **SystemAudioCapture**: NOT @MainActor. Uses `DispatchQueue("SystemAudioCapture", qos: .userInitiated)` + NSLock. I/O proc callback on CoreAudio real-time thread — **NEVER** do I/O, locks, allocations, or ObjC inside it. Deep-copy buffers before async dispatch.
- **TranscriptionTaskManager**: @MainActor. Spawns `Task {}` for background work. Heavy compute via `nonisolated` methods on Transcription.
- **Transcription**: @MainActor for UI updates. `transcribeMultichannel()` is nonisolated (CPU-heavy). Uses `MainActor.run {}` hops for published property updates.
- **StatsDatabase / SpeakerDatabase**: DispatchQueue serial. Sync reads, async writes.

## Data Flow
```
Recording start → RecordingValidator.validateRecordingConditions()
  → Audio.start() + SystemAudioCapture.prepare() then start() → WAV files

Recording stop → Audio.stop() → onRecordingComplete(micURL, systemURL)
  → TranscriptionTaskManager.startTranscription()
  → Transcription.transcribeMultichannel(): resample → diarize → transcribe segments → match speakers → merge
  → TranscriptSaver.saveTranscript() → markdown file
  → Audio files deleted on success

Failure → FailedTranscriptionManager.addFailedTranscription() → JSON persistence
```

## Transcript Output Format
YAML frontmatter: `date`, `time`, `duration`, `processing_time`, `word_count`, `engines`, `speakers` (list with `name`, `db_id`, `utterances`, `word_count`).
Timeline entries: `[MM:SS] [Source/Speaker Name] Text`
Sections: Meeting Recording title → Channel & Speaker Analytics → Full Transcript

## Modification Recipes

| Task | Files to touch |
|---|---|
| Fix audio capture | `Audio.swift`, `SystemAudioCapture.swift` — check MEMORY.md first |
| Fix transcription output | `Transcription.swift`, `TranscriptSaver.swift` |
| Add field to transcript YAML | `TranscriptSaver.formatTranscriptMarkdown()` |
| Fix retry/queue behavior | `TranscriptionTaskManager.swift`, `FailedTranscriptionManager.swift` |
| Fix stats/counts | `StatsService.swift`, `StatsDatabase.swift` |
| Fix transcript tray data | `TranscriptStore.swift` (reads from TranscriptScanner) |
| Add new log subsystem | `Logging/AppLogger.swift` — add static let, follow existing pattern |
| Change recording validation | `RecordingValidator.swift` |

## Gotchas
- System audio: use aggregate device's nominal sample rate (read via `readNominalSampleRate()`), NOT tap format rate
- Mic format: `inputFormat(forBus: 1)`, NOT `outputFormat(forBus: 0)` (the latter returns 0Hz 0ch)
- File creation MUST happen BEFORE I/O callback starts — never create AVAudioFile inside callback
- `SystemAudioCapture.prepare()` must be called before `start()` (separates setup from I/O)
- Audio callbacks use `bufferListNoCopy` — buffer memory only valid during callback, deep-copy before async
- Recordings < 2s are rejected by TranscriptionTaskManager

## Logging Subsystems
`audio`, `audio.mic`, `audio.system` — recording, devices, format
`transcription` — model loading, STT/diarization results
`pipeline` — task lifecycle, saving, retries
`stats` — database operations
