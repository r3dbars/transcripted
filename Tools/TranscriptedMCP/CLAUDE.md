# TranscriptedMCP

Standalone MCP server (`transcripted-mcp`) for querying Transcripted meeting and
dictation data from Claude Desktop or any MCP-compatible client.

It is read-only, independent from the app target, and builds its own SQLite
index from saved artifacts on disk.

## Directory resolution

Default locations:

- meetings: `~/Library/Application Support/Transcripted/captures/meetings/`
- dictations: `~/Library/Application Support/Transcripted/captures/dictations/`
- index: `~/Library/Application Support/Transcripted/cache/`

Legacy fallback order when the newer folders are missing:

1. `~/Library/Application Support/Draft/meetings/transcripts/` and `.../dictations/transcripts/`
2. `~/Documents/Transcripted/`

Overrides:

- `TRANSCRIPTED_DATA_DIR`
- `TRANSCRIPTED_MEETINGS_DIR`
- `TRANSCRIPTED_DICTATIONS_DIR`
- `TRANSCRIPTED_INDEX_DIR`

## Important files

- `Main.swift` — `@main` entry point, directory resolution, index startup, file watchers, and stdio server boot
- `DataDirectories.swift` — default-path, env-override, and legacy-fallback resolution
- `ToolHandlers.swift` — MCP tool registration and request routing
- `TranscriptIndex.swift` — SQLite-backed index and query methods
- `TranscriptLoader.swift` — markdown loaders for meetings and dictations
- `NameVariants.swift` — speaker-name fuzzy matching
- `FileWatcher.swift` — incremental reindexing on file changes
- `PathSecurity.swift` — path validation for read requests inside the watched directories
- `Models.swift` — Codable request/response models and shared errors

## MCP tools

All tools are read-only:

- `list_meetings`
- `read_meeting`
- `list_dictations`
- `read_dictation`
- `search`
- `search_context`
- `recent_context`
- `who_is`
- `recap`

## Data flow

```text
meeting .json sidecars + dictation markdown/day payloads
  -> TranscriptIndex.reconcile() on startup
  -> FileWatcher incremental updates on change
  -> SQLite index

meeting and dictation markdown
  -> TranscriptLoader direct reads for read_meeting / read_dictation
```

## Build and test

```bash
cd Tools/TranscriptedMCP
swift build
swift test
```

Binary path after build:

```text
.build/debug/transcripted-mcp
```

## Notes

- transport is stdio, not HTTP
- the server auto-creates missing data and index directories
- `read_meeting` and `read_dictation` read files from disk directly, not from the SQLite index
- the MCP binary is separate from the app; updating the app does not update the built server automatically
