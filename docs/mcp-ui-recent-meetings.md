# MCP Apps: the recent-meetings widget

Transcripted's MCP server now ships one **interactive UI surface**: a "recent
meetings" widget that renders inline inside a rendering-capable agent client, as
a card list you can play and read from — not just a wall of text.

This is the first, minimal slice of the
[MCP Apps design](plans/mcp-host-apps-design.md) (Interpretation 2). It reuses the
existing read-only data surface; it adds a UI layer, not new data plumbing.

## What it does

Call the `show_recent_meetings` tool (optional `count`, default 5, max 15). It
returns a self-contained HTML widget: one card per recent meeting with

- title, date, duration, speakers, and word count,
- a **▶ Play** control that plays the meeting audio inline, and
- a **View raw transcript** toggle that expands the full transcript.

Light and dark themes are both handled. In a client that does not render inline
UI, the same tool returns a plain-text meeting list as a fallback.

## Privacy: nothing leaves this Mac

This is the reason MCP Apps is the right first move for Transcripted. The widget
is **fully self-contained** — inline CSS/JS, no CDN, no external fonts, no
network calls of any kind. Audio and transcripts are read from the local capture
library and travel *with* the widget over the local stdio transport to the local
client. There is no remote host in the loop. This matches the app's "your content
never leaves this Mac" posture exactly; the local MCP server serves local bytes to
the local agent.

Concretely, the widget's sandbox runs under the MCP Apps default CSP
(`default-src 'none'; media-src 'self' data:; connect-src 'none'; …`), so it
*cannot* reach the network even if it wanted to. Audio plays from a
`data:audio/mp4;base64,…` URI, which the default policy allows.

## The wire shape (MCP Apps / SEP-1865)

Built against the official **MCP Apps** extension (`io.modelcontextprotocol/ui`,
spec `2026-01-26`), the standardized successor to the community `mcp-ui` project:

- A `ui://transcripted/recent-meetings.html` resource, MIME
  `text/html;profile=mcp-app`, is registered and served via `resources/read`.
- The `show_recent_meetings` tool links to it via `_meta.ui.resourceUri`, and
  also sets `_meta["openai/outputTemplate"]` (the OpenAI Apps SDK alias) so it
  works in ChatGPT.
- The tool result carries three things so it renders across host families:
  1. a **text** summary (fallback for non-rendering clients),
  2. the data-baked widget HTML as an **inline embedded resource** (the `mcp-ui`
     `rawHtml` pattern), and
  3. `structuredContent` (the meeting model), so a host that renders the template
     and pushes tool output via `ui/notifications/tool-result` / `window.openai.toolOutput`
     renders the same view.

The widget prefers live host data when present and falls back to the baked-in
data otherwise, so it renders identically standalone, from `resources/read`, or
inline.

## Renders today in… (be honest)

MCP Apps shipped 2026-01-26 and host support is uneven. Grounded in the spec and
client docs as of mid-2026:

| Client | Renders this widget inline? |
|---|---|
| **ChatGPT** (OpenAI Apps SDK) | **Yes** — most mature inline-widget host. |
| **VS Code** (Copilot MCP) | **Yes** (shipped at launch). |
| **Cursor** (≥ 2.6) | **Yes** (known bug: strips `_meta` from tool-result; the baked-in data path still renders). |
| **Goose** | **Yes**. |
| **Claude Desktop / claude.ai** | **Announced yes, but verify** — a credible open report ([ext-apps#671](https://github.com/modelcontextprotocol/ext-apps/issues/671)) shows some builds negotiate the extension and fetch the resource but paint no iframe. Test on your build. |
| **Claude Code (CLI)** | **No** — it's a terminal; it consumes the tool but shows the **text fallback**, not inline UI. |

So: **renders inline today in ChatGPT, VS Code, Cursor, and Goose. Needs client
support to render in Claude Desktop/web (announced, contested). Does not render
inline in the Claude Code CLI** (by design — no iframe surface); there you get the
text list.

## How to try it

In a rendering-capable client (ChatGPT via the Apps SDK, VS Code, Cursor ≥ 2.6,
or Goose), connect the Transcripted MCP server, then ask the agent to
"show my recent meetings" (or call `show_recent_meetings` directly). The widget
draws inline; click **▶ Play** to hear a meeting and **View raw transcript** to
read it.

To sanity-check the widget itself without a client, drive the server over stdio
and open the HTML it returns:

```bash
cd Tools/TranscriptedMCP && swift build
# initialize → tools/call show_recent_meetings, then write the embedded
# resource's `text` to recent-meetings.html and open it in any browser.
```

The card list, audio playback, and transcript toggle all work standalone — that
is the proof the widget is correct even where a client hasn't shipped MCP Apps
rendering yet.

## Known limitations (minimal slice)

- **Inline audio is size-capped** (per-meeting and per-widget budgets in
  `RecentMeetingsWidgetBuilder`). Audio bytes ride inside the tool result, and
  some hosts limit message size, so longer recordings fall back to showing their
  local `audio/<stem>_audio/` path instead of an inline player. The natural next
  step is lazy fetch: a play click calls a `get_meeting_audio` tool over the
  postMessage bridge and streams the track on demand — scales past the inline
  budget, but needs a host that forwards widget→server tool calls.
- One widget (recent meetings). The transcript browser and person card sketched
  in the design doc are follow-ups.
