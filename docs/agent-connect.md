# Connect Your Agent

The setup should feel like this:

1. Pick the app you use.
2. Click `Connect`.
3. Restart the agent, or paste the copied prompt for agents we cannot configure directly.

No manual JSON for normal users. No source build for DMG installs.

The Agent page shows one row per agent found on the Mac — Claude Desktop,
Claude Code, Codex, Cursor — each with a single `Connect` button. Every row
points that agent's own MCP config at the same installed `transcripted-mcp`
helper. Agents we cannot configure directly use the universal copy-prompt row.

## Claude Desktop

1. Open Transcripted.
2. Open Settings.
3. Go to `Agent`.
4. Click `Connect` on the Claude Desktop row.
5. Restart Claude Desktop.

After restart, ask Claude:

```text
Use Transcripted to summarize my latest meeting. Tell me which Transcripted source you used, including the filename/date, then list decisions and action items.
```

Tomorrow, ask:

```text
Review yesterday. Use recent context or a recap to tell me what I promised, what changed, and what I should follow up on today.
```

Claude answers from Transcripted's read-only direct tools. If those tools are
unavailable, use the local-agent prompt below so an agent can fall back to the
saved Markdown folders.

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

The installed helper is self-healing: at app launch, Transcripted compares the
installed helper against the one bundled in the current app build and silently
replaces it when they differ. Users should never have to think about a stale
helper. If the silent refresh fails (for example a permissions problem), the
Agent page surfaces the error on the affected row and `Connect` performs a
full reinstall.

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

These tools are read-only, but they are not redacted. `read_meeting` and
`read_dictation` can return local transcript text to the agent you connected.

## Local Coding Agents

Claude Code, Codex, and Cursor get the same one-click `Connect` as Claude
Desktop:

- Claude Code — registered through the `claude` CLI (`claude mcp add --scope user`), so the CLI keeps ownership of `~/.claude.json`.
- Codex — a conservative text-level edit of `~/.codex/config.toml` that only touches the `[mcp_servers.transcripted]` table.
- Cursor — the same safe `mcpServers` JSON merge as Claude Desktop, written to `~/.cursor/mcp.json`.

For everything else (Windsurf, Zed, OpenCode, OpenClaw, Cline, Continue,
VS Code agents, web chats), the user copies the universal prompt from the
`Something else` row, pastes it into the agent, and asks normal questions like:

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
3. Turn on `Live meetings`.
4. Click `Open Live View` for a live transcript page, or open the tokenized browser preview URL from `agent-live-meeting.md` in Codex's in-app browser.
5. For a dedicated agent meeting room, expand `Advanced` and click `Open in Codex`, or `Copy for Cowork` and paste that setup prompt into Claude Cowork.

While a meeting is recording, the meeting overlay pill also has a live
transcript button: it expands an embedded transcript drawer right inside the
overlay, with the browser/agent view one more click away from the drawer
header. If live meetings is still off, that button turns it on in the same
click; live transcript lines then begin with the next recording (live ASR
cannot attach to a capture that is already running), while the current
meeting's final transcript still links into the live page when it saves.

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
