# Services — CLAUDE.md

## Purpose
Local ML inference engines (Parakeet STT, Sortformer diarization), persistent speaker voice database, audio resampling, and external task service integrations (Apple Reminders, Todoist).

## Key Files

| File | Responsibility |
|------|---------------|
| `ParakeetService.swift` | Local speech-to-text via FluidAudio's Parakeet TDT V3 (~600MB CoreML model) |
| `SortformerService.swift` | Local speaker diarization via FluidAudio's Sortformer (identifies who speaks when) |
| `SpeakerDatabase.swift` | SQLite database with 256-dim voice embeddings, cosine similarity matching |
| `AudioResampler.swift` | Resamples audio (48kHz → 16kHz mono) for model input, WAV file loading |
| `RemindersService.swift` | Creates EKReminders from extracted action items |
| `TodoistService.swift` | Sends tasks to Todoist via REST API |

## Data Flow

```
Audio files (WAV)
  → AudioResampler converts to 16kHz mono Float32 samples
  → SortformerService.performCompleteDiarization() → speaker segments
  → ParakeetService.transcribe() → text per segment
  → SpeakerDatabase matches voice embeddings → speaker names

Action items (from Core/ActionItemExtractor)
  → RemindersService.createReminders() or TodoistService.createTasks()
```

## Common Tasks

| Task | Files to touch | Watch out for |
|------|---------------|---------------|
| Fix STT accuracy | `ParakeetService.swift` | Model must be `.ready` state; check `transcription` logs |
| Fix diarization | `SortformerService.swift` | Segment boundaries come from Sortformer, not Parakeet |
| Fix speaker matching | `SpeakerDatabase.swift` | Cosine similarity threshold, embedding dimension = 256 |
| Fix resampling | `AudioResampler.swift` | System audio is 48kHz (not 96kHz), mic varies by device |
| Fix Reminders | `RemindersService.swift` | Needs EKEventStore authorization |
| Fix Todoist | `TodoistService.swift` | REST API, check API key in UserDefaults |

## Failure Modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| Model stuck in `.loading` | Download failed or bundle path wrong | Check `transcription` logs for HuggingFace errors |
| Wrong speaker names | Similarity threshold too low/high | Adjust in SpeakerDatabase (default ~0.7) |
| Resampled audio sounds wrong | Wrong source sample rate | System audio = 48kHz, verify in `audio.system` logs |
| Todoist 403 | Invalid API key | Check `todoistAPIKey` in UserDefaults |
| Reminders denied | Missing calendar permission | Check entitlements and `services` logs |

## Dependencies

**Imports**: FluidAudio (AsrManager, DiarizerManager), EventKit, Foundation
**Imported by**: Core/Transcription.swift, Core/TranscriptionTaskManager.swift

## Logging

| Subsystem | What to grep |
|-----------|-------------|
| `transcription` | Parakeet/Sortformer model loading, transcription results, diarization |
| `speaker-db` | Database open/close, speaker matching, merges |
| `services` | Reminders/Todoist task creation, API errors |
