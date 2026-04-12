# Connect Your Agent

Transcripted is easiest to use when the connection story stays focused on one main action:

1. Copy one smart prompt.
2. Let your agent use MCP if it is already available.
3. Fall back to folders only when you need manual setup.

## Main Path: Copy One Prompt

This is the default path for most people.

- Open `Connect your agent` in the app.
- Copy the agent prompt.
- Paste it into your agent.
- Ask normal questions like:
  - what did I miss today
  - summarize my latest meeting
  - find every time we discussed pricing
  - pull action items from my latest meeting and dictations

The copied prompt tells the agent to:

- use Transcripted MCP tools first if they are already connected
- otherwise read the local Transcripted folders directly
- help you set up the better option if neither path is ready yet

The intended user path is:

- click `Connect your agent`
- copy the prompt
- paste it into your agent
- let the agent use MCP first or fall back to the saved folders

Current local folders:

- meetings: `~/Library/Application Support/Transcripted/captures/meetings`
- dictations: `~/Library/Application Support/Transcripted/captures/dictations`

The meetings folder also contains:

- `transcripted.json` — index of saved meeting transcripts

## Optional: MCP

Use MCP when your client supports it and you want direct read-only tools instead
of asking the model to inspect files manually.

Current `transcripted-mcp` capabilities:

- `recent_context`
- `search_context`
- `list_meetings`
- `read_meeting`
- `list_dictations`
- `read_dictation`
- `search`
- `who_is`
- `recap`

### What it gives the user

- one place to search meetings and dictations together
- fast recaps over a date range
- direct access to one meeting or one dictation entry
- people lookups without hand-rolling folder searches
- read-only access to local Transcripted data

### Repo Setup

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

- `transcripted-mcp` communicates over stdio, not HTTP.
- By default it reads Transcripted data from the current Draft-named app-support folders.
- If needed, override paths with `TRANSCRIPTED_DATA_DIR`,
  `TRANSCRIPTED_MEETINGS_DIR`, `TRANSCRIPTED_DICTATIONS_DIR`, and
  `TRANSCRIPTED_INDEX_DIR`.
