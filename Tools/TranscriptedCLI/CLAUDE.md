# TranscriptedCLI

## What This Package Is

`Tools/TranscriptedCLI/` is a standalone Swift package for offline diarization
workflows built directly on FluidAudio.

It is separate from the main app and separate from `TranscriptedCore`.

## Commands

- `transcripted-cli diarize`
  Run offline diarization on a single audio file and emit RTTM or JSON.
- `transcripted-cli batch`
  Run offline diarization across a directory of audio files and write RTTM
  outputs for each file.

## Key Files

- `Package.swift`
  Standalone package definition with ArgumentParser plus the dependency archive
  include/link pattern.
- `TranscriptedCLI.swift`
  Root command registration.
- `DiarizeCommand.swift`
  Single-file diarization flow.
- `BatchCommand.swift`
  Directory batch flow.
- `ConfigLoader.swift`
  Maps a JSON file into `OfflineDiarizerConfig`.
- `RTTMWriter.swift`
  Converts diarization segments into RTTM output.

## Build Assumptions

This package expects repo-root dependency artifacts to exist in:

- `.deps-libs/`
- `.deps-modules/`

CLI failures are often missing build artifacts rather than source-level errors.

## Typical Usage

```bash
cd Tools/TranscriptedCLI
swift run transcripted-cli diarize /path/to/audio.m4a --json
swift run transcripted-cli batch /path/to/folder --ext wav
```

Optional flags:

- `--config`
- `--models-dir`
- `--output`
- `--output-dir`

## What This Package Does Not Do

- it does not import app UI code
- it does not save Markdown transcripts
- it does not use `TranscriptedCore`
- it does not participate in the app's meeting storage layout

## When To Update This Doc

Update this file if you change:

- command names or flags
- required dependency artifact locations
- output formats
- the package's relationship to the main app or `TranscriptedCore`
