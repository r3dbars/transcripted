# TranscriptedCLI

`Tools/TranscriptedCLI/` is a standalone Swift package for command-line access to Transcripted context and offline diarization.

It does not build or run the app target.

## Command Groups

### Local Context

- `transcripted-cli context-recent` — list recent meetings and dictations
- `transcripted-cli context-search <query>` — search across saved meetings and dictations
- `transcripted-cli list-dictations` — list saved dictation day files
- `transcripted-cli read-dictation <filename>` — read one dictation day or one entry

By default these commands read:

- meetings: `~/Library/Application Support/Transcripted/captures/meetings`
- dictations: `~/Library/Application Support/Transcripted/captures/dictations`

Fallback order when the Transcripted capture folders do not exist yet:

- legacy Draft exports: `~/Library/Application Support/Draft/{meetings,dictations}/transcripts`
- older shared layout: `~/Documents/Transcripted`

They also honor:

- `--data-dir`
- `--meetings-dir`
- `--dictations-dir`
- `TRANSCRIPTED_DATA_DIR`
- `TRANSCRIPTED_MEETINGS_DIR`
- `TRANSCRIPTED_DICTATIONS_DIR`

### Offline Audio

- `transcripted-cli diarize <audio>` — diarize one file, output RTTM or JSON
- `transcripted-cli batch <directory>` — diarize matching audio files in a directory

## Files

| File | Purpose |
|------|---------|
| `Package.swift` | Swift package manifest; links against repo dependency artifacts |
| `TranscriptedCLI.swift` | `@main` command root and subcommand registration |
| `ContextCommands.swift` | CLI entry points for recent/search/dictation commands |
| `ContextStore.swift` | Shared file-loading and filtering logic for local context |
| `ContextModels.swift` | Codable models used by the context commands |
| `DiarizeCommand.swift` | Single-file diarization command |
| `BatchCommand.swift` | Directory diarization command |
| `ConfigLoader.swift` | JSON-to-`OfflineDiarizerConfig` loader |
| `DiarizerConfigCompatibility.swift` | Compatibility shim for speaker-bound tuning while newer FluidAudio APIs are in flux |
| `RTTMWriter.swift` | RTTM output formatter |

## Build And Run

```bash
cd Tools/TranscriptedCLI
swift build
swift run transcripted-cli context-recent
swift run transcripted-cli context-search "roadmap"
swift run transcripted-cli list-dictations --count 5
swift run transcripted-cli diarize /path/to/audio.wav --json
```

## Gotchas

- the context commands and the diarization commands serve different users, do not describe the whole package as diarization-only
- the diarization commands depend on repo-level artifacts, so run `bash build-deps.sh` first when those are missing
- the default context resolver prefers Transcripted capture folders, then falls back to Draft-era exports, then `~/Documents/Transcripted/`
- `DiarizerConfigCompatibility.swift` currently keeps old bounded-speaker call sites compiling; it does not reintroduce upstream behavior by itself
- changes here should be verified independently from the app build
