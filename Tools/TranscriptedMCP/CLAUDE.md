# TranscriptedMCP

Standalone MCP server (`transcripted-mcp`) for querying Transcripted meeting and dictation data from Claude Desktop or any MCP-compatible client.

It is read-only, independent from the app target, and builds its own SQLite index from saved artifacts on disk.

## What It Reads

App-selected locations:

- MCP first checks `~/Library/Application Support/Transcripted/mcp-directories.json`
  and the app's `transcriptSaveLocation` preference so it follows the capture
  library chosen in Settings.

Default locations when no custom capture library is configured:

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

When `TRANSCRIPTED_DATA_DIR` points at a shared root with `meetings/` and
`dictations/` subfolders, the server uses those subfolders automatically. In
that mode the SQLite index also defaults to the shared root unless
`TRANSCRIPTED_INDEX_DIR` is set.

## Package Layout (22 Swift files)

- `Package.swift` — Swift package manifest for the standalone MCP server
- `Sources/TranscriptedMCP/` — 11 source files for server startup, directory resolution, path validation, indexing, semantic embedding, telemetry, and tool handlers
- `Tests/TranscriptedMCPTests/` — 11 test files for directory resolution, index lifecycle, structured-summary indexing, summary rollups, semantic search, tool handlers, markdown loading, logging, telemetry, name variants, and shared fixtures

## File Index

| File | Purpose |
|------|---------|
| `Main.swift` | `@main` entry point; resolves directories, builds the index, starts file watchers, then starts the MCP stdio server |
| `DataDirectories.swift` | Index-dir resolution plus a thin wrapper over `TranscriptedCaptureKit`'s shared capture-library resolver |
| `ToolHandlers.swift` | Registers every MCP tool and routes requests to the correct loader or index method |
| `TranscriptIndex.swift` | SQLite-backed index, incremental updates, and query methods across meetings and dictations |
| `TranscriptLoader.swift` | Loads markdown meeting transcripts and dictation day files from disk; parsing delegates to `TranscriptedCaptureKit` |
| `Models.swift` | Codable input/output models and `MCPIndexError` |
| `SemanticEmbedding.swift` | On-device sentence-embedding seam (Apple `NLEmbedding`), vector blob codec, and utterance chunker behind `semantic_search` |
| `NameVariants.swift` | Speaker-name fuzzy matching for speaker-aware queries |
| `PathSecurity.swift` | Guards direct file reads against traversal, symlinks, and out-of-root paths |
| `FileWatcher.swift` | Watches the local transcript directories and incrementally reindexes changed files |
| `AgentCaptureQueryTelemetry.swift` | Anonymous bucketed telemetry for agent capture queries |

## Test Files

| File | Purpose |
|------|---------|
| `DataDirectoriesTests.swift` | Directory-resolution coverage for current Transcripted captures vs legacy Draft fallback |
| `TranscriptIndexTests.swift` | Full index lifecycle: reconcile, query, date filters, speaker search, and mixed-context indexing |
| `SummaryItemIndexTests.swift` | Structured summary parse→index→query: decisions/action-items/open-questions, owner + unassigned rollup, reindex/delete, sidecar-not-a-meeting |
| `TranscriptLoaderTests.swift` | Markdown and YAML frontmatter parsing edge cases, including path-safety checks |
| `LoggingTests.swift` | JSON log emission coverage for MCP startup and indexing diagnostics |
| `NameVariantsTests.swift` | Name variant matching accuracy |
| `SummaryRollupTests.swift` | Cross-meeting rollups: action items by owner/status/date, decisions, digest, write-seam idempotency |
| `SemanticSearchTests.swift` | Semantic retrieval mechanics: chunking, cosine ranking, kind/date filters, reindex cleanup, model-unavailable fallback (deterministic fake embedding) |
| `ToolHandlersTests.swift` | Handler-level coverage: title hydration, telemetry, status tool payload, self-describing empty results, done-filter error, read pagination windows and size guard |
| `AgentCaptureQueryTelemetryTests.swift` | Bucketing and payload coverage for agent capture-query telemetry |
| `TestHelpers.swift` | Shared fixture builders for sample transcripts and temp directories |

## MCP Tools

All tools are read-only.

| Tool | Description |
|------|-------------|
| `list_meetings` | List saved meetings with metadata and optional date filters |
| `read_meeting` | Read one meeting transcript by filename; `section` (`full`/`transcript`/`speakers`) plus optional `offset`/`limit` utterance paging |
| `list_dictations` | List saved dictation day files with counts, source apps, and titles |
| `read_dictation` | Read one dictation day, one specific entry by `entry_id`, or a paged window of entries via `offset`/`limit` |
| `search` | Search meeting transcript content |
| `search_context` | Search across meetings, dictations, or both |
| `semantic_search` | Meaning-based (embedding) search across meetings and dictations; finds paraphrases lexical search misses |
| `recent_context` | Get a mixed recent feed of meetings and dictations |
| `who_is` | Look up a speaker profile across saved meetings |
| `recap` | Build a structured digest for a date range |
| `list_action_items` | Roll up action items across meetings; filter by owner / status (`open`/`all`; `done` is rejected with an explicit error) / query / date |
| `list_decisions` | Roll up decisions across meetings; filter by query / date |
| `digest` | Cross-meeting summary (decisions + action items + open questions) for a window |
| `status` | Server version, resolved capture directories and which resolution rule selected them, index location, and indexed counts |

