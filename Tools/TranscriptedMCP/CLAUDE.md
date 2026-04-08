# TranscriptedMCP

Standalone MCP server (`transcripted-mcp`) for querying Transcripted meeting
and dictation data from Claude Desktop or any MCP-compatible client.

It is read-only and independent from the app target.

## What It Reads

Default locations:

- meetings: `~/Library/Application Support/Draft/meetings/transcripts`
- dictations: `~/Library/Application Support/Draft/dictations/transcripts`
- index: meetings folder by default

Legacy fallback:

- `~/Documents/Transcripted`

Path overrides:

- `TRANSCRIPTED_DATA_DIR` — shared meetings + dictations directory
- `TRANSCRIPTED_MEETINGS_DIR` — meetings directory override
- `TRANSCRIPTED_DICTATIONS_DIR` — dictations directory override
- `TRANSCRIPTED_INDEX_DIR` — SQLite index directory override

## File Index

| File | Purpose |
|------|---------|
| `Main.swift` | `@main` entry point; resolves directories, builds the index, starts file watchers, then starts the MCP stdio server |
| `DataDirectories.swift` | Default-path and env-override resolution for meetings, dictations, and index storage |
| `ToolHandlers.swift` | Registers every MCP tool and routes requests to the correct loader/index method |
| `TranscriptIndex.swift` | SQLite-backed index, incremental updates, and query methods across meetings and dictations |
| `TranscriptLoader.swift` | Loads `.md` meeting transcripts from disk for `read_meeting` |
| `Models.swift` | Codable input/output models and `MCPIndexError` |
| `NameVariants.swift` | Speaker-name fuzzy matching for `search` and `who_is` |
| `FileWatcher.swift` | Watches the local transcript directories and incrementally reindexes changed files |

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

meetings/*.md
  -> TranscriptLoader.load() for read_meeting
```

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

## Gotchas

- transport is stdio, not HTTP
- the server auto-creates missing data/index directories
- the index rebuilds from disk on startup
- `read_meeting` reads the markdown file directly, not the SQLite index
- the server binary is separate from the app; updating the app does not update
  the MCP binary automatically
