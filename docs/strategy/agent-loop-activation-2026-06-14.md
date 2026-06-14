# Agent Loop Activation — deep dive (2026-06-14)

Scope: is the capture -> agent -> answer -> return loop actually good today, where is it
shallow, and what's the next leap. Grounded in the source, not the pitch.

## Executive summary

The plumbing is genuinely strong. Transcripted writes clean, frontmattered Markdown to
disk, ships a real read-only MCP server with nine tools backed by a SQLite + FTS5 index,
and the agent-connect onboarding is a true one-click-per-agent flow (Claude Desktop,
Claude Code, Codex, Cursor) with a sane copy-prompt fallback for everyone else. For
single-meeting questions — "summarize my latest call", "what did Jenny say about pricing"
— the loop works well and the agent quotes instead of guessing. That's real, and it's
ahead of "point at a folder and pray."

But the moat — "ask my history" across many meetings over time — is where reality falls
short of the promise. The retrieval layer is **lexical keyword search only**. There are no
embeddings, no semantic ranking, no topic/decision/action-item index, no entity graph
across meetings + dictations, and no cross-capture "memory" abstraction. `who_is` is
meeting-only and never touches dictations. `recap` returns the first ~15 raw transcript
lines as a "preview," not a summary. So a question like "what did I promise across all my
calls this month and what's still open?" forces the agent to brute-force read full
transcripts, and a paraphrased query ("the budget conversation") misses the meeting that
only ever said "spend" and "headcount." The structured intelligence that would make
cross-meeting answers fast and reliable already exists in the product — the Gemma/Apple
local summarizer extracts Decisions, Action Items, Open Questions per meeting — but **that
structured output is not indexed and not queryable through MCP.** The single biggest leap
is to close that gap: index the summary fields and expose a structured cross-meeting query
surface. That turns a folder of transcripts into an actual answerable memory.

## Current state — what works (grounded)

### The saved Markdown is well-shaped for agents, not just humans

Meeting files (`Sources/TranscriptedCore/Storage/TranscriptFormatter.swift`) carry real
YAML frontmatter: `capture_id`, `capture_type: meeting`, `date`, `time`, `duration`,
`transcription_engine`, per-channel utterance/speaker counts, `total_word_count`, optional
`title`, recording-health keys, and a structured `speakers:` block with channel-qualified
ids, `db_id` (persistent speaker UUID), `name`, `confidence`, `source`
(`TranscriptFormatter.swift:84-176`). Optional Obsidian mode adds `tags`, `aliases`,
`cssclasses`, and `[[wiki-link]]` speaker names (`:155-293`). The body has a Channel &
Speaker Analytics section and a `## Full Transcript` with `[MM:SS] [Source/Speaker] text`
lines. Dictations (`Sources/Dictation/DictationTranscriptWriter.swift`) are one append-only
file per day with `capture_type: dictation_day` frontmatter and per-entry metadata (Entry
ID, ISO `Captured:` timestamp, source app + bundle id, delivery outcome, word/char counts).

This is above the bar. Timestamps, speaker attribution, persistent speaker ids, stable
capture ids, and a parser-friendly shape are all there. The format is the strongest part
of the moat.

### The MCP server is a real index, not a folder pointer

`Tools/TranscriptedMCP` builds a SQLite index (`TranscriptIndex.swift`) with FTS5 virtual
tables over both meeting utterances and dictation entries, a `FileWatcher` for incremental
reindex, corruption recovery (`PRAGMA quick_check`), WAL mode, and owner-only file perms.
Nine read-only tools (`ToolHandlers.swift:22-237`): `list_meetings`, `read_meeting`
(with `full`/`transcript`/`speakers` sections), `list_dictations`, `read_dictation`
(whole day or one `entry_id`), `search` (utterance FTS, speaker + date filters), `who_is`,
`recap`, plus the unified `search_context` and `recent_context` that span meetings and
dictations together. Name matching is fuzzy via `NameVariants` (Mike -> Michael) and
substring (Jenny -> Jenny Wen). Path reads are hardened against traversal/symlink escape
(`PathSecurity`). The connect doc and starter prompt steer agents to use direct tools
first and fall back to reading the folders if MCP isn't connected
(`AgentConnectionGuide.starterPrompt`). This is a well-built retrieval layer for what it
covers.

