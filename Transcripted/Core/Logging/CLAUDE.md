# Logging System (Historical Stub)

This directory no longer contains Swift source files.

The logging files that used to live here were moved into the shared Swift package at `Sources/TranscriptedCore/Logging/` during the TranscriptedCore extraction.

## Current source of truth

| File | Location | Purpose |
|------|----------|---------|
| `AppLogger.swift` | `Sources/TranscriptedCore/Logging/AppLogger.swift` | Static subsystem loggers, dispatches to both os.Logger and FileLogger |
| `FileLogger.swift` | `Sources/TranscriptedCore/Logging/FileLogger.swift` | JSON Lines writer to ~/Library/Logs/Transcripted/app.jsonl |

## Quick reference

- **Log file path**: `~/Library/Logs/Transcripted/app.jsonl` (JSON Lines format)
- **Subsystems**: audio, audio.mic, audio.system, transcription, pipeline, speaker-db, services, ui, stats, app
- **Levels**: debug, info, warning, error
- **Thread safety**: Both files are `@unchecked Sendable`; FileLogger uses a dedicated utility DispatchQueue
- **Rolling**: max 2000 entries, trims to 1500 every 100 writes

## Gotcha

If you find an old comment, doc, or code review mentioning `Transcripted/Core/Logging/AppLogger.swift` or `FileLogger.swift`, treat it as pre-extraction history and update the reference to `Sources/TranscriptedCore/Logging/`.
