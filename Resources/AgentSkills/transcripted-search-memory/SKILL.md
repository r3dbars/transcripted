---
name: transcripted-search-memory
description: Search Transcripted meeting and dictation history for what was said, when it happened, who mentioned it, where an idea came from, or how a topic changed over time. Use for memory, recall, provenance, timeline, source-finding, and "what did I say about" questions.
---

# Transcripted Search Memory

Version: 0.1.0

## Purpose

Find evidence across Transcripted meetings and dictations, then answer with source-backed memory. Search first, synthesize second.

## Workflow

1. Restate the query as a search target: topic, person, project, phrase, decision, action, or date range.
2. Prefer Transcripted MCP tools when available. Fall back to local meeting and dictation markdown files only when MCP is unavailable.
3. Combine available retrieval modes:
   - exact search
   - relevant context search
   - recency
   - date filters
   - people or speaker names
   - topic/project terms
4. Show the best matches before or alongside the answer.
5. Synthesize only from the evidence found.
6. If the topic appears over time, include a short timeline.
7. If evidence is thin or missing, say so plainly.

## Default Output

Use these sections when relevant:

```md
## Answer

## Best Matches

## Timeline

## Related Threads

## Confidence

## Sources

## Uncertainty
```

## Match Format

For each strong match, include as much of this as is available:

```md
- Source:
- Date:
- Speaker:
- Timestamp:
- Snippet:
- Why this surfaced:
```

## Rules

- Do not answer from vague memory when sources are available.
- Do not hide weak evidence. Use `low confidence` when matches are sparse, old, ambiguous, or conflicting.
- If nothing relevant is found, say `not found` and list what was searched.
- If the user asks for "when", prefer a timeline over a prose-only answer.
- If the user asks "where did this come from", prioritize the earliest strong source.
- Keep snippets short and cite the original capture instead of pasting large transcript chunks.

## Quality Check

Before answering, check:

- The answer has at least one source unless explicitly reporting no results.
- Important claims point to filenames, dates, speakers, or timestamps when available.
- Conflicting or evolving decisions are described as a timeline, not flattened into one claim.
- Search scope is clear enough that the user can ask a better follow-up.
