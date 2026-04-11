# TranscriptedCLI

`Tools/TranscriptedCLI/` is a standalone Swift package for:

- searching saved Transcripted context from the terminal
- offline diarization commands

It does not build or run the app target.

## Command groups

### Local context

- `transcripted-cli context-recent`
- `transcripted-cli context-search <query>`
- `transcripted-cli list-dictations`
- `transcripted-cli read-dictation <filename>`

Default context locations:

- meetings: `~/Library/Application Support/Transcripted/captures/meetings/`
- dictations: `~/Library/Application Support/Transcripted/captures/dictations/`

Legacy fallback order when those newer folders are missing:

1. `~/Library/Application Support/Draft/meetings/transcripts/` and `.../dictations/transcripts/`
2. `~/Documents/Transcripted/`

Overrides:

- `--data-dir`
- `--meetings-dir`
- `--dictations-dir`
- `TRANSCRIPTED_DATA_DIR`
- `TRANSCRIPTED_MEETINGS_DIR`
- `TRANSCRIPTED_DICTATIONS_DIR`

### Offline audio

- `transcripted-cli diarize <audio>`
- `transcripted-cli batch <directory>`

## Important files

- `Package.swift` — Swift package manifest
- `TranscriptedCLI.swift` — `@main` command root and subcommand registration
- `ContextCommands.swift` — CLI entry points for recent/search/dictation commands
- `ContextStore.swift` — directory resolution, markdown loading, and filtering logic
- `ContextModels.swift` — Codable models used by context commands
- `DiarizeCommand.swift` — single-file diarization
- `BatchCommand.swift` — directory diarization
- `ConfigLoader.swift` — config loading
- `DiarizerConfigCompatibility.swift` — legacy config compatibility helpers
- `RTTMWriter.swift` — RTTM formatter

## Build and run

```bash
cd Tools/TranscriptedCLI
swift build
swift run transcripted-cli context-recent
swift run transcripted-cli context-search "roadmap"
swift run transcripted-cli list-dictations --count 5
swift run transcripted-cli diarize /path/to/audio.wav --json
```

## Notes

- the context commands and diarization commands serve different use cases; do not describe the whole package as diarization-only
- diarization commands depend on repo-level artifacts, so run `bash build-deps.sh` first when they are missing
- context commands read markdown directly and can synthesize dictation summaries even when JSON sidecars are absent
