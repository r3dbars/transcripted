# TranscriptedCLI

`Tools/TranscriptedCLI/` is a standalone Swift package for command-line access to Transcripted context, offline transcription, and offline diarization.

It does not build or run the app target.

## Command Groups

### Local Context

- `transcripted-cli context-recent` — list recent meetings and dictations
- `transcripted-cli context-search <query>` — search across saved meetings and dictations, including meeting titles and speaker names
- `transcripted-cli read-meeting <filename>` — read one saved meeting transcript
- `transcripted-cli list-dictations` — list saved dictation day files
- `transcripted-cli read-dictation <filename>` — read one dictation day or one entry
- `transcripted-cli list-timelines` — list saved timeline day files
- `transcripted-cli read-timeline <filename>` — read one saved timeline day file

By default these commands read:

- meetings: the app-selected capture library when available, otherwise `~/Library/Application Support/Transcripted/captures/meetings`
- dictations: the app-selected capture library when available, otherwise `~/Library/Application Support/Transcripted/captures/dictations`
- timeline: the app-selected capture library when available, otherwise `~/Library/Application Support/Transcripted/captures/timeline`

Read order for default local context:

- app-selected capture library first when Transcripted has written `~/Library/Application Support/Transcripted/mcp-directories.json` or a saved `transcriptSaveLocation` preference
- current Transcripted capture folders first
- legacy Draft exports when they contain capture Markdown: `~/Library/Application Support/Draft/{meetings,dictations}/transcripts`
- older shared layout when it contains capture Markdown: `~/Documents/Transcripted`

They also honor:

- `--data-dir`
- `--meetings-dir`
- `--dictations-dir`
- `--timeline-dir`
- `TRANSCRIPTED_DATA_DIR`
- `TRANSCRIPTED_MEETINGS_DIR`
- `TRANSCRIPTED_DICTATIONS_DIR`
- `TRANSCRIPTED_TIMELINE_DIR`

### Output Shapes

- `context-recent`, `context-search`, and `list-dictations` print a bare JSON array with `--json` when there are results; with zero results they emit `{"results": [], "searched_directories": [...], "hint": "..."}` instead, and in text mode print `No results. Searched: <dirs>` to stderr
- `context-search --speaker` with `--kind all` or `--kind dictation` skips dictations by design; text mode prints a one-line note to stderr, `--json` wraps the results as `{"results": [...], "notes": [...]}`
- `--count` values are clamped to 1-50
- `read-meeting --json` includes `recording`, `speakers`, and `utterances` (parsed transcript structure) alongside the raw `markdown`; `read-dictation --json` includes `date` and `entries` (entry id, captured timestamp, source app, title, text) alongside `markdown`; `read-timeline --json` includes `date`, `cards`, `card_count`, `active_minutes`, and `categories` alongside `markdown`

### Offline Audio

- `transcripted-cli transcribe <media...>` — transcribe audio or video files to plain text (default), JSON, or SRT with the local Parakeet model
- `transcripted-cli diarize <audio>` — diarize one file, output RTTM or JSON
- `transcripted-cli batch <directory>` — diarize matching audio files in a directory

`transcribe` exists so coding agents (Claude Code, Codex) can use the on-device
model on arbitrary files — downloaded videos, voice memos, screen recordings —
without going through the app's meeting flow. Audio files decode through
`AVAudioFile`; video containers (MP4, MOV, M4V) fall back to `AVAssetReader`
and mix all audio tracks to mono. WebM/MKV are not decodable by AVFoundation —
the error message suggests an `ffmpeg` conversion. Models resolve in order:
`--models-dir`, the installed `Transcripted.app` bundled models, the shared
FluidAudio cache (`~/Library/Application Support/FluidAudio/Models/`), then a
one-time ~600MB download into that cache (`--no-download` fails instead).

## Files

| File | Purpose |
|------|---------|
| `Package.swift` | Swift package manifest; depends on `../TranscriptedCaptureKit` and links against repo dependency artifacts |
| `TranscriptedCLI.swift` | `@main` command root and subcommand registration |
| `ContextCommands.swift` | CLI entry points for recent/search/read context commands |
| `ContextStore.swift` | File-loading and filtering logic for local context; directory resolution and markdown parsing delegate to `TranscriptedCaptureKit` |
| `ContextModels.swift` | Codable models used by the context commands |
| `TranscribeCommand.swift` | Audio/video transcription command plus Parakeet model resolution |
| `TranscribeMediaLoader.swift` | AVFoundation decode of audio files and video containers into 16kHz mono samples |
| `TranscribeOutput.swift` | dependency-free output formatting: segment grouping, SRT rendering, JSON payloads, output-path derivation |
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
| `Tests/TranscriptedCLITests/TranscribeOutputTests.swift` | Coverage for transcribe output formats, segment grouping, SRT timestamps, and output-path derivation |

## Build And Run

