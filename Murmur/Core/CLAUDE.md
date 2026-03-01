# Core — CLAUDE.md

## Purpose
Audio capture, transcription pipeline orchestration, task management, transcript saving, and recording statistics. This is the engine room of Transcripted. Everything runs 100% locally — no cloud APIs.

## Key Files

| File | Responsibility |
|------|---------------|
| `Audio.swift` | Microphone capture via AVAudioEngine, writes WAV in real-time, monitors levels/silence |
| `SystemAudioCapture.swift` | System-wide audio via CoreAudio process taps, aggregate device management |
| `Transcription.swift` | Orchestrates Parakeet STT + Sortformer diarization + speaker matching |
| `TranscriptionTaskManager.swift` | Background transcription queue, progress tracking, status management |
| `TranscriptionTypes.swift` | Engine-agnostic result types (TranscriptionResult, SpeakerIdentificationResult, etc.) |
| `TranscriptSaver.swift` | Writes markdown with YAML frontmatter to ~/Documents/Transcripted/ |
| `TranscriptStore.swift` | ObservableObject store for transcript tray UI (recent transcripts, copy-to-clipboard) |
| `TranscriptScanner.swift` | Discovers and indexes existing transcript files |
| `TranscriptUtils.swift` | Transcript file management, renaming, cleanup |
| `DateParser.swift` | Natural language date parsing ("next Friday", "EOW") |
| `DateFormattingHelper.swift` | Date formatting utilities |
| `FailedTranscriptionManager.swift` | Persistent retry queue for failed transcriptions (JSON file) |
| `RecordingValidator.swift` | Pre-recording checks: disk space, permissions, devices |
| `StatsService.swift` | Recording statistics and streak tracking |
| `StatsDatabase.swift` | SQLite persistence for stats |
| `Logging/AppLogger.swift` | Unified logging interface with subsystem loggers |
| `Logging/FileLogger.swift` | JSON Lines file logger at ~/Library/Logs/Transcripted/app.jsonl |

## Data Flow

```
Recording starts
  → RecordingValidator checks conditions
  → Audio.start() captures mic (AVAudioEngine)
  → SystemAudioCapture captures system audio (CoreAudio process tap)
  → Both write WAV files to ~/Documents/

Recording stops
  → Audio.stop() triggers onRecordingComplete callback
  → TranscriptionTaskManager.startTranscription() queued
  → Transcription.swift runs pipeline:
      Sortformer diarizes → Parakeet transcribes per-segment → Speaker matching
  → TranscriptSaver writes markdown
  → Status transitions to .transcriptSaved → auto-resets to .idle

On failure → FailedTranscriptionManager persists for retry
```

## Common Tasks

| Task | Files to touch | Watch out for |
|------|---------------|---------------|
| Fix audio capture bug | `Audio.swift`, `SystemAudioCapture.swift` | NEVER do I/O or locks in audio callbacks (real-time threads) |
| Fix transcription output | `Transcription.swift`, `TranscriptSaver.swift` | Check model loading state first |
| Fix retry/queue behavior | `TranscriptionTaskManager.swift`, `FailedTranscriptionManager.swift` | Retry state persisted to JSON file |
| Fix stats/counts | `StatsService.swift`, `StatsDatabase.swift` | SQLite database, check schema |
| Fix transcript tray | `TranscriptStore.swift` | Reads from TranscriptScanner, provides copy-to-clipboard |
| Add new log subsystem | `Logging/AppLogger.swift` | Add static let, follow existing pattern |

## Failure Modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| "0Hz 0ch" in logs | Using `outputFormat` instead of `inputFormat(forBus: 1)` | Always use hardware format from bus 1 |
| Audio glitches/pops | Doing I/O or locks in audio callback | Move to DispatchQueue.async |
| 96kHz mismatch | System tap reports 96kHz but actual is 48kHz | Use hardcoded 48000.0 for system audio |
| Transcription empty | Models not loaded | Check `transcription` subsystem logs for model state |
| System audio silent | Output device changed | Check device change listener in SystemAudioCapture |
| Recording not saving | Disk space or permissions | Check RecordingValidator output |

## Dependencies

**Imports from Services/**: ParakeetService, SortformerService, SpeakerDatabase, AudioResampler
**Imported by**: TranscriptedApp.swift, UI/ (FloatingPanel reads task manager state)

## Logging

| Subsystem | What to grep |
|-----------|-------------|
| `audio` | General audio start/stop, sleep/wake |
| `audio.mic` | Mic format, device switches, recovery, writes |
| `audio.system` | System tap setup, buffers, device changes, recovery |
| `transcription` | Model loading, STT/diarization results |
| `pipeline` | Task lifecycle, saving, file management, retries |
| `stats` | Database operations, recording stats |