### Agent-connect onboarding is smooth and broad

`AgentMCPConnector.swift` gives one `Connect` button per detected agent. Claude Desktop
runs the dedicated installer + self-test; Claude Code registers through the `claude` CLI
(it never hand-edits `~/.claude.json`); Codex gets a careful text-level TOML edit of only
`[mcp_servers.transcripted]` that refuses to corrupt inline/dotted configs; Cursor gets the
same safe `mcpServers` JSON merge as Claude Desktop. The bundled helper self-heals at
launch (replaces a stale copy). For agents we can't configure, the universal copy-prompt
row and a `portableMeetingBundle` (embeds one meeting + skill instructions for any web
chat) cover the long tail. There's also an opt-in live-meeting sidecar for Codex/Cowork.
First-prompt copy is concrete and good: "Summarize my latest meeting. Tell me which
Transcripted source you used... then list decisions and action items."

### Return-use surfacing exists

Home (`HomeView` + `RecentCaptureScanners.swift`) shows day-grouped recent meetings and
dictations with hover-reveal actions, audio playback, failed-meeting recovery, and an
inline AI-summary lead when a local summary exists. `ActivationTelemetry.swift` is honest
about its limits — it tracks artifact actions, agent setup/prompt CTAs, and a
`return_proxy_observed` event bucketed by time-since-prior-artifact as a coarse proxy for
"did they come back." That's a sensible MVP of measurement.

### Local summaries already produce the structured gold

`LocalMeetingSummarizer.swift` (Gemma MLX or Apple Foundation Models, opt-in beta) chunks
the transcript, runs a tightly-prompted extraction, and writes back into the same meeting
file a managed block with Title, Summary, Decisions, Action Items, Open Questions, Risks/
Follow-ups, Accuracy Notes, plus flattened `local_summary_*` frontmatter keys
(`LocalMeetingSummaryMarkdownUpdater`, `:1592-1830`). The prompts are careful (owner-first
action items, decisions-name-outcome-first, "None found." discipline, anti-hallucination
rules). This is exactly the structured layer a cross-meeting memory needs.

## The gaps (ranked, with evidence)

### 1. Cross-capture intelligence is the crux, and it's missing. [biggest]

The payoff question is "ask my history across many meetings" — and the index can't answer
it well. Every query path is single-file or flat-list:

- `search`/`search_context` return matching utterances grouped by meeting, ordered by FTS
  `rank`, capped at the first ~200 rows then top-N meetings (`TranscriptIndex.swift:399-501`).
  Good for "find the pricing discussion," useless for "synthesize what we decided about
  pricing across Q2."
- `recap` (`ToolHandlers.swift:514-562`) returns each meeting's first ~15 raw transcript
  lines as `preview` — it is explicitly *not* a summary, so "what did I miss Mon-Wed"
  dumps raw dialogue openings, not decisions/action items.
- There is no tool for "all open action items," "all decisions about X," "everything I
  committed to this week." The agent must `list_meetings` then `read_meeting` each one in
  full and reason over raw transcripts. That's slow, blows context windows, and gets less
  reliable the more history you have — the moat *inverts* as the library grows.

### 2. Retrieval is lexical only — no semantic search. [high]

Both FTS tables use `tokenize='porter unicode61'` (`TranscriptIndex.swift:126-153`) and
queries are tokenized into quoted AND terms (`:401-402`, `:604-605`). There are no
embeddings, vectors, or semantic ranking anywhere in the tree (confirmed by grep). A user
who asks "the conversation about cutting costs" will miss a meeting that only said
"reduce headcount" and "trim the budget." This is precisely where cloud-RAG competitors
win, and it's the difference between "search" and "memory."

### 3. The structured summary output is generated but never indexed. [high]

The Gemma/Apple summarizer writes Decisions / Action Items / Open Questions into the file
and frontmatter, but `TranscriptIndex` indexes only `meetings`, `meeting_speakers`,
`utterances`, `dictation_days`, `dictation_entries` (`:62-176`). No table for summaries,
decisions, or action items. So the one place with clean structured facts is invisible to
MCP. `recap` even re-derives a raw preview instead of reading the summary that may already
exist in the file. The product already paid the compute cost to extract this — it's just
not wired into retrieval.

### 4. `who_is` and the people graph stop at meetings. [high]

