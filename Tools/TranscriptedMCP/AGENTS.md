# TranscriptedMCP

Standalone stdio MCP server (`transcripted-mcp`) for querying saved Transcripted meetings, dictations, and writing from Claude Desktop or any MCP client. Setup and client config are in [README.md](README.md).

It never writes capture data and has no compile-time dependency on the app target. It builds its own SQLite index from the Markdown on disk, plus a small companion bridge to the running app (see Companion).

## Where it reads

Resolution is shared with `Tools/TranscriptedCLI` through `Tools/TranscriptedCaptureKit`; change it there, not here.

1. App-selected capture library: `~/Library/Application Support/Transcripted/mcp-directories.json` or the saved `transcriptSaveLocation` preference.
2. `~/Library/Application Support/Transcripted/captures/{meetings,dictations,writing}`. Index in `~/Library/Application Support/Transcripted/cache`.
3. Legacy: `~/Library/Application Support/Draft/{meetings,dictations}/transcripts`, then `~/Documents/Transcripted`.

Overrides: `TRANSCRIPTED_DATA_DIR`, `TRANSCRIPTED_MEETINGS_DIR`, `TRANSCRIPTED_DICTATIONS_DIR`, `TRANSCRIPTED_WRITING_DIR`, `TRANSCRIPTED_INDEX_DIR`.

- A `TRANSCRIPTED_DATA_DIR` with `meetings/`, `dictations/`, or `writing/` subfolders uses them. Otherwise every kind reads the root, kinds are told apart by filename prefix and `capture_type` (a `Writing_` file is never a meeting), and the index defaults to that root unless `TRANSCRIPTED_INDEX_DIR` is set.
- With a meetings or dictations override and no writing override, no writing folder is read, so per-kind test harnesses cannot reach the real one.
- Startup creates missing meeting, dictation, and index dirs, never the writing dir (the app creates it).

## Tools

All read-only. Registered in `ToolHandlers.swift`; bodies live in `ToolHandlers+*.swift`.

| Family | Tools |
|--------|-------|
| Meetings | `list_meetings`, `read_meeting` (`section` full/transcript/speakers, `offset`/`limit`) |
| Dictations | `list_dictations`, `read_dictation` (day, `entry_id`, or `offset`/`limit`) |
| Writing | `list_writing`, `read_writing` (same shape as dictations) |
| Search | `search`, `search_context` (meetings/dictations/writing/all; writing is full-text only), `recent_context`, `who_is`. `mode` is `hybrid` (default), `lexical`, or `semantic` |
| Rollups | `recap`, `list_action_items` (`done` status is rejected with an explicit error), `list_decisions`, `digest` |
| Receipts | `decisions`, `commitments`, `open_questions`, `search_meetings` (share `handleReceiptQuery`) |
| Diagnostics | `status`: version, resolved dirs and which rule chose them, index location, counts |
| MCP Apps | `show_recent_meetings` returns a `ui://` HTML widget plus `structuredContent` (`UIResourceHandlers.swift`) |

Rollups and receipts read local `meeting_summary_items` and utterance FTS. No embeddings, cloud calls, or LLM synthesis.

Common shapes:

- latest meeting: `list_meetings {"count":3}` or `recent_context {"kind":"meeting","count":3}`. `recent_context` is a mixed feed by default.
- by speaker: `search {"query":"topic","speaker":"Name"}` or `who_is {"speaker":"Name"}`
- dictations by day: `list_dictations {"date":"2026-04-29"}`, then `read_dictation` with the returned filename

## Companion

A separate tool surface that talks to the running app over a local socket: `show_companion`, `get_recording_status`, `start_meeting`, `stop_meeting`, `set_live_context_sharing`, `read_live_transcript`, `get_live_meeting_context`, `browse_companion_context`, `read_context_passage`. Resource `transcripted_companion` (`text/html;profile=mcp-app`).

- `CompanionClient.swift` reads `<Application Support>/Transcripted/companion/connection.json` (root overridable with `TRANSCRIPTED_CONTAINER_DIR`). It requires owner-only dir and socket, no symlinks, socket inside the root. Keep those checks strict. It never logs credentials, paths, or native payloads.
- `CompanionTools.swift` keeps view data in tool-result `_meta` so it stays out of model context until the user attaches it.
- `CompanionUI.swift` is self-contained: no analytics, network fetches, audio, or model replies.
- `CompanionTransport.swift` wraps `BlockingStdioTransport` and only rewrites the `initialize` experimental-capabilities field (SDK 0.12 expects strings, MCP Apps hosts send objects). Never rewrite tool requests or replies.
- `test-support/companion_preview.py` is a fixture-only preview with an invented socket. No app, mic, or real library.

## Data flow and index

```text
captures/*.md -> TranscriptLoader (direct reads: read_meeting/read_dictation/read_writing)
              -> TranscriptIndex.reconcile() at startup -> FileWatcher incremental updates -> SQLite
```

- Index tables: meetings, speakers and utterance rows, `meeting_summary_items` (one row per Decision / Action Item with owner / Open Question, `kind` discriminator, FTS5), dictation days and entries, `writing_days` / `writing_entries` + FTS5. Schema version is 6 (`TranscriptIndex.swift`); an older `user_version` rebuilds from disk. DDL is in `TranscriptIndex+Schema.swift`.
- Summary items come from `TranscriptedCaptureKit.CaptureSummaryParser` over legacy artifacts (inline summary or `<stem>.summary.md` sidecar) during `indexMeeting`. Current app capture does not create new AI summaries. Cross-meeting queries go through `TranscriptIndex.listSummaryItems(kind:owner:dateFrom:dateTo:)`.
- `FileWatcher` debounces 500ms and also scans on a 5-minute timer.

