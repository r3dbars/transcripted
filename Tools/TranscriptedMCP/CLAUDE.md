# TranscriptedMCP

Standalone MCP server (`transcripted-mcp`) for querying Transcripted meeting data from Claude Desktop or any MCP-compatible client. Reads the same `~/Documents/Transcripted/` artifacts produced by the main app — no direct access to the app or its databases.

## File Index (Sources/TranscriptedMCP/)

| File | Purpose |
|------|---------|
| `Main.swift` | `@main` entry point: initialises TranscriptIndex, starts FileWatcher, creates MCP Server with StdioTransport |
| `ToolHandlers.swift` | Registers all 5 MCP tool handlers with the server; contains per-tool request parsing and JSON serialisation |
| `TranscriptIndex.swift` | SQLite-backed index rebuilt from JSON sidecars; `reconcile()` full rebuild, `indexSingleFile()` incremental update, all query methods (`listMeetings`, `searchUtterances`, `getPersonProfile`, `indexSidecar`) |
| `TranscriptLoader.swift` | Loads `.md` transcript files from disk for `read_meeting` |
| `Models.swift` | All Codable input/output structs (AgentTranscript, MeetingSummary, SearchResult, SpeakerHistoryResult, etc.) and `MCPIndexError` |
| `NameVariants.swift` | Speaker name fuzzy-matching — `Mike` finds `Michael`, handles nicknames and first-name-only lookups |
| `DataDirectories.swift` | Resolves meeting and dictation data directories from env vars or defaults; provides the list of directories to watch |
| `FileWatcher.swift` | `DispatchSource`-based directory watcher; calls back with changed URL for incremental index updates |

## Test Files (Tests/TranscriptedMCPTests/)

| File | Purpose |
|------|---------|
| `TranscriptIndexTests.swift` | Full index lifecycle: reconcile, query, date filters, speaker search |
| `TranscriptLoaderTests.swift` | Markdown + YAML frontmatter parsing edge cases |
| `NameVariantsTests.swift` | Name variant matching accuracy |
| `TestHelpers.swift` | Shared fixture builders (sample JSON sidecars, temp directories) |

## MCP Tools (5 tools, all read-only)

| Tool | Description |
|------|-------------|
| `list_meetings` | List meetings with metadata (date, duration, speakers, word count). Optional: `count` (default 10, max 50), `date`, `date_from`, `date_to` |
| `read_meeting` | Full transcript for a single meeting by filename. Optional `section`: `full` (default), `transcript` (dialogue only), `speakers` (analytics only) |
| `search` | Full-text search across all transcripts. Required: `query`. Optional: `speaker` (name variant matching), `date_from`, `date_to`. Returns grouped results by meeting |
| `who_is` | Person profile: meeting count, last seen, total speaking time, co-speakers, representative quotes. Required: `speaker` |
| `recap` | Structured day/week digest with per-meeting title + speaker list + ~200-word preview. Optional: `date_from`, `date_to` (both default to today) |

## Data Flow
```
~/Documents/Transcripted/*.json  (AgentOutput JSON sidecars)
  -> TranscriptIndex.reconcile()  (on startup: full SQLite rebuild)
  -> FileWatcher callback          (on new file: indexSingleFile())
  -> SQLite index                  (in-memory + on-disk, :memory: during tests)

~/Documents/Transcripted/*.md    (Markdown transcripts)
  -> TranscriptLoader.load()      (on read_meeting requests only)
```

## Index Database Schema
```sql
-- meetings: one row per JSON sidecar
id TEXT PRIMARY KEY,      -- filename stem (e.g. "Call_2026-03-26_16-04-11")
date TEXT,                -- YYYY-MM-DD
datetime TEXT,            -- ISO 8601
duration_seconds INT,
speaker_count INT,
word_count INT,
speakers_json TEXT,       -- JSON array of MeetingSpeaker
title TEXT                -- from YAML frontmatter (nullable)

-- utterances: one row per utterance, FTS5-indexed
meeting_id TEXT,
speaker TEXT,
speaker_id TEXT,          -- persistent DB ID (nullable)
start REAL,
end REAL,
text TEXT
```
WAL mode, `busy_timeout 5000ms`. Index file: `~/Documents/Transcripted/mcp_index.sqlite` (auto-recreated on corruption).

## Environment / Config
- `TRANSCRIPTED_DATA_DIR` — override data directory (default: `~/Documents/Transcripted`)
- No other configuration; no credentials, no network calls

## Build & Test
```bash
# From repo root
cd Tools/TranscriptedMCP
swift build
swift test

# Binary lands at: .build/debug/transcripted-mcp
```

## Claude Desktop Setup (claude_desktop_config.json)
```json
{
  "mcpServers": {
    "transcripted": {
      "command": "/path/to/transcripted-mcp"
    }
  }
}
```

## Relationships
- Reads JSON sidecars written by `Core/AgentOutput.swift` (main app)
- Name variant logic mirrors `Services/SpeakerProfileMerger.swift`
- No compile-time dependency on the main Transcripted target — standalone Swift package

## Threading Model
- All MCP handler callbacks are `async`; SQLite access is synchronous inside each handler (single-process, no shared state across requests)
- FileWatcher runs on a `DispatchQueue`; `indexSingleFile()` is safe to call from any queue (SQLite journal mode handles concurrent reads)

## Gotchas
- Server communicates over stdio (MCP transport) — no HTTP port
- Index is rebuilt from scratch if `PRAGMA quick_check` fails (corrupt DB auto-recovery)
- `reconcile()` scans all `.json` files in the data dir on every startup — fast enough for hundreds of files but O(n) on sidecar count
- `who_is` and `search speaker` filters expand names via NameVariants before querying
- `read_meeting` reads `.md` files directly from disk (not from the index) — always returns current file content
- `recap` preview is first 15 non-empty transcript lines (not a summary — just raw dialogue)
- All tools are `readOnlyHint: true` — no writes to the data directory
- Name variant matching (`NameVariants.swift`) is heuristic; uncommon nicknames may not resolve
- The MCP server binary is separate from the main Transcripted app; updating the app does not update the server binary