`who_is` (`getPersonProfile`, `:971-1029`) is meeting-only: meeting count, speaking time,
frequent co-speakers, representative quotes. Dictations are never associated with people,
and there's no "what did this person commit to / what do I owe them" view — even though
action items with owners exist in the summaries (gap #3). There's a persistent speaker id
(`db_id`) in frontmatter, but no cross-meeting entity/topic graph is built from it. "Prep
me for my 1:1 with Sam" can list past co-occurrence but can't surface open threads.

### 5. The agent has to be told how to drive the tools; there's no server-side guidance. [med]

The tool *descriptions* are good, but the retrieval strategy lives in a client-side
starter prompt (`AgentConnectionGuide.starterPrompt`) that only lands if the user pasted
it. A freshly-connected MCP agent gets nine tools and has to figure out the right
sequence (list -> read, or search -> read) itself. There's no MCP `prompts` capability,
no "recommended retrieval recipes" surfaced by the server, and no resources. For
power-prompted Claude it's fine; for weaker agents it's a coin flip on whether they pick
`recap` vs `search` vs reading everything.

### 6. Measurement can't see the actual answer. [med]

`ActivationTelemetry` tracks setup clicks and a coarse return-proxy, but by privacy design
nothing observes whether the agent gave a *useful* answer, which tool it called, or
whether retrieval returned hits. The team is flying blind on the middle of the loop ("did
they get one useful answer") — the exact step the activation lane says is the real
question. Hard to improve retrieval ranking with zero signal on retrieval quality. (This
is a deliberate privacy tradeoff, not an oversight — but it's still a blind spot.)

### 7. Dictation-side intelligence is thin. [low]

Dictations are full-text searchable but have no summary, no entity extraction, no titles
beyond the first 7 words. They're second-class in `who_is` and in any future cross-capture
synthesis, even though "what did I promise" lives as much in voice memos as in meetings.

## The biggest leap: a structured cross-meeting memory layer over MCP

**Recommendation:** index the structured summary fields (Decisions, Action Items + owner,
Open Questions, Risks) into the SQLite index, and add cross-meeting query tools on top:
`list_action_items` (filter by owner/status/date), `list_decisions` (filter by topic/date),
and a `synthesize`/`digest` tool that returns the *structured* summary block per meeting in
a range instead of raw transcript previews. Pair it with semantic search (a local
embeddings table over utterances + summaries with a vector ANN/cosine query) so
paraphrased questions hit.

**Why it's the moat-maker.** The promise is "your AI stops guessing and starts quoting,"
but the deeper promise is "ask your history." Today the agent can quote *one* file well and
brute-forces the rest. This leap makes the across-time questions — the only ones a folder
of files can't already answer with a glob — fast, cheap, and reliable, and it does it
*locally*. It also flips the moat from "degrades as the library grows" to "compounds as the
library grows," which is the whole point of a memory product. Crucially, most of the hard
part is done: the summarizer already extracts the structured facts; this is wiring, schema,
and one embedding model, not new ML.

**Rough effort: L** (a focused L, not a moonshot). Schema + indexing of existing summary
frontmatter and 2-3 new structured tools is **M**. Adding a local embeddings table +
semantic search tool is the L part (model bundling, backfill, ANN query), but the
embedding model is small and the corpus is one user's transcripts. Phase it: structured
indexing first (proves the cross-meeting value immediately on top of existing summaries),
embeddings second.

**One sharp dependency / caveat:** structured cross-meeting tools are only as good as
summary coverage, and summaries are an opt-in beta gated on Gemma/Apple availability and
12GB+ RAM. To make this the default experience you likely need a lightweight always-on
extraction pass (even a cheap rules+small-model action-item/decision tagger at save time),
not just the heavy opt-in summarizer. Otherwise the new tools return "no summary indexed"
for most users.

## Ranked next moves

1. **Index existing `local_summary_*` fields into SQLite.** [effort: M] [impact: high]
   Add `meeting_summaries` (+ optional `action_items`, `decisions`) tables populated from
   the frontmatter the summarizer already writes; reconcile in `FileWatcher`. Unlocks
   everything below. Zero new ML.

2. **Add cross-meeting structured tools: `list_action_items`, `list_decisions`, `digest`.**
   [effort: M] [impact: high] `digest` replaces `recap`'s raw-line preview with the
   structured summary block per meeting in a date range. This is the literal "what did I
   promise / decide this week" answer the pitch sells.

3. **Make `recap` summary-aware now, even before full indexing.** [effort: S] [impact: high]
   `recap` already opens each meeting file (`ToolHandlers.swift:530-540`); have it prefer
   the in-file `## Local ... Summary` block / `local_summary_*` frontmatter when present
   instead of the first 15 transcript lines. Cheap, immediate quality jump for the most
   "ask my history"-shaped tool.

4. **Local semantic search over utterances + summaries.** [effort: L] [impact: high]
   Bundle a small embedding model, add a vector table, expose `semantic_search` (or fold
   ranking into `search_context`). Closes the paraphrase gap that cloud RAG wins on, while
   staying local. The true differentiator.

5. **Extend `who_is` into a people-and-commitments view.** [effort: M] [impact: med]
   Once action items are indexed (move #1), add "what {person} owes / what I owe {person}"
   and link dictations mentioning a name. Turns `who_is` from trivia into meeting prep.

6. **Ship MCP `prompts` / retrieval recipes from the server.** [effort: S] [impact: med]
   Expose the good starter recipes as MCP prompts so any connected agent — not just ones
   that got the pasted prompt — knows to `search` then `read`, or call `digest` for a
   week. Improves first-answer quality for weaker agents at near-zero cost.

7. **Always-on lightweight extraction at save time.** [effort: M] [impact: med]
   A cheap decision/action-item tagger run on every saved meeting (not gated on the 12GB
   Gemma beta) so the structured tools have coverage for everyone, not just summary-beta
   users. Removes the dependency that otherwise caps moves #1-3.

8. **Add coarse, privacy-safe retrieval-quality telemetry.** [effort: S] [impact: med]
   Even bucketed signals (tool called, hit-count bucket, zero-result rate) would let the
   team tune ranking and see the middle of the loop without sending content. Today there's
   no signal on whether retrieval even returned anything.

## Honest competitive note

Versus Granola / Limitless / Notion AI:

- **Where local-first wins:** the files are *yours* and any agent can read them — no vendor
  lock to one chat UI, works offline, no transcript text leaving the Mac, and it plugs into
  the agent the user already lives in (Claude Code, Codex, Cursor) rather than a walled
  app. The Markdown format and persistent speaker ids are genuinely better substrate than a
  competitor's opaque cloud store. For a privacy-sensitive or agent-native user this is a
  real, defensible edge.
- **Where local-first loses today:** the competitors' core feature *is* cross-meeting RAG —
  semantic search and "ask everything you've ever recorded" answered in one box. Transcripted
  ships the storage and single-file retrieval but not the cross-meeting synthesis or
  semantic recall, so on the headline "ask my history" demo it currently looks weaker than a
  cloud RAG product even though its data substrate is stronger. The leap above is what
  closes that gap — and closing it *locally* is the version of this nobody else has.

## Honest risks

- **Summary-coverage dependency.** Structured cross-meeting tools are worthless without
  broad summary coverage; the heavy summarizer is opt-in and RAM-gated. Move #7 (cheap
  always-on extraction) is effectively a prerequisite for #1-3 to feel good for most users.
- **Extraction quality is the ceiling.** Local action-item/decision extraction will be
  noisier than a frontier cloud model. Wrong "you promised X" is worse than no answer.
  Keep the accuracy-notes discipline and cite source lines/timestamps so the agent can
  verify rather than trust blindly.
- **Index scale + backfill.** Semantic indexing and structured backfill over a large
  existing library is a one-time cost that must stay off the main actor and not jank the
  app; reconcile/backfill paths need care (the index already does incremental reconcile,
  but embeddings backfill is heavier).
- **Privacy-vs-measurement tension is real.** Better retrieval needs feedback the current
  privacy stance forbids. Even coarse bucketed signals must clear the allowlist/sanitizer
  bar — design the telemetry with that constraint up front, not as a retrofit.
- **Don't over-build the MCP before the format question is answered.** If always-on
  extraction changes the written Markdown shape, `TranscriptedCaptureKit` parsers, the
  formatter, and tests must all move together (the repo already enforces this coupling) —
  scope the format change deliberately so the standalone tools don't drift.