The last three are cross-meeting rollups over the structured summary fields and
query the same `meeting_summary_items` index populated from saved meeting
Markdown during reconcile.

## Common Agent Retrieval Shapes

Use these tool patterns for the most common questions:

- latest meeting: `list_meetings` with `{"count": 3}` or `recent_context` with `{"kind":"meeting","count":3}`
- meetings by speaker: `search` with `{"query":"topic","speaker":"Name"}` or `who_is` with `{"speaker":"Name"}`
- recent mixed context: `recent_context` with `{"count":10}`
- dictations by day: `list_dictations` with `{"date":"2026-04-29"}`, then `read_dictation` with the returned filename

## Data Flow

```text
meetings/*.md + dictations/*.md
  -> TranscriptLoader direct reads for read_meeting and read_dictation
  -> TranscriptIndex.reconcile() on startup
  -> FileWatcher incremental updates on change
  -> SQLite index
```

## Index Shape

The SQLite index keeps separate records for:

- meetings
- meeting speakers / utterance search rows
- structured meeting-summary items (Decisions / Action Items with owner / Open Questions), one row per bullet in `meeting_summary_items` with a `kind` discriminator + FTS5, so cross-meeting tools can roll up across all meetings
- dictation day files
- dictation entry search rows
- semantic chunks (one normalized on-device sentence embedding per chunk of consecutive meeting utterances or per dictation entry) behind `semantic_search`

Structured summary items are parsed via `TranscriptedCaptureKit.CaptureSummaryParser` from each meeting's inline local summary (or a `<stem>.summary.md` sidecar fallback) during `indexMeeting`. `TranscriptIndex.listSummaryItems(kind:owner:dateFrom:dateTo:)` is the cross-meeting query foundation behind `list_action_items`, `list_decisions`, and `digest`.

This lets the server answer both meeting-specific queries (`who_is`, `read_meeting`) and mixed-context queries (`search_context`, `recent_context`) without touching app-owned runtime state.

## Build And Test

```bash
cd Tools/TranscriptedMCP
swift build -c release
swift test
./.build/release/transcripted-mcp --help
./.build/release/transcripted-mcp --self-test
```

Binary path after build:

```text
.build/release/transcripted-mcp
```

`--self-test` verifies directory resolution, builds the SQLite index, prints a
JSON status payload, and exits without starting the MCP stdio server.

App builds also bundle a signed copy at:

```text
Transcripted.app/Contents/Helpers/transcripted-mcp
```

The in-app Claude Desktop installer copies that helper into:

```text
~/Library/Application Support/Transcripted/mcp/transcripted-mcp
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

- reads meeting markdown transcripts written by `Sources/TranscriptedCore/Storage/TranscriptSaver.swift`
- reads dictation markdown day files written by `Sources/Dictation/DictationTranscriptWriter.swift`
- shares capture-library resolution and capture-Markdown parsing with `Tools/TranscriptedCLI` through `Tools/TranscriptedCaptureKit`; change that logic in the kit, not here
- mirrors speaker-name matching logic from the app with `NameVariants.swift`
- has no compile-time dependency on the main Transcripted app target

## Gotchas

- transport is stdio, not HTTP
- direct file reads are path-validated and reject traversal or symlink escapes
- the server auto-creates missing data and index directories
- the index rebuilds from disk on startup
- `recent_context` is intentionally mixed; for the latest meeting specifically, prefer `list_meetings` or `recent_context` with `kind: "meeting"`
- `recap` and `recent_context` previews prefer the meeting's structured summary (decisions / action items) and only fall back to opening dialogue when a meeting has no summary — the first lines of a real call are greetings and audio checks
- `semantic_search` embeds with Apple's on-device `NLEmbedding` sentence model (English-optimized, nothing leaves the machine). When the model asset is unavailable the tool says so and lexical `search`/`search_context` keep working; indexing simply skips semantic rows. Embedding happens at index time, so the first rebuild after upgrading pays a one-time cost proportional to library size
- zero-result queries return a self-describing JSON payload (`searched_directories`, indexed counts, `hint`) instead of a bare "not found" string; call `status` to see the full resolution + index picture
- `read_meeting` and `read_dictation` read markdown directly from disk, not from the SQLite index
- both read tools carry a size guard: raw dumps larger than `maxUnpaginatedReadCharacters` (~30k chars) — or any call passing `offset`/`limit` — come back as a paginated JSON window (`total_utterances`/`total_entries`, `offset`, `returned`, `truncated`, `next_offset`, `hint`) instead of the full markdown; small unpaginated reads stay byte-identical raw markdown, and `entry_id` reads are unaffected
- source builds can run the server standalone, but shipped app builds bundle the helper for the one-click Claude Desktop installer
