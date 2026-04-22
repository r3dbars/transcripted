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
- otherwise read any Transcripted folders you granted in that chat
- fall back to the default local Transcripted folders when they are readable
- for Claude Desktop, use the in-app installer instead of source-build setup

The intended user path is:

- click `Connect your agent`
- copy the prompt
- paste it into your agent
- let the agent use MCP first or fall back to the saved folders

Current local folders:

- meetings: `~/Library/Application Support/Transcripted/captures/meetings`
- dictations: `~/Library/Application Support/Transcripted/captures/dictations`

## Optional: MCP

Use MCP when your client supports it and you want direct read-only tools instead
of asking the model to inspect files manually.

If you installed Transcripted from the DMG, you should not need to clone the
repo or build the MCP server yourself.

### Claude Desktop

Use the in-app setup:

1. Open Transcripted.
2. Open Settings.
3. Go to `Agent`.
4. Click `Install for Claude Desktop`.
5. Restart Claude Desktop.

Transcripted copies the bundled `transcripted-mcp` helper into:

```text
~/Library/Application Support/Transcripted/mcp/transcripted-mcp
```

Then it safely merges this entry into Claude Desktop's config:

```text
~/Library/Application Support/Claude/claude_desktop_config.json
```

Existing MCP servers are preserved. If the config is invalid JSON,
Transcripted backs it up before writing a clean config.

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

### Source Build Fallback

This is for contributors working from a checkout. Normal DMG installs should use
the Claude Desktop button in Transcripted Settings.

```bash
cd Tools/TranscriptedMCP
swift build -c release
```

Binary path after build:

```text
Tools/TranscriptedMCP/.build/release/transcripted-mcp
```

Example Claude Desktop config:

```json
{
  "mcpServers": {
    "transcripted": {
      "command": "/absolute/path/to/Tools/TranscriptedMCP/.build/release/transcripted-mcp"
    }
  }
}
```

Notes:

- `transcripted-mcp` communicates over stdio, not HTTP.
- By default it resolves Transcripted capture folders first, then falls back to legacy Draft or `~/Documents/Transcripted/` layouts if those are the only artifacts on disk.
- If needed, override paths with `TRANSCRIPTED_DATA_DIR`,
  `TRANSCRIPTED_MEETINGS_DIR`, `TRANSCRIPTED_DICTATIONS_DIR`, and
  `TRANSCRIPTED_INDEX_DIR`.
