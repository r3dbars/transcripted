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
