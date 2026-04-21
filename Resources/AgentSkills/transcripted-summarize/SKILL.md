---
name: transcripted-summarize
description: Create cited summaries, recaps, briefs, daily reviews, weekly reviews, and "what did I do" answers from Transcripted meetings and dictations. Use when the user asks to summarize one capture, a date range, a person, a project, a topic, or mixed meeting and dictation history.
---

# Transcripted Summarize

Version: 0.1.0

## Purpose

Turn Transcripted meetings and dictations into a clean brief that preserves source traceability. Treat raw transcript and dictation text as the source of truth.

## Workflow

1. Resolve scope first: one meeting, one dictation, a date range, a person, a project, a topic, or mixed captures.
2. Prefer Transcripted MCP tools when available. Fall back to local meeting and dictation markdown files only when MCP is unavailable.
3. Read the relevant source material before summarizing. For a named meeting, read the full meeting when possible.
4. Filter obvious junk: test captures, accidental fragments, setup chatter, and empty or near-empty recordings.
5. Normalize relative dates in the user's local timezone and state the exact dates searched.
6. Summarize with source filenames, dates, speakers, and timestamps when available.
7. Surface uncertainty instead of guessing.

## Default Output

Use these sections when relevant:

```md
## Brief

## Main Threads

## Decisions

## Action Items

## Open Questions

## Risks / Blockers

## Worth Remembering

## Sources

## Uncertainty
```

## Rules

- Do not invent owners, deadlines, decisions, or action items.
- If an owner, deadline, or status is missing, write `unknown`.
- Separate decisions from action items.
- Keep the brief short unless the user asks for depth.
- Cite the source meeting or dictation for important claims.
- When summarizing multiple captures, group repeated themes instead of repeating every similar note.
- If no useful content is found, say so and list what was checked.

## Quality Check

Before answering, check:

- Every decision or action item is grounded in source text.
- Dates are absolute when the user used relative time.
- Unclear speaker names, noisy audio, or missing transcript spans are called out.
- The answer does not expose unrelated sensitive details from other captures.
