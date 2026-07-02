# Cross-meeting MCP tools

`transcripted-mcp` can roll up structured meeting-summary fields across the
local meeting library:

| Tool | What it answers |
|------|-----------------|
| `list_action_items` | "Open action items for Nate", "what did we commit to last week". Filters by owner, status, query, date window, and count. |
| `list_decisions` | "What did we decide about pricing", "all decisions this quarter". Filters by query, date window, and count. |
| `digest` | "What happened across all my meetings this week" — every meeting in the window with decisions, action items, and open questions grouped, plus rolled-up counts. |

All three tools are read-only. They query `meeting_summary_items`, the same
normalized index table populated during MCP reconcile from saved meeting
Markdown.

## Data flow

1. When a meeting transcript is saved, Transcripted writes a cheap always-on
   `auto_summary_*` frontmatter summary. If the user later runs the heavier
   local AI summary, the existing `local_summary_*` fields remain the higher
   quality source.
2. `TranscriptedCaptureKit.CaptureSummaryParser` parses structured Decisions,
   Action Items, and Open Questions from inline summary blocks, frontmatter, or
   a legacy `<stem>.summary.md` sidecar.
3. `TranscriptIndex.indexMeeting` writes one row per structured bullet into
   `meeting_summary_items` with a `kind` discriminator.
4. The rollup tools query those rows and join `meetings` for dates.

Action items carry `text`, optional `owner`, and optional `status` / `due`
metadata from trailing markers on the bullet:

- `- Nate: draft the launch email (due: Friday)`
- `- Jenny: confirm the venue (done)` or `(status: done)`

The always-on quick extraction writes `(due: ...)` markers when a commitment
sentence carries a recognizable deadline cue ("by Friday", "by end of week").
Nothing is ever extracted as `done` — closing an item happens by editing the
marker in the saved Markdown, which the file watcher reindexes on save. That is
the supported write-back path for users and agents alike: mark a bullet
`(done)` and `list_action_items` with `status: "open"` stops returning it. Items
with no marker (including everything written before markers existed) count as
open.

## Verification

The key package tests are:

```bash
swift test --package-path Tools/TranscriptedCaptureKit
swift test --package-path Tools/TranscriptedMCP
```

`SummaryItemIndexTests` proves parse -> index -> query for the structured
summary table. `SummaryRollupTests` proves saved meeting Markdown can be
indexed and queried through the cross-meeting rollup methods.
