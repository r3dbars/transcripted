# Transcripted MCP

Read-only local tools for Transcripted meetings and dictations.

For Claude Desktop users, the best setup is inside the app:

1. Open Transcripted.
2. Open Settings.
3. Go to `Agent`.
4. Click `Install for Claude Desktop`.
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

The server reads:

```text
~/Library/Application Support/Transcripted/captures/meetings
~/Library/Application Support/Transcripted/captures/dictations
```

Override paths with `TRANSCRIPTED_DATA_DIR`, `TRANSCRIPTED_MEETINGS_DIR`,
`TRANSCRIPTED_DICTATIONS_DIR`, or `TRANSCRIPTED_INDEX_DIR`.
