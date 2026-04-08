# Connect Your Agent

Transcripted is easiest to use when the connection story is simple:

1. Start with a prompt.
2. Use MCP when your agent supports it.
3. Use the CLI when you want scripts or automation.

## Start Here: Any Agent

This is the default path for most people.

- Open `Connect your agent` in the app.
- Copy the starter prompt.
- Paste it into your agent.
- Ask normal questions like:
  - what did I miss today
  - summarize my latest meeting
  - find every time we discussed pricing
  - pull action items from my latest meeting and dictations

Current local folders:

- meetings: `~/Library/Application Support/Draft/meetings/transcripts`
- dictations: `~/Library/Application Support/Draft/dictations/transcripts`

The meetings folder also contains:

- `AGENT.md` — plain-English structure guide for file-based agents
- `transcripted.json` — index of saved meeting transcripts

## Better Connection: MCP

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

## Advanced: CLI

Use the CLI when you want terminal access, scripts, automation, or offline audio
processing.

### Context Commands

```bash
cd Tools/TranscriptedCLI
swift run transcripted-cli context-recent
swift run transcripted-cli context-search "roadmap"
swift run transcripted-cli list-dictations
swift run transcripted-cli read-dictation Dictations_YYYY-MM-DD
```

### Diarization Commands

```bash
cd Tools/TranscriptedCLI
swift run transcripted-cli diarize /path/to/audio.wav --json
swift run transcripted-cli batch /path/to/folder --ext wav
```

Notes:

- the context commands read the same local Transcripted folders as the app and
  MCP server
- the diarization commands are separate offline audio tools
- the CLI depends on repo-level dependency artifacts, so run `bash build-deps.sh`
  first if they are missing
