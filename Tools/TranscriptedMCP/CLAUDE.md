# TranscriptedMCP

MCP (Model Context Protocol) server that gives Claude Desktop direct read-only access to Transcripted meeting data. 8 Swift files.

## File Index

| File | Purpose |
|------|---------|
| `Main.swift` | Entry point. Parses `TRANSCRIPTED_DATA_DIR` env, initialises `TranscriptIndex`, launches `FileWatcher`, starts MCP server over stdio. |
| `ToolHandlers.swift` | Registers all 5 tools with the MCP server and implements their handler logic. |
| `Models.swift` | Shared model types decoded from JSON sidecars: `AgentTranscript`, `AgentUtterance`, `AgentSpeaker`, `MeetingRow`, `SearchResults`. |
| `TranscriptIndex.swift` | SQLite index (`mcp_index.sqlite`) over `~/Documents/Transcripted/`. Thread-safe via serial DispatchQueue. FTS5 full-text search, speaker analytics. |
| `TranscriptLoader.swift` | Loads and decodes `.json` sidecar files from the data directory. `enumerateSidecars()` enumerates `Call_*.json`. |
| `FileWatcher.swift` | FSEvents-based directory watcher + 30s reconciliation timer. Calls `onChange` when new/modified sidecars are detected. |
| `NameVariants.swift` | Name variant expansion (mirrors `SpeakerProfileMerger.swift`). `NameVariants.expand("mike")` → `["michael", "mike", "mikey"]`. |
| `TranscriptIndex+Queries.swift` | Complex query methods on `TranscriptIndex`: `listMeetings`, `searchUtterances`, `getPersonProfile`, `indexSidecar`. |

## Tools Exposed (5)

| Tool | Required params | Description |
|------|----------------|-------------|
| `list_meetings` | — | Lists meetings with speakers, duration, word count. Filters: `count` (default 10), `date`, `date_from`, `date_to`. |
| `read_meeting` | `filename` | Full transcript markdown for a meeting. `section`: `full` (default), `transcript`, `speakers`. |
| `search` | `query` | FTS5 full-text search across all utterances. Filters: `speaker`, `date_from`, `date_to`. Name variants applied to speaker filter. |
| `who_is` | `speaker` | Speaker profile: meeting count, total words, speaking minutes, frequent co-speakers, representative quotes. |
| `recap` | — | Digest of meetings in a date range. Defaults to today. Returns title, speakers, duration, first ~15 transcript lines per meeting. |

## Data Directory
- Default: `~/Documents/Transcripted/`
- Override: `TRANSCRIPTED_DATA_DIR` environment variable
- Reads: `Call_*.json` JSON sidecars written by `AgentOutput.writeTranscriptJSON()`
- Index: `mcp_index.sqlite` (auto-built and kept up to date via `FileWatcher`)
- Index permissions: `0o600` (owner-only)

## SQLite Index Schema (TranscriptIndex.swift)
- **meetings** table: `filename`, `date`, `datetime`, `duration_seconds`, `word_count`, `speakers_json`
- **utterances** table: `filename`, `speaker`, `start_time`, `end_time`, `text`, `channel`
- **utterances_fts** virtual FTS5 table: mirrors `utterances.text` for full-text search

## Name Variants (NameVariants.swift)
Bidirectional mapping sourced from `SpeakerProfileMerger.swift`. Example expansions:
- `mike` / `michael` / `mikey` → each finds all three
- `nate` / `nathan` / `nathaniel` → each finds all three
- `dave` / `david` → each finds both
Applied automatically in `search` (speaker filter) and `who_is`.

## File Watcher (FileWatcher.swift)
- FSEvents `O_EVTONLY` watch on the data directory + 30s fallback polling timer
- On change: calls `TranscriptIndex.indexSidecar()` for new/modified files
- Reconciliation: scans all sidecars on timer tick to catch missed events

## Build
```bash
cd Tools/TranscriptedMCP
swift build -c release
.build/release/transcripted-mcp
```

## Claude Desktop Config
Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:
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

## Gotchas
- Server communicates over stdio (MCP transport) — no HTTP port
- Index is rebuilt from scratch if `PRAGMA quick_check` fails (corrupt DB auto-recovery)
- `who_is` and `search speaker` filters expand names via NameVariants before querying
- `read_meeting` reads `.md` files (not JSON sidecars) to return formatted transcript markdown
- `recap` preview is first 15 non-empty transcript lines (not a summary — just raw dialogue)
- All tools are `readOnlyHint: true` — no writes to the data directory
