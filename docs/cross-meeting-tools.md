# Cross-meeting MCP tools (list_action_items / list_decisions / digest)

These three `transcripted-mcp` tools roll up the structured summary fields —
Decisions, Action Items, Open Questions — *across* meetings, instead of one
meeting at a time. This is NEXT_WORK item #4 ("the demo: every open action item
assigned to me, across every call").

## Tools

| Tool | What it answers |
|------|-----------------|
| `list_action_items` | "Open action items for Nate", "what did we commit to last week". Filters: `owner` (name-variant + substring match), `status` (`open` default / `done` / `all`), `query` (FTS on text), `date_from`/`date_to`, `count`. |
| `list_decisions` | "What did we decide about pricing", "all decisions this quarter". Filters: `query` (FTS), `date_from`/`date_to`, `count`. |
| `digest` | "What happened across all my meetings this week" — every meeting in the window with summary facts, grouped, plus rolled-up counts. Filters: `date_from`/`date_to` (default today). |

All are read-only and join the summary-fact tables to `meetings` for date/title.

## HARD DEPENDENCY — summary-index PR ("Moat #1: index summary fields")

> **Sequence #1 before this PR.** These tools query three tables —
> `action_items`, `decisions`, `open_questions` — keyed to the meeting id
> (`filename`). The **summary-index PR owns populating them** by parsing the
> Decisions / Action Items / Open Questions that the summarizer already writes
> into each meeting markdown (frontmatter keys `local_summary_action_items` /
> `local_summary_decisions` / `local_summary_open_questions`, or the
> `### Action Items` etc. sections — see
> `Sources/UI/Shared/RecentCaptureScanners.swift`).

This PR does **not** duplicate that extraction. It contributes:

1. **The provisional table schema** — defined in `TranscriptIndex.createTables()`
   with `IF NOT EXISTS`, clearly flagged. When the summary-index PR lands its
   authoritative schema, the merge-room must reconcile that block and keep a
   single copy.
2. **The write seam** `TranscriptIndex.replaceSummaryFacts(filename:decisions:actionItems:openQuestions:)`
   — the API the summary-index PR's extractor calls during reconcile. Tests call
   it directly to seed facts.
3. **The query layer + the three tools + tests.**

Until #1 lands, the tables exist but stay empty in production, so the tools
return a clear "summaries have not been indexed yet" message rather than wrong
data. The tests seed facts through the write seam, so the query layer is fully
covered in isolation.

### What the merge-room needs to do

1. Land the summary-index PR (#1) first.
2. Rebase this PR on it. Expect a conflict in `TranscriptIndex.swift`
   (`createTables` schema block, and possibly `removeFromIndex`). Keep one copy
   of each table definition; the column set here (`action_items(filename, text,
   owner, status, due)`, `decisions(filename, text)`, `open_questions(filename,
   text)`) is the contract the tools depend on — if #1 chose different column
   names, update the query layer in `TranscriptIndex.swift` to match.
3. Wire #1's extractor to call `replaceSummaryFacts` (or fold the two write
   paths together) so reconcile populates the tables.

### Conflict note (recap-fix thread)

The recap-fix thread also edits `ToolHandlers.swift`. Changes here are
append-only (three new `Tool` entries, three new `switch` cases, three new
handler functions) and do not touch `handleRecap`, so the conflict surface is
small. Merge-room sequences.
