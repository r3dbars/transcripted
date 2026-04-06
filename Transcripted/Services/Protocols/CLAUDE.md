# Service Protocols (Historical Stub)

This directory no longer contains Swift protocol source files.

The protocol definitions that used to live here were moved into the shared Swift package at `Sources/TranscriptedCore/Protocols/` during the TranscriptedCore extraction. Today this folder exists only because it still has this documentation file.

## Current source of truth

The active Core protocol files are:

| File | Purpose |
|------|---------|
| `Sources/TranscriptedCore/Protocols/SpeechToTextEngine.swift` | STT abstraction implemented by `Transcripted/Services/ParakeetEngineAdapter.swift` |
| `Sources/TranscriptedCore/Protocols/DiarizationEngine.swift` | Offline diarization abstraction implemented by Core services |
| `Sources/TranscriptedCore/Protocols/SpeakerStore.swift` | Speaker profile persistence / lookup abstraction |
| `Sources/TranscriptedCore/Protocols/TranscriptStorage.swift` | Transcript persistence abstraction used by the pipeline |
| `Sources/TranscriptedCore/Protocols/AudioCaptureEngine.swift` | Recording engine abstraction |
| `Sources/TranscriptedCore/Protocols/StatsStore.swift` | Stats persistence abstraction |
| `Sources/TranscriptedCore/Protocols/TranscriptNotifier.swift` | Optional notification bridge used by embedders to tag and deliver transcript-saved notifications |

## App-target relationships

- `Transcripted/Services/ParakeetEngineAdapter.swift` conforms to `SpeechToTextEngine`
- `Transcripted/Services/TranscriptedNotificationsAdapter.swift` conforms to `TranscriptNotifier`
- Most other concrete implementations now live inside `Sources/TranscriptedCore/`

## Gotcha

If you find an old comment, doc, or code review mentioning `Transcripted/Services/Protocols/*.swift`, treat it as pre-extraction history and update the reference to `Sources/TranscriptedCore/Protocols/*.swift`.
