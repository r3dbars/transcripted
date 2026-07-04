# Transcripted MCP

Read-only local tools for Transcripted meetings, dictations, and daily timelines.

For Claude Desktop users, the best setup is inside the app:

1. Open Transcripted.
2. Open Settings.
3. Go to `Agent`.
4. Click `Install in Claude`.
5. Restart Claude Desktop.

That path installs the bundled helper, updates Claude Desktop's config, and
runs a local self-test.

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
~/Library/Application Support/Transcripted/captures/timeline
```

Override paths with `TRANSCRIPTED_DATA_DIR`, `TRANSCRIPTED_MEETINGS_DIR`,
`TRANSCRIPTED_DICTATIONS_DIR`, `TRANSCRIPTED_TIMELINE_DIR`, or
`TRANSCRIPTED_INDEX_DIR`.
If `TRANSCRIPTED_DATA_DIR` points at a shared root with `meetings/` and
`dictations/` and `timeline/` subfolders, `transcripted-mcp` uses those subfolders
automatically and stores its SQLite index in that shared root unless
`TRANSCRIPTED_INDEX_DIR` is also set.

## Telemetry

The server can emit one anonymous PostHog event per successful tool call
(`agent_capture_query_observed`, see `AgentCaptureQueryTelemetry.swift`). The
payload is bucketed metadata only: query kind, artifact kind, capture-age
bucket, and source-count bucket. It is validated against an allow-list;
transcript text, query strings, titles, speaker names, file paths, and audio are
never sent.

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
