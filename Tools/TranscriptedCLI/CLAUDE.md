# TranscriptedCLI

`Tools/TranscriptedCLI/` is a standalone Swift package for command-line access to Transcripted context and offline diarization.

It does not build or run the app target.

## Command Groups

### Local Context

- `transcripted-cli context-recent` — list recent meetings and dictations
- `transcripted-cli context-search <query>` — search across saved meetings and dictations, including meeting titles and speaker names
- `transcripted-cli read-meeting <filename>` — read one saved meeting transcript
- `transcripted-cli list-dictations` — list saved dictation day files
- `transcripted-cli read-dictation <filename>` — read one dictation day or one entry

By default these commands read:

- meetings: the app-selected capture library when available, otherwise `~/Library/Application Support/Transcripted/captures/meetings`
- dictations: the app-selected capture library when available, otherwise `~/Library/Application Support/Transcripted/captures/dictations`

Read order for default local context:

- app-selected capture library first when Transcripted has written `~/Library/Application Support/Transcripted/mcp-directories.json` or a saved `transcriptSaveLocation` preference
- current Transcripted capture folders first
- legacy Draft exports when they contain capture Markdown: `~/Library/Application Support/Draft/{meetings,dictations}/transcripts`
- older shared layout when it contains capture Markdown: `~/Documents/Transcripted`

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
| `ContextCommands.swift` | CLI entry points for recent/search/read context commands |
| `ContextStore.swift` | Shared file-loading and filtering logic for local context |
| `ContextModels.swift` | Codable models used by the context commands |
| `DiarizeCommand.swift` | Single-file diarization command |
| `BatchCommand.swift` | Directory diarization command |
| `ConfigLoader.swift` | JSON-to-`OfflineDiarizerConfig` loader |
| `CLIPathSecurity.swift` | shared path-validation helper for direct dictation reads and other on-disk file access |
| `RTTMWriter.swift` | RTTM output formatter |

## Test Files

| File | Purpose |
|------|---------|
| `Tests/TranscriptedCLITests/ContextDirectoriesTests.swift` | Coverage for current Transcripted captures vs legacy Draft fallback path resolution |
| `Tests/TranscriptedCLITests/ContextStoreTests.swift` | Coverage for `ContextStore` recent/search loading and dictation day-file filtering |

## Build And Run

```bash
cd Tools/TranscriptedCLI
swift build
swift test
swift run transcripted-cli context-recent
swift run transcripted-cli context-search "roadmap"
swift run transcripted-cli read-meeting "Product review"
swift run transcripted-cli list-dictations --count 5
swift run transcripted-cli diarize /path/to/audio.wav --json
```

## Common Retrieval Recipes

Use the built binary once `swift build` finishes so repeated checks do not wait
on SwiftPM again:

```bash
./.build/debug/transcripted-cli context-recent --count 10
./.build/debug/transcripted-cli context-recent --kind meeting --count 3
./.build/debug/transcripted-cli context-search "Linus" --kind meeting --speaker "Linus" --count 5
./.build/debug/transcripted-cli read-meeting "Call_2026-04-29_09-15-00"
./.build/debug/transcripted-cli list-dictations --date-from 2026-04-29 --date-to 2026-04-29
./.build/debug/transcripted-cli read-dictation Dictations_2026-04-29
```

What these are good for:

- latest mixed context: `context-recent`
- latest meeting only: `context-recent --kind meeting`
- full meeting markdown: `read-meeting` with the filename returned by `context-recent --kind meeting`
- meetings by speaker or topic: `context-search <query> --kind meeting --speaker <name>`
- dictations by day: `list-dictations --date-from YYYY-MM-DD --date-to YYYY-MM-DD`, then `read-dictation`

Binary path after build:

```text
.build/debug/transcripted-cli
```

When the repo-level dependency bundle is missing, `swift build` still builds the
local context commands so agent retrieval can work on a fresh checkout. The
offline audio commands (`diarize` and `batch`) then exit with an explicit
instruction to run `bash build-deps.sh` from the repo root before rebuilding.

## Gotchas

- the context commands and the diarization commands serve different users, do not describe the whole package as diarization-only
- direct dictation or meeting file reads should keep using `CLIPathSecurity` so filename inputs cannot escape the resolved Transcripted data roots
- the diarization commands depend on repo-level artifacts, so run `bash build-deps.sh` first when those are missing
- retrieval-only commands should still build and run even when the diarization bundle is absent
- `swift test` currently covers the agent-facing context path resolver and context-store loading behavior
- the default context resolver prefers the app-selected capture library when Transcripted has one, then falls back to the current Transcripted capture folders, then Draft-era exports, then `~/Documents/Transcripted/`
- when the user moved the capture library in Transcripted Settings, the CLI should follow that app-selected path before defaulting back to `~/Library/Application Support/Transcripted/captures`
- `context-recent` is intentionally a mixed feed; if the user asks for the latest meeting specifically, add `--kind meeting`
- changes here should be verified independently from the app build
