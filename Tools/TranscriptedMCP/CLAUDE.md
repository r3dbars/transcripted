# TranscriptedMCP

Standalone MCP server (`transcripted-mcp`) for querying Transcripted meeting and dictation data from Claude Desktop or any MCP-compatible client.

It is read-only, independent from the app target, and builds its own SQLite index from saved artifacts on disk.

## What It Reads

Default locations:

- meetings: `~/Library/Application Support/Transcripted/captures/meetings`
- dictations: `~/Library/Application Support/Transcripted/captures/dictations`
- index: `~/Library/Application Support/Transcripted/cache`

Legacy fallback:

- `~/Library/Application Support/Draft/{meetings,dictations}/transcripts`
- `~/Documents/Transcripted`

Path overrides:

- `TRANSCRIPTED_DATA_DIR` — shared meetings + dictations directory
- `TRANSCRIPTED_MEETINGS_DIR` — meetings directory override
- `TRANSCRIPTED_DICTATIONS_DIR` — dictations directory override
- `TRANSCRIPTED_INDEX_DIR` — SQLite index directory override

## Package Layout (15 Swift files)

- `Package.swift` — Swift package manifest for the standalone MCP server
- `Sources/TranscriptedMCP/` — 9 source files for server startup, directory resolution, path validation, indexing, and tool handlers
- `Tests/TranscriptedMCPTests/` — 5 test files for directory resolution, index lifecycle, markdown loading, name variants, and shared fixtures

## File Index

| File | Purpose |
|------|---------|
| `Main.swift` | `@main` entry point; resolves directories, builds the index, starts file watchers, then starts the MCP stdio server |
| `DataDirectories.swift` | Default-path and env-override resolution for meetings, dictations, and index storage |
| `ToolHandlers.swift` | Registers every MCP tool and routes requests to the correct loader or index method |
| `TranscriptIndex.swift` | SQLite-backed index, incremental updates, and query methods across meetings and dictations |
| `TranscriptLoader.swift` | Loads markdown meeting transcripts and dictation day files directly from disk |
| `Models.swift` | Codable input/output models and `MCPIndexError` |
| `NameVariants.swift` | Speaker-name fuzzy matching for speaker-aware queries |
| `PathSecurity.swift` | Guards direct file reads against traversal, symlinks, and out-of-root paths |
| `FileWatcher.swift` | Watches the local transcript directories and incrementally reindexes changed files |

## Test Files

| File | Purpose |
|------|---------|
| `DataDirectoriesTests.swift` | Directory-resolution coverage for current Transcripted captures vs legacy Draft fallback |
| `TranscriptIndexTests.swift` | Full index lifecycle: reconcile, query, date filters, speaker search, and mixed-context indexing |
| `TranscriptLoaderTests.swift` | Markdown and YAML frontmatter parsing edge cases, including path-safety checks |
| `NameVariantsTests.swift` | Name variant matching accuracy |
| `TestHelpers.swift` | Shared fixture builders for sample sidecars and temp directories |

## MCP Tools

All tools are read-only.

| Tool | Description |
|------|-------------|
| `list_meetings` | List saved meetings with metadata and optional date filters |
| `read_meeting` | Read one meeting transcript by filename |
| `list_dictations` | List saved dictation day files with counts, source apps, and titles |
| `read_dictation` | Read one dictation day or one specific dictation entry |
| `search` | Search meeting transcript content |
| `search_context` | Search across meetings, dictations, or both |
| `recent_context` | Get a mixed recent feed of meetings and dictations |
| `who_is` | Look up a speaker profile across saved meetings |
| `recap` | Build a structured digest for a date range |

## Data Flow

```text
meetings/*.json + dictations/*.json
  -> TranscriptIndex.reconcile() on startup
  -> FileWatcher incremental updates on change
  -> SQLite index

meetings/*.md + dictations/*.md
  -> TranscriptLoader direct reads for read_meeting and read_dictation
```

## Index Shape

The SQLite index keeps separate records for:

- meetings
- meeting speakers / utterance search rows
- dictation day files
- dictation entry search rows

This lets the server answer both meeting-specific queries (`who_is`, `read_meeting`) and mixed-context queries (`search_context`, `recent_context`) without touching app-owned runtime state.

## Build And Test

```bash
cd Tools/TranscriptedMCP
swift build
swift test
```

Binary path after build:

```text
.build/debug/transcripted-mcp
```

## Example MCP Config

```json
{
  "mcpServers": {
    "transcripted": {
      "command": "/absolute/path/to/transcripted-mcp"
    }
  }
}
```

## Relationships

- reads meeting sidecars written by `Sources/TranscriptedCore/Storage/AgentOutput.swift`
- reads dictation markdown day files written by `Sources/Dictation/DictationTranscriptWriter.swift`
- mirrors speaker-name matching logic from the app with `NameVariants.swift`
- has no compile-time dependency on the main Transcripted app target

## Gotchas

- transport is stdio, not HTTP
- direct file reads are path-validated and reject traversal or symlink escapes
- the server auto-creates missing data and index directories
- the index rebuilds from disk on startup
- `read_meeting` and `read_dictation` read markdown directly from disk, not from the SQLite index
- the server binary is separate from the app, updating the app does not update the MCP binary automatically
