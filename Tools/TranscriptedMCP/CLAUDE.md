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

## Package Layout (20 Swift files)

- `Package.swift` — Swift package manifest for the standalone MCP server
- `Sources/TranscriptedMCP/` — 12 source files for server startup, directory resolution, path validation, indexing, structured summaries, semantic search, and tool handlers
- `Tests/TranscriptedMCPTests/` — 9 test files for directory resolution, index lifecycle, structured-summary indexing, summary rollups, markdown loading, logging, name variants, semantic search, and shared fixtures

## File Index

| File | Purpose |
|------|---------|
| `Main.swift` | `@main` entry point; resolves directories, builds the index (with an `NLEmbeddingProvider` for semantic search), starts file watchers, then starts the MCP stdio server |
| `DataDirectories.swift` | Index-dir resolution plus a thin wrapper over `TranscriptedCaptureKit`'s shared capture-library resolver |
| `ToolHandlers.swift` | Registers every MCP tool and routes requests to the correct loader or index method |
| `TranscriptIndex.swift` | SQLite-backed index, incremental updates, and query methods across meetings and dictations; routes `lexical`/`semantic`/`hybrid` search modes |
| `EmbeddingProvider.swift` | `EmbeddingProvider` protocol, the default `NLEmbeddingProvider` (Apple NaturalLanguage, zero-bundle on-device), `SearchMode`, and `VectorMath` helpers |
| `EmbeddingStore.swift` | Vector store on its own SQLite connection; embeds rows, stores Float32 vectors, and runs cosine semantic search over utterances and dictation entries |
| `SemanticSearchFusion.swift` | Reciprocal-rank fusion that merges lexical (FTS) and semantic result lists for hybrid search |
| `TranscriptLoader.swift` | Loads markdown meeting transcripts and dictation day files from disk; parsing delegates to `TranscriptedCaptureKit` |
| `Models.swift` | Codable input/output models and `MCPIndexError` |
| `NameVariants.swift` | Speaker-name fuzzy matching for speaker-aware queries |
| `PathSecurity.swift` | Guards direct file reads against traversal, symlinks, and out-of-root paths |
| `FileWatcher.swift` | Watches the local transcript directories and incrementally reindexes changed files |

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
| `SemanticSearchTests.swift` | Semantic + hybrid search via a deterministic stub provider, graceful fallback, model-change re-embed, vector-math, and RRF fusion |
| `TestHelpers.swift` | Shared fixture builders for sample transcripts and temp directories |

## MCP Tools

All tools are read-only.

| Tool | Description |
|------|-------------|
| `list_meetings` | List saved meetings with metadata and optional date filters |
| `read_meeting` | Read one meeting transcript by filename |
| `list_dictations` | List saved dictation day files with counts, source apps, and titles |
| `read_dictation` | Read one dictation day or one specific dictation entry |
| `search` | Search meeting transcript content (lexical / semantic / hybrid via `mode`, default hybrid) |
| `search_context` | Search across meetings, dictations, or both (same `mode` options) |
| `recent_context` | Get a mixed recent feed of meetings and dictations |
| `who_is` | Look up a speaker profile across saved meetings |
| `recap` | Build a structured digest for a date range |
| `list_action_items` | Roll up action items across meetings; filter by owner / status / query / date |
| `list_decisions` | Roll up decisions across meetings; filter by query / date |
| `digest` | Cross-meeting summary (decisions + action items + open questions) for a window |

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

Structured summary items are parsed via `TranscriptedCaptureKit.CaptureSummaryParser` from each meeting's inline local summary (or a `<stem>.summary.md` sidecar fallback) during `indexMeeting`. `TranscriptIndex.listSummaryItems(kind:owner:dateFrom:dateTo:)` is the cross-meeting query foundation behind `list_action_items`, `list_decisions`, and `digest`.

This lets the server answer both meeting-specific queries (`who_is`, `read_meeting`) and mixed-context queries (`search_context`, `recent_context`) without touching app-owned runtime state.

The semantic layer adds three additive tables on a separate connection: `embedding_meta` (model id + dimension), `utterance_vectors`, and `dictation_entry_vectors` (Float32 BLOBs keyed by the lexical rows' `rowid`). They never alter the lexical write path.

## Semantic Search

Local, on-device semantic search complements FTS so paraphrase queries hit (e.g. "pricing pushback" finds "they balked at the cost").

- Embeddings come from Apple's `NaturalLanguage` `NLEmbedding.sentenceEmbedding` — **no bundled model, no download, negligible app-size impact**. Backend is pluggable via `EmbeddingProvider`, so a bundled CoreML model can replace it later without touching the store or search path.
- `EmbeddingStore` embeds new/changed rows after each reconcile (lazily, keyed by `rowid`), re-embeds everything on a model-id/dimension change, and runs a streaming cosine scan with the same speaker/date filters as FTS.
- `search` / `search_context` accept `mode`: `hybrid` (default — FTS + semantic fused with reciprocal-rank fusion, a strict superset of FTS recall), `lexical`, or `semantic`.
- All modes degrade gracefully: if the embedding backend is unavailable (e.g. missing OS language assets), the store is never created and every mode runs lexical-only.
- NLEmbedding's similarity floor is high, so `semantic` alone is best-effort; `hybrid` is rank-based and stays robust because exact FTS hits anchor precision.

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
- `read_meeting` and `read_dictation` read markdown directly from disk, not from the SQLite index
- source builds can run the server standalone, but shipped app builds bundle the helper for the one-click Claude Desktop installer