```bash
cd Tools/TranscriptedCLI
swift build
swift test
swift run transcripted-cli context-recent
swift run transcripted-cli context-search "roadmap"
swift run transcripted-cli read-meeting "Product review"
swift run transcripted-cli list-dictations --count 5
TRANSCRIPTEDCLI_ENABLE_TRANSCRIPTION=1 swift run transcripted-cli transcribe /path/to/video.mp4
TRANSCRIPTEDCLI_ENABLE_DIARIZATION=1 swift run transcripted-cli diarize /path/to/audio.wav --json
```

Transcription recipes once built with the deps bundle:

```bash
./.build/debug/transcripted-cli transcribe ~/Downloads/talk.mp4
./.build/debug/transcripted-cli transcribe ~/Downloads/videos/*.mp4 --output-dir ~/Downloads/transcripts
./.build/debug/transcripted-cli transcribe interview.m4a --json
./.build/debug/transcripted-cli transcribe talk.mov --srt --output talk.srt
./.build/debug/transcripted-cli transcribe memo.m4a --no-download
```

## Common Retrieval Recipes

Use the built binary once `swift build` finishes so repeated checks do not wait
on SwiftPM again:

```bash
./.build/debug/transcripted-cli context-recent --count 10
./.build/debug/transcripted-cli context-recent --kind meeting --count 3
./.build/debug/transcripted-cli context-search "Linus" --kind meeting --speaker "Linus" --count 5
./.build/debug/transcripted-cli read-meeting "Call_2026-04-29_09-15-00" --json
./.build/debug/transcripted-cli list-dictations --date-from 2026-04-29 --date-to 2026-04-29
./.build/debug/transcripted-cli read-dictation Dictations_2026-04-29 --json
./.build/debug/transcripted-cli list-timelines --date-from 2026-04-29 --date-to 2026-04-29
./.build/debug/transcripted-cli read-timeline 2026-04-29 --json
```

What these are good for:

- latest mixed context: `context-recent`
- latest meeting only: `context-recent --kind meeting`
- full meeting markdown: `read-meeting` with the filename returned by `context-recent --kind meeting`
- meetings by speaker or topic: `context-search <query> --kind meeting --speaker <name>`
- dictations by day: `list-dictations --date-from YYYY-MM-DD --date-to YYYY-MM-DD`, then `read-dictation`
- timeline by day: `list-timelines --date-from YYYY-MM-DD --date-to YYYY-MM-DD`, then `read-timeline`
- machine-readable full reads: add `--json` to `read-meeting` or `read-dictation`

Binary path after build:

```text
.build/debug/transcripted-cli
```

By default, `swift build` builds the local context commands without linking the
offline audio dependency bundle, so agent retrieval works on a fresh checkout.
The offline audio commands (`transcribe`, `diarize`, and `batch`) then exit
with an explicit instruction to run `bash build-deps.sh` from the repo root and
rebuild with `TRANSCRIPTEDCLI_ENABLE_TRANSCRIPTION=1` (or
`TRANSCRIPTEDCLI_ENABLE_DIARIZATION=1` — either flag links the same bundle and
enables both command groups) when offline audio work is needed.

## Gotchas

- the context commands and the offline audio commands serve different users, do not describe the whole package as diarization-only
- direct dictation or meeting file reads should keep using `CLIPathSecurity` so filename inputs cannot escape the resolved Transcripted data roots
- the transcription and diarization commands depend on repo-level artifacts, so run `bash build-deps.sh` and rebuild with `TRANSCRIPTEDCLI_ENABLE_TRANSCRIPTION=1` or `TRANSCRIPTEDCLI_ENABLE_DIARIZATION=1` when those are needed
- retrieval-only commands should still build and run even when the offline audio bundle is absent
- `transcribe` keeps its output formatting in the dependency-free `TranscribeOutput.swift` so `swift test` covers it without the deps bundle; keep new formatting logic there, not in the gated command
- `transcribe` decodes whole files into memory as 16kHz mono Float32 (~230MB per hour of audio); very long recordings need commensurate RAM
- `swift test` currently covers the agent-facing context path resolver, context-store loading behavior, and transcribe output formatting
- the default context resolver prefers the app-selected capture library when Transcripted has one, then falls back to the current Transcripted capture folders, then Draft-era exports, then `~/Documents/Transcripted/`
- when the user moved the capture library in Transcripted Settings, the CLI should follow that app-selected path before defaulting back to `~/Library/Application Support/Transcripted/captures`
- `context-recent` is intentionally a mixed feed; if the user asks for the latest meeting specifically, add `--kind meeting`
- diagnostics (empty-result and speaker-filter notes) go to stderr in text mode so piped stdout stays parseable; keep it that way
- changes here should be verified independently from the app build
- directory resolution and capture-Markdown parsing live in `Tools/TranscriptedCaptureKit` and are shared with `Tools/TranscriptedMCP`; change them there, not by re-inlining logic into `ContextStore.swift`
