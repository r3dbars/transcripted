# Connect Your Agent

The setup should feel like this:

1. Pick the app you use.
2. Click one button.
3. Restart or paste the copied prompt.

No manual JSON for normal users. No source build for DMG installs.

## Best Path: Claude Desktop

Claude Desktop is the best full-library experience.

1. Open Transcripted.
2. Open Settings.
3. Go to `Agent`.
4. Click `Install in Claude`.
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

If the installed helper's `--self-test` prints many `[transcripted-mcp] Indexed`
lines before the JSON payload, the helper copied into Application Support is
stale. Click `Update Claude Helper` from Transcripted Settings to replace it
with the current bundled helper. The current helper should print only the JSON
self-test payload.

A stale helper can also pass `--self-test` but still behave like an older build,
for example if `transcripted-mcp --help` starts the MCP server instead of
printing usage. If Transcripted Settings says the direct tools need repair, or
the installed helper differs from the app-bundled helper, click the repair or
update button shown in Settings.

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

## Good Path: Local Coding Agents

Use this for local agents that can read files on the user's Mac.

Examples:

- Claude Code
- Codex
- Cursor
- Windsurf
- Zed
- OpenCode
- OpenClaw
- Cline
- Continue
- VS Code agents

The user copies the local-agent prompt from Transcripted, pastes it into the
agent, and asks normal questions like:

- what did I miss today
- summarize my latest meeting
- find every time we discussed pricing
- pull action items from my latest meeting and dictations

The copied prompt tells the agent to use Transcripted direct tools when they are
connected, otherwise read the saved Markdown folders:

```text
~/Library/Application Support/Transcripted/captures/meetings
~/Library/Application Support/Transcripted/captures/dictations
```

## Live Meeting Sidecar

This is an opt-in sidecar for Codex or Claude Cowork while a meeting is still recording.
The product contract lives in `docs/live-meeting-codex-sidecar.md`.

1. Open Transcripted Settings.
2. Go to `Agent`.
3. Turn on `Live meeting sidecar`.
4. Click `Open in Codex`, or click `Copy for Cowork` and paste that setup prompt into Claude Cowork.
5. Click `Open Preview` if you want a live transcript page, or open the tokenized browser preview URL from `agent-live-meeting.md` in Codex's in-app browser.

Transcripted creates:

```text
~/Library/Application Support/Transcripted/AgentLiveMeeting/
```

The folder contains `state.json`, `live_transcript.md`, `agent-handoff.md`,
`agent-watcher-state.json`, `agent-live-meeting.md`, and `preview.html`.
While Transcripted is running, the same preview updates in place at the
tokenized browser preview URL written into `agent-live-meeting.md`.

Rules:

- the live sidecar is provisional
- `[partial]` lines are live streaming ASR hypotheses and may change
- the normal meeting Markdown still saves after stop
- after save, `agent-handoff.md` becomes the automatic marker that points the agent at the final transcript
- once `state.json` has `finalTranscriptPath`, the agent should read that final
  Markdown for participant names, diarization, and durable notes
- before a watcher wakes the user about a ready final transcript, it should check
  `agent-watcher-state.json` and stay quiet if the final path was already handled
- live questions should be answered locally from the current sidecar
- if mic and system audio are duplicated, the agent should say so instead of
  treating both as separate speakers

## Fallback Only: Web Chat

Do not present web chat as a main setup path.

This includes:

- Claude web
- ChatGPT web
- mobile chats

These are usually a bad full-library experience because the chat cannot
reliably see the user's Mac or keep folder access. Use them only for:

- a pasted meeting bundle
- folders the user explicitly granted in that chat
- quick support/debugging

The copy should say this plainly: web chats are fallback only.

## Source Build Fallback

This is for contributors working from a checkout. Normal DMG installs should use
the Claude Desktop button in Transcripted Settings.

```bash
cd Tools/TranscriptedMCP
swift build -c release
./.build/release/transcripted-mcp --self-test
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
- `--self-test` verifies directory resolution, creates missing local data/index directories, and exits without starting the MCP stdio server.
- By default it follows the capture library chosen in Transcripted Settings, then also reads legacy Draft or `~/Documents/Transcripted/` layouts when those folders still contain capture Markdown.
- `TRANSCRIPTED_DATA_DIR` can point at a shared root with `meetings/` and `dictations/` subfolders. For `transcripted-mcp`, that shared root also becomes the default SQLite index location unless `TRANSCRIPTED_INDEX_DIR` is set.
- If needed, override paths with `TRANSCRIPTED_DATA_DIR`,
  `TRANSCRIPTED_MEETINGS_DIR`, `TRANSCRIPTED_DICTATIONS_DIR`, and
  `TRANSCRIPTED_INDEX_DIR`.