## Semantic search

On-device, to catch paraphrases FTS misses. Embeddings come from Apple `NLEmbedding.sentenceEmbedding` (no bundled model or download), behind the `EmbeddingProvider` protocol so a CoreML model can replace it.

- Separate SQLite connection (`EmbeddingStore`), additive tables `embedding_meta`, `utterance_vectors`, `dictation_entry_vectors` (Float32 BLOBs keyed by lexical `rowid`), plus `embedding_cache` (content-keyed reuse, 72h TTL, cleared on model change; old helpers ignore it). Never alters the lexical write path.
- Backfill: at most 100 missing rows per page by rowid; each table pass fixes its upper rowid first, advances past nil results, checks cancellation between provider calls. Reads are finalized and provider work finishes before short write transactions. Rows past the boundary wait for the next pass. Everything re-embeds on model-id or dimension change.
- `mcp_index.embed.lock` is a per-pass cross-process lock around `reconcileEmbeddings`. On timeout or open failure, backfill defers to a later reconcile (or the watcher's first 5-minute tick); it never runs an unlocked competing pass or unlinks a live lock. Exited holders release automatically. Until the first model reconciliation succeeds, semantic queries use the lexical fallback.
- Hybrid fuses FTS and semantic with reciprocal-rank fusion (`SemanticSearchFusion.swift`) and is a superset of FTS recall. If the backend is unavailable (for example missing OS language assets) the store is never created and every mode runs lexical-only. NLEmbedding's similarity floor is high, so `semantic` alone is best-effort.

## Files

All under `Sources/TranscriptedMCP/`:

| File | Owns |
|------|------|
| `Main.swift` | Entry point, `--help` / `--version` / `--self-test`, startup order, watchers |
| `BlockingStdioTransport.swift`, `Companion*.swift` | Transport and companion bridge above |
| `DataDirectories.swift`, `PathSecurity.swift` | Index-dir resolution over the kit resolver; traversal/symlink guard for direct reads |
| `ToolHandlers.swift`, `ToolHandlers+*.swift` | Registration and per-family handlers |
| `UIResourceHandlers.swift`, `RecentMeetingsWidget*.swift` | MCP Apps widget, model, builder |
| `TranscriptIndex.swift`, `TranscriptIndex+*.swift` | Connection lifecycle, schema gate, reconcile, per-kind queries |
| `SQLiteHelpers.swift` | Plumbing shared by `TranscriptIndex` and `EmbeddingStore` |
| `EmbeddingProvider.swift`, `EmbeddingStore.swift`, `SemanticSearchFusion.swift` | Semantic layer |
| `TranscriptLoader.swift` | Loads and classifies files (writing first, so it never falls into the meeting default); parsing is the kit's |
| `Models.swift`, `NameVariants.swift`, `FileWatcher.swift` | Codable models and `MCPIndexError`, speaker-name fuzzy matching (mirrors the app's), incremental reindex |
| `AgentCaptureQueryTelemetry.swift` | One anonymous, bucketed terminal event per tracked capture query |

Also `mcpb/manifest.json` (Claude Desktop bundle manifest; its tool list must match the tools you ship).

## Build and test

```bash
cd Tools/TranscriptedMCP
swift build -c release && swift test
./.build/release/transcripted-mcp --self-test   # resolves dirs, builds index, prints status JSON, exits
```

- `Tests/TranscriptedMCPTests/` covers directory resolution, index lifecycle, summary rollups, tool handlers, loader and frontmatter parity, embeddings (backfill, cache, search), transports, companion, widget, telemetry, and writing. `ProcessStartupTests` launches the built executable for a real `initialize` round trip. `TestHelpers.swift` has the fixtures.
- App builds bundle a signed copy at `Transcripted.app/Contents/Helpers/transcripted-mcp`. The in-app Claude Desktop installer copies it to `~/Library/Application Support/Transcripted/mcp/transcripted-mcp`.

## Gotchas

- Transport is stdio, not HTTP.
- Do not switch back to the SDK's `StdioTransport`: 0.12 sets O_NONBLOCK on the client's fds and polls stdin every 10 ms forever (~0.5% of a core, ~200 context switches/s per idle server) and sleeps 10 ms per full pipe on large replies. `BlockingStdioTransport` sleeps in read(2)/poll(2). Running servers keep the old binary until their client restarts.
- `read_meeting`, `read_dictation`, `read_writing` read Markdown from disk, not the index, and are path-validated against traversal and symlink escapes.
- Read size guard: raw dumps over `maxUnpaginatedReadCharacters` (30,000 chars), or any call with `offset`/`limit`, return a paginated JSON window (`total_utterances`/`total_entries`, `offset`, `returned`, `truncated`, `next_offset`, `hint`). Small unpaginated reads stay byte-identical raw Markdown; `entry_id` reads are unaffected.
- Zero-result queries return self-describing JSON (`searched_directories`, counts, `hint`), not a bare "not found". `status` gives the full picture.
- Telemetry: `app_version` is the owning app version written by the installer, never `TranscriptedMCP.serverVersion`; omit it if missing rather than invent it. `source_count_bucket` counts distinct capture files, `result_count_bucket` counts returned records at the tool's natural grain.
- The index rebuilds from disk on startup, so it is disposable.
