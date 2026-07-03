# Ask Your History Decision Memo

Date: 2026-07-03
Scope: Transcripted Premium WS2.4/WS2.5 decision before building the omnibar.

## Decision

"Ask your history" is not one feature. It is a layered local recall system:

1. Fast retrieval: SQLite FTS5 over meeting titles, attendees, summaries, decisions, action items, open questions, raw utterances, and dictations.
2. Receipt model: every result must carry meeting id, date, speaker when known, timestamp when available, snippet, and source section.
3. Structured tools: MCP tools answer common work questions like decisions, commitments, open questions, and search meetings.
4. Optional synthesis: a local LLM can summarize retrieved evidence after the receipts are already visible.
5. Later semantic recall: local embeddings help with fuzzy questions only after exact and structured retrieval is trusted.

The user-facing promise should be: "Find the thing, show where it came from, then explain it if useful."

## What Ships First

Ship WS2.1-WS2.3 first:

- Index summaries, not just raw utterances.
- Fix `recap` to return real summary sections instead of first raw lines.
- Add structured cross-meeting MCP tools with receipts.

Do not build the omnibar first. An omnibar without reliable receipts becomes a pretty search box over weak memory. It adds UI risk before proving the value loop.

Do not start with local embeddings. Embeddings help "that meeting where..." questions, but they are harder to debug, harder to trust, and less important than exact decisions/actions/person/date recall.

Do not start with local LLM synthesis. Synthesis is useful as a second phase, but it must be grounded in retrieved receipts. The first proof can succeed without generated prose.

## Fully Local Under 1.5s

This is realistic locally:

- Keystroke to first FTS result: under 100ms on an already-open index.
- Summary/decision/action/open-question search: under 200ms for normal corpora if pre-indexed.
- Date/person filters: under 200ms with existing meeting and speaker tables.
- Receipt chips: immediate when backed by indexed filename, timestamp, section, quote.
- MCP `search_meetings`, `decisions`, `commitments`, and `open_questions`: under 1.5s perceived if they return JSON receipts first.
- Local LLM synthesis: acceptable only if streamed after receipts appear. It should not block first answer.

The latency contract should be staged:

1. Show exact/structured matches immediately.
2. Show receipt chips with the first paint.
3. Stream synthesis only after evidence is on screen.

## Privacy And Trust Risks

The biggest trust risk is a confident answer without a receipt. If Transcripted says "Sarah committed to X" and cannot show the exact source, the magic becomes creepy or wrong.

Other risks:

- Indexing too much raw text into analytics or logs. Search queries and snippets must stay local.
- LLM hallucination over thin retrieval. The answer must say when evidence is weak.
- Wrong speaker names turning into wrong commitments. Speaker uncertainty must be visible in receipts or excluded from commitment claims.
- Hidden cloud calls. Premium memory must be local by default, and any non-local path must be explicit.
- Recap/search drift. If the app summary says one thing and MCP returns raw dialogue, users will stop trusting both.

## User-Value Risks

The product risk is building a "universal AI search" before proving the narrow habit:

1. I captured a meeting.
2. I asked one question later.
3. I got the exact source back.
4. I came back because it saved me time.

The first valuable questions are not broad philosophical prompts. They are work retrieval:

- What did we decide about pricing?
- What did Sarah say she would do?
- What open questions are still unresolved?
- Where did this idea come from?
- What changed since last week?

If those fail, semantic search and omnibar polish will not save the feature.

## Defer

Defer until the receipt loop is proven:

- WS2.4 omnibar UI.
- WS2.5 embeddings.
- Long-form local LLM answers.
- "Ask anything ever" marketing.
- Morning Rewind claims that depend on cross-meeting synthesis.
- Proactive agent behavior.

These may be right later. They are just not the next proof.

## Smallest Proof Experiment

Build a local MCP proof before the omnibar:

1. Index summary sections alongside raw utterances.
2. Add or adjust tools:
   - `search_meetings(query, range)`
   - `decisions(topic, range)`
   - `commitments(person, range)`
   - `open_questions(project, range)`
3. Return structured receipts for every item:
   - `meetingId`
   - `title`
   - `date`
   - `section`
   - `timestamp` when available
   - `speaker` when known
   - `quote`
   - `confidence`: `exact`, `section`, or `weak`
4. Create a 20-50 meeting fixture with summary-only hits, raw-only hits, person/date filters, and no-result cases.
5. Benchmark:
   - backfill time
   - query p50/p95
   - first-result latency
   - receipt completeness

Pass condition: five realistic questions return correct source-backed results locally in under 1.5s perceived, with no LLM required.

## Recommendation

Split WS2:

- Build now: WS2.1-WS2.3 as local retrieval plus MCP receipts.
- Hold: WS2.4 omnibar until MCP proof answers real questions cleanly.
- Hold: WS2.5 semantic layer until exact and summary retrieval has known misses.
- Add later: local synthesis as a streamed layer after receipts.

This keeps the moat real: not "AI search", but trustworthy private work memory.
