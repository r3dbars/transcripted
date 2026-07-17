# Transcripted MCP

Read-only local tools for Transcripted meetings and dictations.

For Claude Desktop users, the best setup is inside the app:

1. Open Transcripted.
2. Open Settings.
3. Go to `Agent`.
4. Click `Install in Claude`.
5. Restart Claude Desktop.

That path installs the bundled helper, updates Claude Desktop's config, and
runs a local self-test.

## Interactive UI (MCP Apps)

The server exposes one interactive widget via the MCP Apps extension
(`io.modelcontextprotocol/ui`, SEP-1865): call `show_recent_meetings` to render a
card list of recent meetings — each with inline audio playback and a raw-transcript
view — that draws inside a rendering-capable client. It is fully self-contained
(no network; local audio/transcripts travel over the local transport), and falls
back to a plain-text list in clients that do not render inline UI (e.g. the Claude
Code CLI). Renders inline today in ChatGPT, VS Code, Cursor, and Goose; see
[`docs/mcp-ui-recent-meetings.md`](../../docs/mcp-ui-recent-meetings.md) for the
per-client support matrix and how to try it.

## Source Build

Use this only when developing the MCP server directly:

```bash
swift build -c release
swift test
```

Binary:

```text
.build/release/transcripted-mcp
```

Self-test:

```bash
.build/release/transcripted-mcp --self-test
```

The server reads the app-selected capture library first when Transcripted has
written its local directory manifest or `transcriptSaveLocation` preference.
Without a custom library, it reads:

```text
~/Library/Application Support/Transcripted/captures/meetings
~/Library/Application Support/Transcripted/captures/dictations
```

Override paths with `TRANSCRIPTED_DATA_DIR`, `TRANSCRIPTED_MEETINGS_DIR`,
`TRANSCRIPTED_DICTATIONS_DIR`, or `TRANSCRIPTED_INDEX_DIR`.
If `TRANSCRIPTED_DATA_DIR` points at a shared root with `meetings/` and
`dictations/` subfolders, `transcripted-mcp` uses those subfolders
automatically and stores its SQLite index in that shared root unless
`TRANSCRIPTED_INDEX_DIR` is also set.

## Telemetry

The server can emit one anonymous PostHog event when each tracked capture query
finishes (`agent_capture_query_observed`, see
`AgentCaptureQueryTelemetry.swift`). `result` is one of `success`,
`empty_not_found`, `invalid_input`, or `internal_error`. The payload is limited
to coarse allowlisted metadata: client, tool, and capture kinds; latency and
source- and result-count buckets; the result; and the owning app's validated
`app_version`, build channel, and revision when available. Build identity is
omitted when the app did not install it; the helper's own server version is
never used as an app-version fallback. `source_count_bucket` means distinct
capture files contributing to the response. `result_count_bucket` means
returned records at that tool's natural response grain. Transcript text, query strings, capture IDs,
titles, names, file paths, audio, and user identifiers are never properties.

It is gated twice:

- it honors the app's anonymous analytics toggle
  (`observability-anonymous-analytics-enabled`; off means nothing is sent)
- it no-ops entirely unless a PostHog API key and HTTPS host are configured via
  `POSTHOG_API_KEY`/`POSTHOG_HOST`, a local override, or the bundle's
  `TranscriptedPostHogAPIKey`; source builds have none by default

Transcripts and audio never leave the Mac in any mode.

## Cross-Meeting Receipt Tools

WS2.3 adds local structured retrieval tools for agents:

- `decisions(topic, range)`
- `commitments(person, range)`
- `open_questions(project, range)`
- `search_meetings(query, range)`

Each returns JSON receipts shaped around `meetingId`, `timestamp`, and `quote`.
Summary-derived receipts have `timestamp: null` until exact audio anchors are
available; raw utterance search includes the transcript timestamp. These tools
use only the local SQLite index and saved summary/parser output.
