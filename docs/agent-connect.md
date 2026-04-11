# Connect Your Agent

Transcripted is easiest to use when the connection story stays simple:

1. Copy one smart prompt.
2. Prefer MCP if it is already available.
3. Fall back to folders when MCP is unavailable.

## Main Path: Copy One Prompt

This is the default path for most people.

- Open `Connect your agent` in the app.
- Copy the starter prompt.
- Paste it into your agent.
- Let the agent decide between MCP and folders.

The starter prompt tells the agent to:

- use Transcripted MCP tools first if they are already connected
- otherwise build or configure `transcripted-mcp` when possible
- otherwise read the local capture folders directly
- stop and explain exactly what is missing if neither path works

## Folder Fallback

By default the app stores captures here:

- meetings: `~/Library/Application Support/Transcripted/captures/meetings`
- dictations: `~/Library/Application Support/Transcripted/captures/dictations`

The meetings folder may also contain:

- `AGENT.md` — plain-English structure guide for file-based agents
- `CLAUDE.md` — the same guidance in Claude-oriented naming
- `transcripted.json` — index of saved meeting transcripts

Important note:

- the capture library is user-configurable in Settings, so the exact folder may differ on a given machine

## Optional: MCP

Use MCP when your client supports it and you want direct read-only tools
instead of asking the model to inspect files manually.

Current `transcripted-mcp` tools:

- `recent_context`
- `search_context`
- `list_meetings`
- `read_meeting`
- `list_dictations`
- `read_dictation`
- `search`
- `who_is`
- `recap`

## What MCP Gives You

- one read-only tool surface over meetings and dictations together
- faster search and recap flows than manual file walking
- direct meeting reads and dictation entry reads
- speaker lookups across saved meeting history

## Repo Setup

```bash
cd Tools/TranscriptedMCP
swift build
```

Binary path after build:

```text
Tools/TranscriptedMCP/.build/debug/transcripted-mcp
```

Example Claude Desktop config:

```json
{
  "mcpServers": {
    "transcripted": {
      "command": "/absolute/path/to/Tools/TranscriptedMCP/.build/debug/transcripted-mcp"
    }
  }
}
```

Notes:

- `transcripted-mcp` uses stdio, not HTTP
- by default it reads the Transcripted capture folders under Application Support
- it falls back to older Draft or `~/Documents/Transcripted` layouts only when the newer default folders are absent
- you can override directories with `TRANSCRIPTED_DATA_DIR`, `TRANSCRIPTED_MEETINGS_DIR`, `TRANSCRIPTED_DICTATIONS_DIR`, and `TRANSCRIPTED_INDEX_DIR`
