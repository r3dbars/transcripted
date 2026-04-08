# TranscriptedCLI

## What this tool does

`Tools/TranscriptedCLI/` is a standalone Swift package for offline diarization. It does not build or run the app target.

## Commands

- `transcripted-cli diarize <audio>` — diarize one file, output RTTM or JSON
- `transcripted-cli batch <directory>` — diarize every matching audio file in a directory

## Files

- `Package.swift` — Swift package manifest; links against repo-level dependency artifacts in `.deps-libs/` and `.deps-modules/`
- `Sources/TranscriptedCLI/TranscriptedCLI.swift` — `@main` entry point
- `Sources/TranscriptedCLI/DiarizeCommand.swift` — single-file command
- `Sources/TranscriptedCLI/BatchCommand.swift` — directory command
- `Sources/TranscriptedCLI/ConfigLoader.swift` — JSON-to-`OfflineDiarizerConfig` loader
- `Sources/TranscriptedCLI/RTTMWriter.swift` — RTTM output formatter

## Build and run

```bash
cd Tools/TranscriptedCLI
swift build
swift run transcripted-cli diarize /path/to/audio.wav
swift run transcripted-cli batch /path/to/folder --ext wav
```

## Agent notes

- This package depends on repo-level prebuilt FluidAudio artifacts. If those are missing, build the repo dependencies first.
- The CLI is about diarization only. It does not use the app UI, app storage paths, or the `MeetingSessionController` bridge layer.
- Changes here should be checked independently from app builds.
